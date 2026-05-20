import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/chats/chat_services.dart';
import '../services/contact_alias_service.dart';
import '../services/block_service.dart';
import '../utils/release_logger.dart';

/// Controller para la pantalla de chats archivados de padres
///
/// Responsabilidades:
/// - Gestionar autenticación de usuario
/// - Obtener información de usuarios (Firestore)
/// - Manejar operaciones de archivado/desarchivado
/// - Proporcionar streams de Firestore (igual que BaseChatsController)
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
///
/// ✅ CORREGIDO: Usa EXACTAMENTE el mismo patrón que ParentChatsScreen:
/// - `Stream<QuerySnapshot>` CRUDO de Firestore (sin .map())
/// - Filtrado en el builder de la Screen
class ParentArchivedChatsController {
  // Servicios privados
  final UnarchiveChatService _unarchiveService;
  final ChatPreferencesCache _preferencesCache;
  final ContactAliasService _aliasService;
  final BlockService _blockService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;

  /// Constructor
  ParentArchivedChatsController({
    UnarchiveChatService? unarchiveService,
    ChatPreferencesCache? preferencesCache,
    ContactAliasService? aliasService,
    BlockService? blockService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  })  : _unarchiveService = unarchiveService ?? UnarchiveChatService(),
        _preferencesCache = preferencesCache ?? ChatPreferencesCache(),
        _aliasService = aliasService ?? ContactAliasService(),
        _blockService = blockService ?? BlockService(),
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  String get currentUserIdSafe => currentUserId ?? '';
  bool get isUserAuthenticated => currentUserId != null;

  /// ✅ Stream CRUDO de Firestore - EXACTAMENTE igual que BaseChatsController.getChatsStream()
  /// NO usa .map() para que cuando ValueKey cambie, Firestore emita datos cacheados inmediatamente
  Stream<QuerySnapshot> getChatsStream() {
    final userId = currentUserIdSafe;
    if (userId.isEmpty) return Stream.value(_EmptyQuerySnapshot());

    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .limit(50)
        .snapshots(includeMetadataChanges: false);
  }

  /// ✅ Stream CRUDO de Firestore - EXACTAMENTE igual que BaseChatsController.getGroupsStream()
  Stream<QuerySnapshot> getGroupsStream() {
    final userId = currentUserIdSafe;
    if (userId.isEmpty) return Stream.value(_EmptyQuerySnapshot());

    return _firestore
        .collection('groups_v2')
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .limit(50)
        .snapshots(includeMetadataChanges: false);
  }

  /// ✅ Filtrar SOLO chats archivados (se llama EN EL BUILDER, no en stream)
  List<QueryDocumentSnapshot> filterOnlyArchivedChats(List<QueryDocumentSnapshot> chatDocs) {
    return chatDocs.where((doc) => _preferencesCache.isArchived(doc.id)).toList();
  }

  /// ✅ Filtrar SOLO grupos archivados (se llama EN EL BUILDER, no en stream)
  List<QueryDocumentSnapshot> filterOnlyArchivedGroups(List<QueryDocumentSnapshot> groupDocs) {
    return groupDocs.where((doc) => _preferencesCache.isArchived(doc.id)).toList();
  }

