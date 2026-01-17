import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
// ✅ Nuevos servicios atómicos
import '../services/chats/chat_services.dart';
import '../services/message_cache_service.dart';
import '../utils/release_logger.dart';

/// Controller para items de lista de chats
///
/// Responsabilidades:
/// - Gestionar operaciones de chat (archivar, silenciar, limpiar)
/// - Proporcionar streams de estado de usuario (online, silenciado)
/// - Manejar cache de mensajes
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en widgets
class ChatListItemController {
  final String chatId;
  final String userId;

  // ✅ Nuevos servicios atómicos
  final ArchiveChatService _archiveService;
  final MuteChatService _muteService;
  final UnmuteChatService _unmuteService;
  final ClearChatService _clearService;
  final ChatPreferencesCache _preferencesCache;
  final MessageCacheService _cacheService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;

  /// Constructor
  ChatListItemController({
    required this.chatId,
    required this.userId,
    ArchiveChatService? archiveService,
    MuteChatService? muteService,
    UnmuteChatService? unmuteService,
    ClearChatService? clearService,
    ChatPreferencesCache? preferencesCache,
    MessageCacheService? cacheService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _archiveService = archiveService ?? ArchiveChatService(),
       _muteService = muteService ?? MuteChatService(),
       _unmuteService = unmuteService ?? UnmuteChatService(),
       _clearService = clearService ?? ClearChatService(),
       _preferencesCache = preferencesCache ?? ChatPreferencesCache(),
       _cacheService = cacheService ?? MessageCacheService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getter para usuario actual
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;

  /// Inicializar el controller
  void initialize() {
    _currentUserId = _auth.currentUser?.uid;
    if (_currentUserId == null) {
      ReleaseLogger.warning('Usuario no autenticado en ChatListItemController', tag: 'ChatListItem');
    }
  }

  /// Archivar chat
  Future<bool> archiveChat() async {
    try {
      // ✅ Usar nuevo servicio atómico
      final result = await _archiveService.call(chatId: chatId);

      if (result.success) {
        ReleaseLogger.log('Chat $chatId archivado exitosamente', tag: 'ChatListItem');
      } else {
        ReleaseLogger.error('Error archivando chat $chatId: ${result.message}', tag: 'ChatListItem');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error archivando chat: $e', tag: 'ChatListItem');
      return false;
    }
  }

  /// Silenciar chat
  Future<bool> muteChat() async {
    try {
      // ✅ Usar nuevo servicio atómico
      final result = await _muteService.call(chatId: chatId);

      if (result.success) {
        ReleaseLogger.log('Chat $chatId silenciado exitosamente', tag: 'ChatListItem');
      } else {
        ReleaseLogger.error('Error silenciando chat $chatId: ${result.message}', tag: 'ChatListItem');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error silenciando chat: $e', tag: 'ChatListItem');
      return false;
    }
  }

  /// Desilenciar chat
  Future<bool> unmuteChat() async {
    try {
      // ✅ Usar nuevo servicio atómico
      final result = await _unmuteService.call(chatId: chatId);

      if (result.success) {
        ReleaseLogger.log('Chat $chatId desilenciado exitosamente', tag: 'ChatListItem');
      } else {
        ReleaseLogger.error('Error desilenciando chat $chatId: ${result.message}', tag: 'ChatListItem');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error desilenciando chat: $e', tag: 'ChatListItem');
      return false;
    }
  }

  /// Limpiar chat
  Future<bool> clearChat() async {
    try {
      // ✅ Usar nuevo servicio atómico
      final result = await _clearService.call(chatId: chatId);

      // Limpiar también el cache local
      if (result.success) {
        await _cacheService.clearChat(chatId);
        ReleaseLogger.log('Cache local limpiado para chat $chatId', tag: 'ChatListItem');
        ReleaseLogger.log('Chat $chatId limpiado exitosamente', tag: 'ChatListItem');
      } else {
        ReleaseLogger.error('Error limpiando chat $chatId: ${result.message}', tag: 'ChatListItem');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error limpiando chat: $e', tag: 'ChatListItem');
      return false;
    }
  }

  /// Stream para verificar si un chat está silenciado
  /// ✅ Usa ChatPreferencesCache local para evitar llamadas a Firestore
  Stream<bool> watchChatMuted() {
    try {
      // El cache local es síncrono, así que devolvemos un Stream.value
      // que emite el valor actual del cache
      final isMuted = _preferencesCache.isMuted(chatId);
      return Stream.value(isMuted);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo estado de chat silenciado: $e', tag: 'ChatListItem');
      return Stream.value(false);
    }
  }

  /// Stream para verificar el estado online del usuario
  Stream<DocumentSnapshot> getUserOnlineStatusStream() {
    try {
      return _firestore
          .collection('users')
          .doc(userId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de estado online: $e', tag: 'ChatListItem');
      // Retornar un stream que emite un documento vacío
      return Stream.value(_createEmptyDocumentSnapshot());
    }
  }

  /// Crear un DocumentSnapshot vacío para casos de error
  DocumentSnapshot _createEmptyDocumentSnapshot() {
    // Esto es un workaround para crear un DocumentSnapshot vacío
    // En un caso real deberíamos usar una factory o mock, pero por simplicidad:
    return _firestore.collection('_empty').doc('_empty').snapshots().first.then((snap) => snap as DocumentSnapshot) as DocumentSnapshot;
  }

  /// Verificar si un usuario está online desde los datos del snapshot
  bool isUserOnline(DocumentSnapshot userSnapshot) {
    try {
      if (!userSnapshot.exists || userSnapshot.data() == null) {
        return false;
      }

      final userData = userSnapshot.data() as Map<String, dynamic>;
      return userData['isOnline'] ?? false;
    } catch (e) {
      ReleaseLogger.error('Error verificando estado online: $e', tag: 'ChatListItem');
      return false;
    }
  }

  /// Verificar si un mensaje es propio
  bool isOwnMessage(String? messageUserId) {
    final userId = currentUserId;
    if (userId == null) return false;

    return messageUserId == userId;
  }

  /// Obtener el userId actual para uso en streams (con fallback)
  String getCurrentUserIdForStreams() {
    return currentUserId ?? '';
  }

  /// Verificar que el usuario esté autenticado
  bool get isUserAuthenticated => currentUserId != null;

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChatListItemController for chat: $chatId', tag: 'ChatListItem');
    // No hay recursos específicos que limpiar para servicios stateless
  }
}