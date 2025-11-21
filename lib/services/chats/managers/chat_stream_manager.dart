import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../repositories/chat_repository.dart';
import '../repositories/message_repository.dart';
import 'chat_cache_manager.dart';
import '../../../models/chat_message.dart';
import '../../../utils/release_logger.dart';
import '../chat_orchestrator.dart';
import '../../unread_messages_service.dart';
import '../../read_receipts_service.dart';
import '../../message_cache_service.dart';

/// Manager para coordinación de streams de chats
///
/// Responsabilidades:
/// - Coordinar streams de Firestore con cache
/// - Gestionar background updates
/// - Optimizar queries y reducir rebuilds
/// - NO mezcla responsabilidades de cache y streams
class ChatStreamManager {
  final ChatRepository _chatRepository;
  final MessageRepository _messageRepository;
  final ChatCacheManager _cacheManager;
  final UnreadMessagesService _unreadService;

  // Background stream management
  bool _isBackgroundStreamActive = false;
  final Map<String, StreamSubscription> _messageStreamSubscriptions = {};
  final Map<String, bool> _chatIsGroupMap = {}; // Mapea chatId -> isGroup
  StreamSubscription? _chatListSubscription;

  // Stream controllers
  final Map<String, StreamController<List<ChatMessage>>> _messageControllers = {};
  final StreamController<List<Chat>> _chatListController =
      StreamController<List<Chat>>.broadcast();

  // Cache change notification controllers (for cache-first architecture)
  final Map<String, StreamController<void>> _cacheChangeControllers = {};

  // Performance tracking
  int _activeStreamCount = 0;
  DateTime? _lastRefresh;

  // Performance optimization: rate limiting
  final Map<String, DateTime> _lastUpdateTimes = {};
  static const Duration _rateLimitDuration = Duration(milliseconds: 500);

  ChatStreamManager({
    required ChatRepository chatRepository,
    required MessageRepository messageRepository,
    required ChatCacheManager cacheManager,
    UnreadMessagesService? unreadService,
  }) : _chatRepository = chatRepository,
       _messageRepository = messageRepository,
       _cacheManager = cacheManager,
       _unreadService = unreadService ?? UnreadMessagesService();

  // ═══════════════════════════════════════════════════════════════
  // STREAM MANAGEMENT - MESSAGES
  // ═══════════════════════════════════════════════════════════════

  /// Obtener stream de mensajes para un chat específico
  Stream<List<ChatMessage>> getMessagesStream(String chatId, {bool isGroup = false}) {
    // Si ya existe un controller, reutilizar
    if (_messageControllers.containsKey(chatId)) {
      return _messageControllers[chatId]!.stream;
    }

    // Crear nuevo controller
    final controller = StreamController<List<ChatMessage>>.broadcast();
    _messageControllers[chatId] = controller;

    // Guardar si es grupo para futuros refreshes
    _chatIsGroupMap[chatId] = isGroup;

    // Configurar stream de Firestore
    _setupMessageStream(chatId, controller, isGroup: isGroup);

    _activeStreamCount++;
    return controller.stream;
  }

  /// Watch for cache changes for a specific chat (CACHE-FIRST ARCHITECTURE)
  /// This ONLY notifies when cache is updated, doesn't emit data
  Stream<void> watchCacheChanges(String chatId) {
    if (!_cacheChangeControllers.containsKey(chatId)) {
      _cacheChangeControllers[chatId] = StreamController<void>.broadcast();
      ReleaseLogger.log('Created cache change controller for chat $chatId');
    }
    return _cacheChangeControllers[chatId]!.stream;
  }

  /// Ensure Firestore listener is active for a chat (without returning stream)
  /// This is used by cache-first architecture to start background sync
  void ensureListenerActive(String chatId, {bool isGroup = false}) {
    // If controller already exists, listener is already active
    if (_messageControllers.containsKey(chatId)) {
      ReleaseLogger.log('Firestore listener already active for chat $chatId');
      return;
    }

    // Create controller and start listener
    final controller = StreamController<List<ChatMessage>>.broadcast();
    _messageControllers[chatId] = controller;
    _chatIsGroupMap[chatId] = isGroup;

    _setupMessageStream(chatId, controller, isGroup: isGroup);
    _activeStreamCount++;

    ReleaseLogger.log('Started Firestore listener for chat $chatId (isGroup: $isGroup)');
  }

