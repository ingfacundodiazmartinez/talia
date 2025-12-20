import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
// ✅ Nuevos servicios atómicos
import '../services/chats/chat_services.dart';
import '../utils/release_logger.dart';

/// Controller base con lógica compartida entre Parent y Child chats
///
/// Responsabilidades:
/// - Proveer streams de datos de Firestore
/// - Filtrar chats eliminados y archivados
/// - Formatear timestamps
/// - Gestionar reconexión de Firestore
abstract class BaseChatsController {
  final String userId;
  final FirebaseFirestore _firestore;
  final ChatService _chatService;
  final GroupChatService _groupChatService;
  // ✅ Nuevo servicio atómico para grupos
  final LeaveGroupService _leaveGroupService;
  // ✅ Cache de preferencias (Hive) para archivados/silenciados
  final ChatPreferencesCache _preferencesCache;

  BaseChatsController({
    required this.userId,
    FirebaseFirestore? firestore,
    ChatService? chatService,
    GroupChatService? groupChatService,
    LeaveGroupService? leaveGroupService,
    ChatPreferencesCache? preferencesCache,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _chatService = chatService ?? ChatService(),
       _groupChatService = groupChatService ?? GroupChatService(),
       _leaveGroupService = leaveGroupService ?? LeaveGroupService(),
       _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  // Getters protegidos para acceso desde subclases
  @protected
  ChatService get chatService => _chatService;

  @protected
  GroupChatService get groupChatService => _groupChatService;

  /// Stream de chats donde el usuario participa
  /// ✅ Paginado a 50 chats para escalar a 10,000+ chats
  Stream<QuerySnapshot> getChatsStream({int limit = 50}) {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .limit(limit)
        .snapshots(includeMetadataChanges: false);
  }

  /// Stream de grupos donde el usuario es miembro (Groups V2)
  /// ✅ Paginado a 50 grupos para escalar
  Stream<QuerySnapshot> getGroupsStream({int limit = 50}) {
    ReleaseLogger.log('🔍 [getGroupsStream] Iniciando stream para userId: $userId', tag: 'BaseChats');

    return _firestore
        .collection('groups_v2')
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .limit(limit)
        .snapshots(includeMetadataChanges: false)
        .handleError((error, stackTrace) {
          ReleaseLogger.error(
            '❌ [getGroupsStream] ERROR en stream: $error',
            tag: 'BaseChats',
          );
          ReleaseLogger.error(
            '   Stack: $stackTrace',
            tag: 'BaseChats',
          );
        })
        .map((snapshot) {
          ReleaseLogger.log(
            '📊 [getGroupsStream] Recibidos ${snapshot.docs.length} grupos para userId: $userId',
            tag: 'BaseChats',
          );
          if (snapshot.docs.isEmpty) {
            ReleaseLogger.log(
              '⚠️ [getGroupsStream] No se encontraron grupos - verificar query o permisos',
              tag: 'BaseChats',
            );
          }
          for (final doc in snapshot.docs) {
            final data = doc.data() as Map<String, dynamic>;
            ReleaseLogger.log(
              '  → Grupo: ${doc.id}, nombre: ${data['name']}, members: ${(data['members'] as List?)?.length ?? 0}',
              tag: 'BaseChats',
            );
          }
          return snapshot;
        });
  }

  /// Stream de datos de un usuario específico
  /// ✅ FIX: Maneja errores de permisos gracefully (ej: cuando se revoca un contacto)
  Stream<DocumentSnapshot?> getUserDataStream(String targetUserId) {
    return _firestore
        .collection('users')
        .doc(targetUserId)
        .snapshots(includeMetadataChanges: false)
        .handleError((error) {
          // Ignorar errores de permisos silenciosamente
          // Esto ocurre cuando un contacto es revocado y ya no tenemos acceso
          ReleaseLogger.log(
            'Stream de usuario $targetUserId cerrado (sin permisos)',
            tag: 'BaseChats',
          );
          return null;
        });
  }

  /// Obtener datos de usuario (una vez)
  Future<Map<String, dynamic>?> getUserData(String targetUserId) async {
    try {
      final doc = await _firestore.collection('users').doc(targetUserId).get();
      return doc.data();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de usuario $targetUserId: $e', tag: 'BaseChats');
      return null;
    }
  }

  /// ✅ CORREGIDO: Refresh suave sin romper StreamSubscriptions activos
  ///
  /// PROBLEMA ANTERIOR: disableNetwork() y enableNetwork() cancelaban TODOS los
  /// StreamBuilders activos, causando spinner infinito después de videollamadas.
  ///
  /// SOLUCIÓN: Firestore ya maneja actualizaciones en tiempo real automáticamente.
  /// Solo necesitamos un delay para la UX del pull-to-refresh.
  Future<void> forceReconnect() async {
    try {
      ReleaseLogger.log('Actualizando lista de chats...', tag: 'BaseChats');

      // ✅ NUEVO: Delay simple para UX sin romper streams
      // Firestore se actualiza automáticamente con cambios en tiempo real
      await Future.delayed(Duration(milliseconds: 800));

      ReleaseLogger.log('Lista de chats actualizada', tag: 'BaseChats');
    } catch (e) {
      ReleaseLogger.error('Error actualizando lista: $e', tag: 'BaseChats');
    }
  }

  /// 🔄 Forzar actualización de grupos desde el servidor (Groups V2)
  ///
  /// Útil después de crear un grupo para asegurar que el cache local
  /// tenga los datos más recientes del servidor.
  Future<void> refreshGroupsFromServer() async {
    try {
      ReleaseLogger.log('🔄 Forzando refresh de grupos_v2 desde servidor para userId: $userId', tag: 'BaseChats');

      // Hacer una query explícita al servidor para actualizar el cache
      // Con timeout para evitar que se cuelgue
      // ✅ Limitado a 50 para escalar
      final snapshot = await _firestore
          .collection('groups_v2')
          .where('members', arrayContains: userId)
          .where('isActive', isEqualTo: true)
          .orderBy('lastActivity', descending: true)
          .limit(50)
          .get(GetOptions(source: Source.server))
          .timeout(
            Duration(seconds: 10),
            onTimeout: () {
              ReleaseLogger.log('⏱️ Timeout en refresh de grupos_v2, usando cache', tag: 'BaseChats');
              return _firestore
                  .collection('groups_v2')
                  .where('members', arrayContains: userId)
                  .where('isActive', isEqualTo: true)
                  .orderBy('lastActivity', descending: true)
                  .limit(50)
                  .get();
            },
          );

      ReleaseLogger.log('✅ Grupos V2 actualizados desde servidor: ${snapshot.docs.length} grupos encontrados', tag: 'BaseChats');

      for (final doc in snapshot.docs) {
        final data = doc.data();
        ReleaseLogger.log('  → Grupo: ${doc.id}, nombre: ${data['name']}', tag: 'BaseChats');
      }

      // Delay para dar tiempo al cache de actualizarse y a los listeners de recibir el update
      await Future.delayed(Duration(milliseconds: 500));
    } catch (e, stack) {
      ReleaseLogger.error('❌ Error refrescando grupos: $e', tag: 'BaseChats');
      ReleaseLogger.error('   Stack: $stack', tag: 'BaseChats');
    }
  }

  /// Filtra chats eliminados
  List<QueryDocumentSnapshot> filterDeletedChats(QuerySnapshot snapshot) {
    return _chatService.filterDeletedChats(snapshot);
  }

  /// Filtra chats archivados usando Hive cache (no Firestore)
  List<QueryDocumentSnapshot> filterArchivedChats(
    List<QueryDocumentSnapshot> chatDocs,
  ) {
    return chatDocs.where((doc) {
      // ✅ Usar Hive cache en vez de Firestore
      return !_preferencesCache.isArchived(doc.id);
    }).toList();
  }

  /// Filtra grupos archivados usando Hive cache (no Firestore)
  List<QueryDocumentSnapshot> filterArchivedGroups(
    List<QueryDocumentSnapshot> groupDocs,
  ) {
    return groupDocs.where((doc) {
      // ✅ Usar Hive cache en vez de Firestore
      return !_preferencesCache.isArchived(doc.id);
    }).toList();
  }

  /// Formatear tiempo de mensaje
  String formatTime(dynamic timestamp) {
    if (timestamp == null) return '';

    final DateTime dateTime = (timestamp as Timestamp).toDate();
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      if (difference.inDays == 1) return 'Ayer';
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }

  /// Generar chatId entre dos usuarios
  String getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  /// Sale de un grupo específico
  /// ✅ Usa nuevo servicio atómico
  Future<void> leaveGroup(String groupId) async {
    final result = await _leaveGroupService.call(groupId: groupId);
    if (!result.success) {
      throw Exception(result.message);
    }
  }

  /// Ordenar chats por última actividad
  void sortChatsByLastActivity(List<QueryDocumentSnapshot> chats) {
    chats.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;
      final aTime =
          aData['lastMessageTime'] as Timestamp? ??
          aData['createdAt'] as Timestamp?;
      final bTime =
          bData['lastMessageTime'] as Timestamp? ??
          bData['createdAt'] as Timestamp?;

      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;

      return bTime.compareTo(aTime);
    });
  }

  /// Stream de datos específicos de un chat
  Stream<DocumentSnapshot> getChatDataStream(String chatId) {
    try {
      return _firestore.collection('chats').doc(chatId).snapshots(includeMetadataChanges: false);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de chat $chatId: $e', tag: 'BaseChats');
      rethrow;
    }
  }

  /// Stream del último mensaje de un grupo específico (Groups V2)
  Stream<QuerySnapshot> getGroupLastMessageStream(String groupId) {
    try {
      return _firestore
          .collection('groups_v2')
          .doc(groupId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .snapshots(includeMetadataChanges: false);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo último mensaje del grupo $groupId: $e', tag: 'BaseChats');
      rethrow;
    }
  }

  /// Stream del último mensaje de un chat individual
  Stream<QuerySnapshot> getChatLastMessageStream(String chatId) {
    try {
      return _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .snapshots(includeMetadataChanges: false);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo último mensaje del chat $chatId: $e', tag: 'BaseChats');
      rethrow;
    }
  }
}
