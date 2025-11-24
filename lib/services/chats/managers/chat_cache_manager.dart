import 'dart:async';
import '../../../models/chat_message.dart';

/// Manager para gestión inteligente de cache de chats y mensajes
///
/// Responsabilidades:
/// - Cache en memoria de mensajes por chat
/// - Cache optimista para UX inmediata
/// - Gestión de TTL y limpieza automática
/// - Deduplicación y ordenamiento
/// - NO accede a Firestore directamente
class ChatCacheManager {
  // Cache principal de mensajes por chatId
  final Map<String, List<ChatMessage>> _messageCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static const Duration _cacheDuration = Duration(minutes: 5);

  // Cache optimista para mensajes temporales
  final Map<String, Map<String, ChatMessage>> _optimisticCache = {};

  // Métricas de cache
  int _cacheHits = 0;
  int _cacheMisses = 0;

  // Controllers para notificaciones de cambios
  final Map<String, StreamController<List<ChatMessage>>> _chatControllers = {};

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API - CACHE OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener mensajes del cache para un chat específico
  List<ChatMessage> getCachedMessages(String chatId) {
    if (_isCacheValid(chatId)) {
      _cacheHits++;
      return _mergeOptimisticMessages(chatId);
    }

    _cacheMisses++;
    return _mergeOptimisticMessages(chatId);
  }

  /// Actualizar cache de un chat con nuevos mensajes
  void updateCacheForChat(String chatId, List<ChatMessage> messages) {
    _messageCache[chatId] = List.from(messages); // Crear copia defensiva
    _cacheTimestamps[chatId] = DateTime.now();

    // Notificar cambios
    _notifyChangesForChat(chatId);
  }

  /// Stream reactivo de cambios para un chat específico
  Stream<List<ChatMessage>> getChatChangesStream(String chatId) {
    if (!_chatControllers.containsKey(chatId)) {
      _chatControllers[chatId] = StreamController<List<ChatMessage>>.broadcast();
    }

    return Stream.multi((controller) {
      // Emitir estado inicial inmediatamente
      controller.add(getCachedMessages(chatId));

      // Luego escuchar cambios futuros
      final subscription = _chatControllers[chatId]!.stream.listen(
        controller.add,
        onError: controller.addError,
      );

      // Cleanup cuando se cancela la suscripción
      controller.onCancel = () => subscription.cancel();
    });
  }

  /// Verificar si el cache de un chat es válido
  bool isCacheValidForChat(String chatId) => _isCacheValid(chatId);

  /// Invalidar cache de un chat específico
  void invalidateChatCache(String chatId) {
    _messageCache.remove(chatId);
    _cacheTimestamps.remove(chatId);
    _notifyChangesForChat(chatId);
  }

  /// Invalidar todo el cache
  void clearAllCache() {
    _messageCache.clear();
    _cacheTimestamps.clear();
    _optimisticCache.clear();

    // Notificar todos los chats
    for (final chatId in _chatControllers.keys) {
      _notifyChangesForChat(chatId);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // OPTIMISTIC CACHE - Para UX inmediata
  // ═══════════════════════════════════════════════════════════════

  /// Agregar mensaje optimista (aparece inmediatamente en UI)
  void addOptimisticMessage(String chatId, ChatMessage message) {
    if (!_optimisticCache.containsKey(chatId)) {
      _optimisticCache[chatId] = {};
    }

    _optimisticCache[chatId]![message.id] = message;
    _notifyChangesForChat(chatId);
  }

  /// Actualizar mensaje optimista (ej: cuando upload completa)
  void updateOptimisticMessage(String chatId, String messageId, ChatMessage updatedMessage) {
    if (_optimisticCache[chatId]?.containsKey(messageId) == true) {
      _optimisticCache[chatId]![messageId] = updatedMessage;
      _notifyChangesForChat(chatId);
    }
  }

  /// Remover mensaje optimista (ej: cuando envío falla)
  void removeOptimisticMessage(String chatId, String messageId) {
    _optimisticCache[chatId]?.remove(messageId);

    if (_optimisticCache[chatId]?.isEmpty == true) {
      _optimisticCache.remove(chatId);
    }

    _notifyChangesForChat(chatId);
  }

  /// Limpiar cache optimista de un chat
  void clearOptimisticCacheForChat(String chatId) {
    _optimisticCache.remove(chatId);
    _notifyChangesForChat(chatId);
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Actualizar mensaje específico en cache
  void updateMessage(String chatId, String messageId, Map<String, dynamic> updates) {
    // Actualizar en cache principal
    final messages = _messageCache[chatId];
    if (messages != null) {
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].id == messageId) {
          // Crear nuevo mensaje con updates (usando constructor ChatMessage)
          messages[i] = ChatMessage(
            id: messages[i].id,
            senderId: messages[i].senderId,
            text: updates['content'] as String? ?? messages[i].text,
            imageUrl: messages[i].imageUrl,
            videoUrl: messages[i].videoUrl,
            audioUrl: messages[i].audioUrl,
            timestamp: messages[i].timestamp,
            isRead: messages[i].isRead,
            replyTo: messages[i].replyTo,
            reactions: messages[i].reactions,
            type: messages[i].type,
            status: messages[i].status,
            localTimestamp: messages[i].localTimestamp,
            localPath: messages[i].localPath,
            // Agregar campos de edición si están soportados
          );
          break;
        }
      }
    }

    // También actualizar en cache optimista si existe
    if (_optimisticCache[chatId]?.containsKey(messageId) == true) {
      final currentMessage = _optimisticCache[chatId]![messageId]!;
      _optimisticCache[chatId]![messageId] = ChatMessage(
        id: currentMessage.id,
        senderId: currentMessage.senderId,
        text: updates['content'] as String? ?? currentMessage.text,
        imageUrl: currentMessage.imageUrl,
        videoUrl: currentMessage.videoUrl,
        audioUrl: currentMessage.audioUrl,
        timestamp: currentMessage.timestamp,
        isRead: currentMessage.isRead,
        replyTo: currentMessage.replyTo,
        reactions: currentMessage.reactions,
        type: currentMessage.type,
        status: currentMessage.status,
        localTimestamp: currentMessage.localTimestamp,
        localPath: currentMessage.localPath,
      );
    }

    _notifyChangesForChat(chatId);
  }