  /// Configurar stream de mensajes desde Firestore
  void _setupMessageStream(String chatId, StreamController<List<ChatMessage>> controller, {bool isGroup = false}) {
    final firestoreStream = _messageRepository.watchMessages(chatId: chatId, isGroup: isGroup, limit: 50);

    final subscription = firestoreStream.listen(
      (snapshot) async {
        try {
          // Rate limiting para evitar rebuilds excesivos
          if (_shouldRateLimit(chatId)) {
            return;
          }
          _lastUpdateTimes[chatId] = DateTime.now();

          // ✅ FIX: Get current user ID for status calculation
          final currentUserId = FirebaseAuth.instance.currentUser?.uid;

          // Convertir QuerySnapshot a List<ChatMessage>
          final messages = snapshot.docs
              .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
              .toList();

          // ✅ CRITICAL: Save to Hive cache (persistent) - CACHE-FIRST ARCHITECTURE
          await MessageCacheService().saveMessages(chatId, messages);
          ReleaseLogger.log('Saved ${messages.length} messages to Hive cache for chat $chatId');

          // ✅ Notify cache change listeners (no data emission, just notification)
          if (_cacheChangeControllers.containsKey(chatId) &&
              !_cacheChangeControllers[chatId]!.isClosed) {
            _cacheChangeControllers[chatId]!.add(null);
            ReleaseLogger.log('Notified cache change for chat $chatId');
          }

          // Actualizar cache in-memory (for quick access)
          _cacheManager.updateCacheForChat(chatId, messages);

          // ✅ NUEVA LÓGICA CENTRALIZADA: Detectar mensajes nuevos y actualizar contadores
          await _handleNewMessagesDetected(chatId, messages, isGroup: isGroup);

          // Combinar con cache optimista
          final finalMessages = _cacheManager.getCachedMessages(chatId);

          // Emitir al stream (legacy compatibility)
          if (!controller.isClosed) {
            controller.add(finalMessages);
          }
        } catch (e) {
          ReleaseLogger.error('Error en stream de mensajes para chat $chatId: $e');
          if (!controller.isClosed) {
            controller.addError(e);
          }
        }
      },
      onError: (error) {
        ReleaseLogger.error('Error en Firestore stream para chat $chatId: $error');
        if (!controller.isClosed) {
          controller.addError(error);
        }
      },
    );

    _messageStreamSubscriptions[chatId] = subscription;
  }

