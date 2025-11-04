import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/chat_archive_service.dart';
import '../services/contact_alias_service.dart';
import '../services/block_service.dart';
import '../utils/release_logger.dart';

/// Controller para la pantalla de chats archivados de padres
///
/// Responsabilidades:
/// - Gestionar autenticación de usuario
/// - Obtener información de usuarios (Firestore)
/// - Manejar operaciones de archivado/desarchivado
/// - Proporcionar streams de servicios
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ParentArchivedChatsController {
  // Servicios privados
  final ChatArchiveService _archiveService;
  final ContactAliasService _aliasService;
  final BlockService _blockService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;

  /// Constructor
  ParentArchivedChatsController({
    ChatArchiveService? archiveService,
    ContactAliasService? aliasService,
    BlockService? blockService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _archiveService = archiveService ?? ChatArchiveService(),
       _aliasService = aliasService ?? ContactAliasService(),
       _blockService = blockService ?? BlockService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  String get currentUserIdSafe => currentUserId ?? '';
  bool get isUserAuthenticated => currentUserId != null;

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

  /// Stream de chats archivados
  Stream<QuerySnapshot> getArchivedChatsStream() {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para stream de chats archivados', tag: 'ArchivedChats');
        return Stream.empty();
      }

      return _archiveService.getArchivedChatsStream(userId);
    } catch (e) {
      ReleaseLogger.error('Error creando stream de chats archivados: $e', tag: 'ArchivedChats');
      return Stream.empty();
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

      final success = await _archiveService.unarchiveChat(
        chatId: chatId,
        userId: userId,
      );

      if (success) {
        ReleaseLogger.log('Chat $chatId desarchivado exitosamente', tag: 'ArchivedChats');
      } else {
        ReleaseLogger.error('Error desarchivando chat $chatId', tag: 'ArchivedChats');
      }

      return success;
    } catch (e) {
      ReleaseLogger.error('Error desarchivando chat: $e', tag: 'ArchivedChats');
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
      // Crear un documento vacío en caso de error
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

  /// Stream para verificar si un usuario está bloqueado
  Stream<bool> isBlockedStream(String userId) {
    try {
      return _blockService.isBlockedStream(userId);
    } catch (e) {
      ReleaseLogger.error('Error creando stream de bloqueo: $e', tag: 'ArchivedChats');
      return Stream.value(false);
    }
  }

  /// Verificar si un chat fue limpiado
  bool isChatCleared(Map<String, dynamic> chatData) {
    try {
      final parentId = currentUserIdSafe;
      final clearedAt = chatData['clearedAt_$parentId'] as Timestamp?;
      final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;

      return clearedAt != null &&
          (lastMessageTime == null || clearedAt.compareTo(lastMessageTime) >= 0);
    } catch (e) {
      ReleaseLogger.error('Error verificando si chat está limpio: $e', tag: 'ArchivedChats');
      return false;
    }
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

  /// Ordenar chats archivados por última actividad
  List<QueryDocumentSnapshot> sortChatsByLastActivity(List<QueryDocumentSnapshot> chats) {
    try {
      final sortedChats = List<QueryDocumentSnapshot>.from(chats);
      sortedChats.sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;
        final aTime = aData['lastMessageTime'] as Timestamp?;
        final bTime = bData['lastMessageTime'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      return sortedChats;
    } catch (e) {
      ReleaseLogger.error('Error ordenando chats: $e', tag: 'ArchivedChats');
      return chats;
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
    // No hay recursos específicos que limpiar para servicios stateless
  }
}