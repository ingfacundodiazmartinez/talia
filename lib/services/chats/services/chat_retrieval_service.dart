import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/chat_message.dart';
import '../chat_orchestrator.dart';
import '../managers/chat_stream_manager.dart';
import '../managers/chat_cache_manager.dart';
import '../repositories/chat_repository.dart';
import '../repositories/message_repository.dart';
import '../../../utils/release_logger.dart';
import '../../../services/message_cache_service.dart';

/// Servicio especializado para recuperación y búsqueda de datos de chat
///
/// Responsabilidades:
/// - Coordinar streams de mensajes con cache
/// - Búsqueda de mensajes en chats
/// - Paginación de mensajes históricos
/// - Gestión de estado de lectura
class ChatRetrievalService {
  final ChatStreamManager _streamManager;
  final ChatCacheManager _cacheManager;
  final ChatRepository _chatRepository;
  final MessageRepository _messageRepository;

  ChatRetrievalService({
    required ChatStreamManager streamManager,
    required ChatCacheManager cacheManager,
    required ChatRepository chatRepository,
    required MessageRepository? messageRepository,
  }) : _streamManager = streamManager,
       _cacheManager = cacheManager,
       _chatRepository = chatRepository,
       _messageRepository = messageRepository ?? MessageRepository(
         firestore: FirebaseFirestore.instance,
         auth: FirebaseAuth.instance,
       );

  // ═══════════════════════════════════════════════════════════════
  // STREAMS DE DATOS EN TIEMPO REAL
  // ═══════════════════════════════════════════════════════════════

  /// Watch messages for a chat (CACHE-FIRST)
  ///
  /// This stream emits:
  /// 1. Initial data from Hive cache (instant, works offline)
  /// 2. Updates when background listener updates cache
  Stream<List<ChatMessage>> watchMessages(String chatId) async* {
    ReleaseLogger.log('📖 [ChatRetrieval] Reading messages from cache for chat $chatId');

    // STEP 1: Emit initial cached data immediately (from Hive)
    final cachedMessages = await MessageCacheService().getMessages(chatId);
    yield cachedMessages;
    ReleaseLogger.log('✅ [ChatRetrieval] Emitted ${cachedMessages.length} cached messages for chat $chatId');

    // STEP 2: Ensure background Firestore listener is active
    // This will automatically update the cache when Firestore changes
    _streamManager.ensureListenerActive(chatId);

    // STEP 3: Listen for cache updates from background listener
    await for (final _ in _streamManager.watchCacheChanges(chatId)) {
      final updatedMessages = await MessageCacheService().getMessages(chatId);
      yield updatedMessages;
      ReleaseLogger.log('🔄 [ChatRetrieval] Cache updated: ${updatedMessages.length} messages for chat $chatId');
    }
  }

  /// Get messages synchronously from cache (for one-time reads)
  Future<List<ChatMessage>> getMessagesFromCache(String chatId) async {
    ReleaseLogger.log('Getting messages from cache for chat $chatId');
    return await MessageCacheService().getMessages(chatId);
  }

  /// Obtener stream de mensajes de un chat específico (LEGACY - for backwards compatibility)
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    try {
      // For now, use the new cache-first method
      return watchMessages(chatId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de mensajes: $e', tag: 'ChatRetrieval');
      // Retornar stream vacío en caso de error
      return Stream.value([]);
    }
  }

  /// Obtener stream de lista de chats del usuario
  Stream<List<Chat>> getUserChatsStream() {
    try {
      return _streamManager.getChatListStream();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de chats: $e', tag: 'ChatRetrieval');
      // Retornar stream vacío en caso de error
      return Stream.value([]);
    }
  }