  /// Verificar si debemos aplicar rate limiting
  bool _shouldRateLimit(String chatId) {
    final lastUpdate = _lastUpdateTimes[chatId];
    if (lastUpdate == null) return false;

    final timeSinceLastUpdate = DateTime.now().difference(lastUpdate);
    return timeSinceLastUpdate < _rateLimitDuration;
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAM MANAGEMENT - CHAT LIST
  // ═══════════════════════════════════════════════════════════════

  /// Obtener stream de lista de chats del usuario
  Stream<List<Chat>> getChatListStream() {
    if (_chatListSubscription == null) {
      _setupChatListStream();
    }
    return _chatListController.stream;
  }

  /// Configurar stream de lista de chats
  void _setupChatListStream() {
    final firestoreStream = _chatRepository.getUserChatsStream();

    _chatListSubscription = firestoreStream.listen(
      (snapshot) async {
        try {
          // Convertir QuerySnapshot a List<Chat> (usando modelo simple)
          final chats = snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return Chat(
              id: doc.id,
              type: data['type'] ?? 'individual',
              name: data['name'] ?? '',
              participants: List<String>.from(data['participants'] ?? []),
              lastActivity: (data['lastActivity'] as Timestamp?)?.toDate() ?? DateTime.now(),
              unreadCount: data['unreadCount'] ?? 0,
            );
          }).toList();

          // Emitir al stream
          if (!_chatListController.isClosed) {
            _chatListController.add(chats);
          }
        } catch (e) {
          ReleaseLogger.error('Error en stream de lista de chats: $e');
          if (!_chatListController.isClosed) {
            _chatListController.addError(e);
          }
        }
      },
      onError: (error) {
        ReleaseLogger.error('Error en Firestore stream de chats: $error');
        if (!_chatListController.isClosed) {
          _chatListController.addError(error);
        }
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // BACKGROUND STREAMS MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar background streams
  Future<void> startBackgroundStreams() async {
    if (_isBackgroundStreamActive) {
      return; // Ya están activos
    }

    try {
      // Inicializar stream de lista de chats
      _setupChatListStream();

      _isBackgroundStreamActive = true;
      _lastRefresh = DateTime.now();

      ReleaseLogger.info('Chat background streams iniciados');
    } catch (e) {
      ReleaseLogger.error('Error iniciando background streams: $e');
      throw Exception('Failed to start background streams: $e');
    }
  }

  /// Detener background streams
  void stopBackgroundStreams() {
    if (!_isBackgroundStreamActive) {
      return; // Ya están detenidos
    }

    try {
      // Detener stream de chats
      _chatListSubscription?.cancel();
      _chatListSubscription = null;

      // Detener streams de mensajes
      for (final subscription in _messageStreamSubscriptions.values) {
        subscription.cancel();
      }
      _messageStreamSubscriptions.clear();

      // Cerrar controllers
      for (final controller in _messageControllers.values) {
        controller.close();
      }
      _messageControllers.clear();
      _chatIsGroupMap.clear();

      _isBackgroundStreamActive = false;
      _activeStreamCount = 0;

      ReleaseLogger.info('Chat background streams detenidos');
    } catch (e) {
      ReleaseLogger.error('Error deteniendo background streams: $e');
    }
  }

  /// Forzar refresh de todos los streams activos
  Future<void> forceRefresh() async {
    try {
      // Invalidar cache
      _cacheManager.clearAllCache();

      // Re-setup streams activos
      final activeChatIds = List.from(_messageControllers.keys);

      for (final chatId in activeChatIds) {
        await _refreshChatStream(chatId);
      }

      // Refresh chat list
      if (_chatListSubscription != null) {
        _setupChatListStream();
      }

      _lastRefresh = DateTime.now();
      ReleaseLogger.info('Force refresh completado para ${activeChatIds.length} chats');
    } catch (e) {
      ReleaseLogger.error('Error en force refresh: $e');
      throw Exception('Failed to force refresh streams: $e');
    }
  }

  /// Refresh stream específico de un chat
  Future<void> _refreshChatStream(String chatId) async {
    // Cancelar stream existente
    _messageStreamSubscriptions[chatId]?.cancel();

    // Re-crear stream
    final controller = _messageControllers[chatId];
    final isGroup = _chatIsGroupMap[chatId] ?? false;

    if (controller != null && !controller.isClosed) {
      _setupMessageStream(chatId, controller, isGroup: isGroup);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener número de streams activos
  int getActiveStreamCount() => _activeStreamCount;

  /// Verificar si background streams están activos
  bool get isBackgroundActive => _isBackgroundStreamActive;

  /// Obtener timestamp del último refresh
  DateTime? get lastRefreshTime => _lastRefresh;

  /// Cleanup al cerrar un chat específico
  void closeChatStream(String chatId) {
    _messageStreamSubscriptions[chatId]?.cancel();
    _messageStreamSubscriptions.remove(chatId);

    _messageControllers[chatId]?.close();
    _messageControllers.remove(chatId);

    // Close cache change controller too
    _cacheChangeControllers[chatId]?.close();
    _cacheChangeControllers.remove(chatId);

    _chatIsGroupMap.remove(chatId);
    _lastUpdateTimes.remove(chatId);
    _activeStreamCount = _messageControllers.length;
  }

  // ═══════════════════════════════════════════════════════════════
  // UNREAD COUNT MANAGEMENT - NUEVA LÓGICA CENTRALIZADA
  // ═══════════════════════════════════════════════════════════════

  /// Manejar mensajes nuevos detectados y actualizar contadores
  Future<void> _handleNewMessagesDetected(String chatId, List<ChatMessage> messages, {bool isGroup = false}) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      final currentUserId = currentUser.uid;

      // Filtrar mensajes que NO sean del usuario actual (mensajes recibidos)
      final receivedMessages = messages.where((message) =>
        message.senderId != currentUserId
      ).toList();

      if (receivedMessages.isEmpty) {
        // No hay mensajes nuevos de otros usuarios
        return;
      }

      ReleaseLogger.log('📊 [ChatStreamManager] Detectados ${receivedMessages.length} mensajes recibidos en ${isGroup ? 'grupo' : 'chat'} $chatId');

      // ✅ PASO 1: Verificar si el usuario está viendo este chat actualmente
      final currentChatId = await _getCurrentActiveChatId();
      if (currentChatId != null && currentChatId == chatId) {
        ReleaseLogger.log('📱 [ChatStreamManager] Usuario está en chat $chatId - marcando como leído automáticamente');

        // Marcar mensajes como leídos automáticamente
        await _markMessagesAsSeenIfActive(chatId, isGroup);

        // Poner contador en 0 automáticamente
        await _updateUnreadCountInFirestore(chatId, currentUserId, 0, isGroup: isGroup);
        await _unreadService.updateBadgeCount();
        return; // No necesitamos calcular contador
      }

      // ✅ PASO 2: Si no está en el chat, consultar cache para contar no leídos
      final cachedMessages = _cacheManager.getCachedMessages(chatId);

      // ✅ PASO 3: Contar solo mensajes no leídos (usando sistema de read receipts)
      int unreadCount = 0;
      for (final cachedMessage in cachedMessages) {
        if (cachedMessage.senderId != currentUserId) {
          // Verificar si este mensaje específico está marcado como leído
          final isMessageRead = await _isMessageRead(chatId, cachedMessage.id, currentUserId, isGroup);
          if (!isMessageRead) {
            unreadCount++;
          }
        }
      }

      ReleaseLogger.log('📊 [ChatStreamManager] Calculado $unreadCount mensajes sin leer en ${isGroup ? 'grupo' : 'chat'} $chatId');

      // Actualizar contador en Firestore
      await _updateUnreadCountInFirestore(chatId, currentUserId, unreadCount, isGroup: isGroup);

      // Actualizar badge global
      await _unreadService.updateBadgeCount();

    } catch (e) {
      ReleaseLogger.error('❌ Error manejando mensajes nuevos en chat $chatId: $e');
    }
  }

  /// Obtener el chat ID que el usuario está viendo actualmente
  Future<String?> _getCurrentActiveChatId() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Intentar diferentes claves (como en el Android service)
      String? currentChatId = prefs.getString('flutter.current_chat_id');
      currentChatId ??= prefs.getString('current_chat_id');

      ReleaseLogger.log('📱 [ChatStreamManager] Chat activo detectado: $currentChatId');
      return currentChatId;
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo chat activo: $e');
      return null;
    }
  }