  /// Remover mensaje específico del cache
  void removeMessage(String chatId, String messageId) {
    // Remover del cache principal
    final messages = _messageCache[chatId];
    if (messages != null) {
      messages.removeWhere((message) => message.id == messageId);
    }

    // Remover del cache optimista
    _optimisticCache[chatId]?.remove(messageId);

    _notifyChangesForChat(chatId);
  }

  /// Agregar mensaje al cache de un chat
  void addMessageToChat(String chatId, ChatMessage message) {
    if (!_messageCache.containsKey(chatId)) {
      _messageCache[chatId] = [];
    }

    // Evitar duplicados
    final existingIndex = _messageCache[chatId]!
        .indexWhere((msg) => msg.id == message.id);

    if (existingIndex != -1) {
      _messageCache[chatId]![existingIndex] = message;
    } else {
      _messageCache[chatId]!.insert(0, message); // Nuevos mensajes al principio
    }

    _notifyChangesForChat(chatId);
  }

  // ═══════════════════════════════════════════════════════════════
  // METRICS & DEBUGGING
  // ═══════════════════════════════════════════════════════════════

  /// Obtener métricas del cache
  Map<String, dynamic> getMetrics() {
    return {
      'cacheHits': _cacheHits,
      'cacheMisses': _cacheMisses,
      'cacheHitRate': _cacheHits + _cacheMisses > 0
          ? _cacheHits / (_cacheHits + _cacheMisses)
          : 0.0,
      'cachedChatsCount': _messageCache.length,
      'optimisticChatsCount': _optimisticCache.length,
      'activeStreamCount': _chatControllers.length,
    };
  }

  /// Obtener cache hit rate
  double getCacheHitRate() {
    final total = _cacheHits + _cacheMisses;
    return total > 0 ? _cacheHits / total : 0.0;
  }

  /// Obtener número de chats en cache
  int getCachedChatsCount() => _messageCache.length;

  /// Reset métricas
  void resetMetrics() {
    _cacheHits = 0;
    _cacheMisses = 0;
  }

  // ═══════════════════════════════════════════════════════════════
  // PRIVATE HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si cache de un chat es válido
  bool _isCacheValid(String chatId) {
    final timestamp = _cacheTimestamps[chatId];
    return _messageCache.containsKey(chatId) &&
           timestamp != null &&
           DateTime.now().difference(timestamp) < _cacheDuration;
  }

  /// Combinar cache principal con cache optimista para un chat
  ///
  /// ✅ FIX: Deduplicación usando localId para evitar duplicados
  /// cuando mensaje optimista (tempId) y mensaje real (firestoreId) coexisten
  List<ChatMessage> _mergeOptimisticMessages(String chatId) {
    final mainMessages = _messageCache[chatId] ?? <ChatMessage>[];
    final optimisticMessages = _optimisticCache[chatId]?.values.toList() ?? <ChatMessage>[];

    // Combinar y deduplicar
    final allMessages = <ChatMessage>[];
    final seenIds = <String>{};
    final seenLocalIds = <String>{}; // ✅ NEW: Track localIds from main messages

    // Primero, recolectar todos los localIds de mensajes principales (de Firestore)
    for (final message in mainMessages) {
      if (message.localId != null) {
        seenLocalIds.add(message.localId!);
      }
    }

    // Agregar mensajes del cache principal PRIMERO (tienen precedencia - son los reales de Firestore)
    for (final message in mainMessages) {
      if (!seenIds.contains(message.id)) {
        allMessages.add(message);
        seenIds.add(message.id);
      }
    }

    // Agregar mensajes optimistas SOLO si NO duplican (no existe mensaje real con su localId)
    for (final message in optimisticMessages) {
      // ✅ Skip si ya existe un mensaje real cuyo localId matchea este tempId
      if (seenLocalIds.contains(message.id)) {
        // Este mensaje optimista ya tiene su versión real en Firestore
        continue;
      }

      // Skip si ya existe por ID
      if (!seenIds.contains(message.id)) {
        allMessages.add(message);
        seenIds.add(message.id);
      }
    }

    // Ordenar por fecha (más recientes primero) - usar timestamp o localTimestamp
    allMessages.sort((a, b) {
      final aTime = a.localTimestamp ?? a.timestamp?.toDate() ?? DateTime.now();
      final bTime = b.localTimestamp ?? b.timestamp?.toDate() ?? DateTime.now();
      return bTime.compareTo(aTime);
    });

    return allMessages;
  }

  /// Notificar cambios en un chat específico
  void _notifyChangesForChat(String chatId) {
    if (_chatControllers[chatId] != null && !_chatControllers[chatId]!.isClosed) {
      _chatControllers[chatId]!.add(getCachedMessages(chatId));
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar recursos
  void dispose() {
    for (final controller in _chatControllers.values) {
      controller.close();
    }
    _chatControllers.clear();
    _messageCache.clear();
    _cacheTimestamps.clear();
    _optimisticCache.clear();
    resetMetrics();
  }
}