  /// Obtener stream de cambios específico de un chat (desde cache)
  Stream<List<ChatMessage>> getChatChangesStream(String chatId) {
    try {
      return _cacheManager.getChatChangesStream(chatId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de cambios: $e', tag: 'ChatRetrieval');
      return Stream.value([]);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // BÚSQUEDA Y FILTRADO
  // ═══════════════════════════════════════════════════════════════

  /// Buscar mensajes en un chat específico
  Future<List<ChatMessage>> searchMessages({
    required String chatId,
    required String query,
    int limit = 50,
  }) async {
    try {
      // Primero buscar en cache local
      final cachedMessages = _cacheManager.getCachedMessages(chatId);

      if (cachedMessages.isNotEmpty) {
        final localResults = _searchInMessages(cachedMessages, query, limit);
        if (localResults.isNotEmpty) {
          ReleaseLogger.info('Búsqueda local encontró ${localResults.length} mensajes', tag: 'ChatRetrieval');
          return localResults;
        }
      }

      // Si no hay resultados locales, buscar en Firestore
      final firestoreSnapshot = await _messageRepository.searchMessages(
        chatId: chatId,
        query: query,
        limit: limit,
      );

      // ✅ FIX: Pass currentUserId for status calculation
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final firestoreResults = firestoreSnapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
          .toList();

      ReleaseLogger.info('Búsqueda Firestore encontró ${firestoreResults.length} mensajes', tag: 'ChatRetrieval');
      return firestoreResults;

    } catch (e) {
      ReleaseLogger.error('Error en búsqueda de mensajes: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  /// Buscar mensajes por tipo de contenido
  /// TODO: Implementar cuando MessageRepository tenga getMessagesByType
  Future<List<ChatMessage>> searchMessagesByType({
    required String chatId,
    required String messageType,
    int limit = 50,
  }) async {
    try {
      // Por ahora, filtrar del cache local
      final cachedMessages = _cacheManager.getCachedMessages(chatId);
      final filteredMessages = cachedMessages
          .where((message) => message.type == messageType)
          .take(limit)
          .toList();

      ReleaseLogger.info('Búsqueda por tipo \'$messageType\' encontró ${filteredMessages.length} mensajes en cache', tag: 'ChatRetrieval');
      return filteredMessages;

    } catch (e) {
      ReleaseLogger.error('Error buscando mensajes por tipo: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  /// Buscar en lista de mensajes local
  List<ChatMessage> _searchInMessages(List<ChatMessage> messages, String query, int limit) {
    final lowerQuery = query.toLowerCase();

    return messages
        .where((message) {
          // Buscar en texto del mensaje
          if (message.text != null && message.text!.toLowerCase().contains(lowerQuery)) {
            return true;
          }
          // Buscar en mensaje de respuesta si existe
          if (message.replyTo != null) {
            final replyText = message.replyTo!['text'] as String?;
            if (replyText != null && replyText.toLowerCase().contains(lowerQuery)) {
              return true;
            }
          }
          return false;
        })
        .take(limit)
        .toList();
  }

  // ═══════════════════════════════════════════════════════════════
  // PAGINACIÓN DE MENSAJES
  // ═══════════════════════════════════════════════════════════════

  /// Cargar mensajes anteriores (paginación)
  /// TODO: Implementar cuando MessageRepository tenga getMessagesBeforeTimestamp
  Future<List<ChatMessage>> loadMoreMessages({
    required String chatId,
    ChatMessage? lastMessage,
    int limit = 20,
  }) async {
    try {
      // Por ahora implementación simple sin paginación real
      final snapshot = await _messageRepository.searchMessages(
        chatId: chatId,
        query: '', // Busqueda vacía para obtener todos
        limit: limit,
      );

      // ✅ FIX: Pass currentUserId for status calculation
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final messages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
          .toList();

      // Actualizar cache con mensajes cargados
      if (messages.isNotEmpty) {
        for (final message in messages) {
          _cacheManager.addMessageToChat(chatId, message);
        }
      }

      ReleaseLogger.info('Cargados ${messages.length} mensajes anteriores para chat $chatId', tag: 'ChatRetrieval');
      return messages;

    } catch (e) {
      ReleaseLogger.error('Error cargando mensajes anteriores: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  /// Cargar mensajes posteriores (hacia adelante)
  /// TODO: Implementar cuando tengamos método específico
  Future<List<ChatMessage>> loadNewerMessages({
    required String chatId,
    ChatMessage? sinceMessage,
    int limit = 20,
  }) async {
    try {
      // Por ahora retornar vacío - método placeholder
      ReleaseLogger.info('loadNewerMessages no implementado aún', tag: 'ChatRetrieval');
      return [];

    } catch (e) {
      ReleaseLogger.error('Error cargando mensajes nuevos: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ACCESO A CACHE Y DATOS OFFLINE
  // ═══════════════════════════════════════════════════════════════

  /// Obtener mensajes del cache (datos offline)
  List<ChatMessage> getCachedMessages(String chatId) {
    try {
      return _cacheManager.getCachedMessages(chatId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo mensajes del cache: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  /// Verificar si el cache es válido para un chat
  bool isCacheValidForChat(String chatId) {
    return _cacheManager.isCacheValidForChat(chatId);
  }

  /// Obtener información de un chat específico
  /// TODO: Adaptar cuando getChatById retorne Chat en lugar de DocumentSnapshot
  Future<Chat?> getChatInfo(String chatId) async {
    try {
      final doc = await _chatRepository.getChatById(chatId);
      if (doc != null && doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        return Chat(
          id: doc.id,
          type: data['type'] ?? 'individual',
          name: data['name'] ?? '',
          participants: List<String>.from(data['participants'] ?? []),
          lastActivity: (data['lastActivity'] as Timestamp?)?.toDate() ?? DateTime.now(),
          unreadCount: data['unreadCount'] ?? 0,
        );
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo info del chat: $e', tag: 'ChatRetrieval');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // FILTROS Y ORDENAMIENTO
  // ═══════════════════════════════════════════════════════════════

  /// Filtrar mensajes por rango de fechas
  /// TODO: Implementar cuando tengamos el método en repository
  Future<List<ChatMessage>> getMessagesByDateRange({
    required String chatId,
    required DateTime startDate,
    required DateTime endDate,
    int limit = 100,
  }) async {
    try {
      // Por ahora filtrar del cache local
      final cachedMessages = _cacheManager.getCachedMessages(chatId);
      final filteredMessages = cachedMessages.where((message) {
        final messageTime = message.localTimestamp ?? message.timestamp?.toDate();
        if (messageTime == null) return false;
        return messageTime.isAfter(startDate) && messageTime.isBefore(endDate);
      }).take(limit).toList();

      return filteredMessages;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo mensajes por fecha: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  /// Obtener mensajes no leídos de un chat
  /// TODO: Implementar con método específico
  Future<List<ChatMessage>> getUnreadMessages(String chatId) async {
    try {
      // Por ahora filtrar del cache
      final cachedMessages = _cacheManager.getCachedMessages(chatId);
      final unreadMessages = cachedMessages
          .where((message) => !message.isRead)
          .toList();

      return unreadMessages;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo mensajes no leídos: $e', tag: 'ChatRetrieval');
      return [];
    }
  }

  /// Obtener estadísticas del chat
  /// TODO: Implementar con métodos específicos del repository
  Future<ChatStats> getChatStats(String chatId) async {
    try {
      // Por ahora usar cache para estadísticas básicas
      final cachedMessages = _cacheManager.getCachedMessages(chatId);
      final totalMessages = cachedMessages.length;
      final unreadCount = cachedMessages.where((msg) => !msg.isRead).length;
      final lastMessage = cachedMessages.isNotEmpty ? cachedMessages.first : null;

      return ChatStats(
        totalMessages: totalMessages,
        unreadCount: unreadCount,
        lastMessageTime: lastMessage?.localTimestamp ?? lastMessage?.timestamp?.toDate(),
      );
    } catch (e) {
      ReleaseLogger.error('Error obteniendo estadísticas del chat: $e', tag: 'ChatRetrieval');
      return ChatStats(totalMessages: 0, unreadCount: 0);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Invalidar y refrescar cache de un chat
  Future<void> refreshChatData(String chatId) async {
    try {
      _cacheManager.invalidateChatCache(chatId);
      await _streamManager.forceRefresh();
      ReleaseLogger.info('Cache del chat $chatId refrescado', tag: 'ChatRetrieval');
    } catch (e) {
      ReleaseLogger.error('Error refrescando datos del chat: $e', tag: 'ChatRetrieval');
    }
  }

  /// Cerrar stream específico de un chat
  void closeChatStream(String chatId) {
    try {
      _streamManager.closeChatStream(chatId);
      ReleaseLogger.info('Stream del chat $chatId cerrado', tag: 'ChatRetrieval');
    } catch (e) {
      ReleaseLogger.error('Error cerrando stream del chat: $e', tag: 'ChatRetrieval');
    }
  }
}

/// Estadísticas de un chat
class ChatStats {
  final int totalMessages;
  final int unreadCount;
  final DateTime? lastMessageTime;

  ChatStats({
    required this.totalMessages,
    required this.unreadCount,
    this.lastMessageTime,
  });

  @override
  String toString() {
    return 'ChatStats(total: $totalMessages, unread: $unreadCount, lastMessage: $lastMessageTime)';
  }
}