  /// Marcar mensajes como leídos si el usuario está activo en el chat
  Future<void> _markMessagesAsSeenIfActive(String chatId, bool isGroup) async {
    try {
      final readReceiptsService = ReadReceiptsService();
      await readReceiptsService.markMessagesAsSeen(
        chatId: chatId,
        isGroupChat: isGroup
      );

      ReleaseLogger.log('✅ [ChatStreamManager] Mensajes marcados como leídos en ${isGroup ? 'grupo' : 'chat'} $chatId');
    } catch (e) {
      ReleaseLogger.error('❌ Error marcando mensajes como leídos: $e');
    }
  }

  /// Verificar si un mensaje específico está marcado como leído
  Future<bool> _isMessageRead(String chatId, String messageId, String userId, bool isGroup) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      final messageDoc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get();

      if (!messageDoc.exists) return false;

      final messageData = messageDoc.data();
      final readBy = List<String>.from(messageData?['readBy'] ?? []);
      final isRead = readBy.contains(userId);

      return isRead;
    } catch (e) {
      ReleaseLogger.error('❌ Error verificando si mensaje está leído: $e');
      // En caso de error, asumir que no está leído (más conservativo)
      return false;
    }
  }

  /// Actualizar contador de no leídos en Firestore
  Future<void> _updateUnreadCountInFirestore(String chatId, String userId, int unreadCount, {bool isGroup = false}) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      await FirebaseFirestore.instance
          .collection(collection)
          .doc(chatId)
          .update({
        'unreadCount_$userId': unreadCount,
      });

      ReleaseLogger.log('✅ [ChatStreamManager] Contador actualizado en Firestore: ${isGroup ? 'grupo' : 'chat'} $chatId, user $userId, count $unreadCount');
    } catch (e) {
      ReleaseLogger.error('❌ Error actualizando contador en Firestore: $e');
    }
  }

  /// Dispose completo
  void dispose() {
    stopBackgroundStreams();
    _chatListController.close();

    // Close all cache change controllers
    for (final controller in _cacheChangeControllers.values) {
      controller.close();
    }
    _cacheChangeControllers.clear();

    _chatIsGroupMap.clear();
    _lastUpdateTimes.clear();
  }
}