  /// Inicializar el controller
  void initialize() {
    try {
      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.warning('Usuario no autenticado en ParentArchivedChatsController', tag: 'ArchivedChats');
      } else {
        ReleaseLogger.log('ParentArchivedChatsController inicializado para usuario: $_currentUserId', tag: 'ArchivedChats');
      }
    } catch (e) {
      ReleaseLogger.error('Error inicializando ParentArchivedChatsController: $e', tag: 'ArchivedChats');
    }
  }

  /// Desarchivar chat
  Future<bool> unarchiveChat(String chatId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para desarchivar chat', tag: 'ArchivedChats');
        return false;
      }

      final result = await _unarchiveService.call(chatId: chatId);

      if (result.success) {
        ReleaseLogger.log('Chat $chatId desarchivado exitosamente', tag: 'ArchivedChats');
      } else {
        ReleaseLogger.error('Error desarchivando chat $chatId: ${result.message}', tag: 'ArchivedChats');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error desarchivando chat: $e', tag: 'ArchivedChats');
      return false;
    }
  }

  /// Desarchivar grupo (usa el mismo servicio que chats - IDs son genéricos)
  Future<bool> unarchiveGroup(String groupId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para desarchivar grupo', tag: 'ArchivedChats');
        return false;
      }

      final result = await _unarchiveService.call(chatId: groupId);

      if (result.success) {
        ReleaseLogger.log('Grupo $groupId desarchivado exitosamente', tag: 'ArchivedChats');
      } else {
        ReleaseLogger.error('Error desarchivando grupo $groupId: ${result.message}', tag: 'ArchivedChats');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error desarchivando grupo: $e', tag: 'ArchivedChats');
      return false;
    }
  }

  /// Obtener información de usuario desde Firestore
  Future<DocumentSnapshot> getUserDocument(String userId) async {
    try {
      return await _firestore
          .collection('users')
          .doc(userId)
          .get();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo documento de usuario $userId: $e', tag: 'ArchivedChats');
      rethrow;
    }
  }

  /// Stream para observar alias/nombre de contacto
  Stream<String> watchDisplayName(String userId, String realName) {
    try {
      return _aliasService.watchDisplayName(userId, realName);
    } catch (e) {
      ReleaseLogger.error('Error creando stream de nombre de usuario: $e', tag: 'ArchivedChats');
      return Stream.value(realName);
    }
  }

  /// Stream para verificar si un usuario está bloqueado por el usuario actual.
  /// Solo retorna true si el usuario actual fue quien bloqueó — el bloqueado
  /// no debe ver indicadores de bloqueo en su lista de chats.
  Stream<bool> isBlockedStream(String userId) {
    try {
      return _blockService.iBlockedStream(userId);
    } catch (e) {
      ReleaseLogger.error('Error creando stream de bloqueo: $e', tag: 'ArchivedChats');
      return Stream.value(false);
    }
  }

  /// Verificar si un chat fue limpiado
  bool isChatCleared(String chatId) {
    final clearedAt = _preferencesCache.getClearedAt(chatId);
    return clearedAt != null;
  }

  /// Obtener el otro participante de un chat
  String getOtherParticipant(List<String> participants) {
    try {
      final userId = currentUserIdSafe;
      return participants.firstWhere(
        (id) => id != userId,
        orElse: () => '',
      );
    } catch (e) {
      ReleaseLogger.error('Error obteniendo otro participante: $e', tag: 'ArchivedChats');
      return '';
    }
  }

  /// Formatear datos de usuario para UI
  Map<String, dynamic> formatUserData(DocumentSnapshot userSnapshot) {
    try {
      if (!userSnapshot.exists) {
        return {
          'realName': 'Usuario',
          'isOnline': false,
          'photoURL': null,
        };
      }

      final userData = userSnapshot.data() as Map<String, dynamic>?;
      if (userData == null) {
        return {
          'realName': 'Usuario',
          'isOnline': false,
          'photoURL': null,
        };
      }

      return {
        'realName': userData['name'] ?? 'Usuario',
        'isOnline': userData['isOnline'] ?? false,
        'photoURL': userData['photoURL'],
      };
    } catch (e) {
      ReleaseLogger.error('Error formateando datos de usuario: $e', tag: 'ArchivedChats');
      return {
        'realName': 'Usuario',
        'isOnline': false,
        'photoURL': null,
      };
    }
  }

  /// Logging para operaciones
  void logChatOperation(String operation, String chatId) {
    ReleaseLogger.log('$operation para chat: $chatId', tag: 'ArchivedChats');
  }

  /// Logging para errores
  void logError(String message, dynamic error) {
    ReleaseLogger.error('$message: $error', tag: 'ArchivedChats');
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ParentArchivedChatsController', tag: 'ArchivedChats');
    // No hay subscripciones que limpiar - los streams se manejan en la UI
  }
}

/// Clase auxiliar para devolver un QuerySnapshot vacío cuando no hay usuario
class _EmptyQuerySnapshot implements QuerySnapshot<Map<String, dynamic>> {
  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => [];

  @override
  List<DocumentChange<Map<String, dynamic>>> get docChanges => [];

  @override
  SnapshotMetadata get metadata => _EmptyMetadata();

  @override
  int get size => 0;
}

class _EmptyMetadata implements SnapshotMetadata {
  @override
  bool get hasPendingWrites => false;

  @override
  bool get isFromCache => true;
}
