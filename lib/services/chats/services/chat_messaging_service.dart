import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../models/chat_message.dart';
import '../repositories/message_repository.dart';
import '../managers/chat_cache_manager.dart';
import '../managers/message_upload_manager.dart';
import '../../../services/chat_block_service.dart';
import '../utils/chat_exceptions.dart';
import '../../../utils/release_logger.dart';
import 'rate_limiting_service.dart';

// Tipo temporal para compatibilidad hasta adaptar al modelo existente
enum MessageType { text, image, audio, video }

/// Servicio especializado para envío y gestión de mensajes
///
/// Responsabilidades:
/// - Lógica de negocio para envío de mensajes
/// - Upload optimista de media
/// - Gestión de mensajes temporales
/// - Estado de delivery/read receipts
class ChatMessagingService {
  final MessageRepository _messageRepository;
  final MessageUploadManager _uploadManager;
  final ChatCacheManager _cacheManager;
  final ChatBlockService _blockService;
  final RateLimitingService _rateLimitingService;

  ChatMessagingService({
    required MessageRepository messageRepository,
    required MessageUploadManager uploadManager,
    required ChatCacheManager cacheManager,
    ChatBlockService? blockService,
    RateLimitingService? rateLimitingService,
  }) : _messageRepository = messageRepository,
       _uploadManager = uploadManager,
       _cacheManager = cacheManager,
       _blockService = blockService ?? ChatBlockService(),
       _rateLimitingService = rateLimitingService ?? RateLimitingService();

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE SENDING - OPTIMISTIC UX
  // ═══════════════════════════════════════════════════════════════

  /// Write a text message to a chat
  Future<String?> writeMessage({
    required String chatId,
    required String content,
    String? replyToId,
    Map<String, dynamic>? metadata,
    bool isGroup = false,
  }) async {
    return await sendMessage(
      chatId: chatId,
      content: content,
      type: MessageType.text,
      replyToId: replyToId,
      metadata: metadata,
      isGroup: isGroup,
    );
  }

  /// Upload a media message (image, video, audio)
  Future<String?> uploadMessage({
    required String chatId,
    required String mediaPath,
    required String mediaType,
    String? caption,
    String? replyToId,
    bool isGroup = false,
    Function(String messageId, double progress)? onProgressUpdate,
  }) async {
    MessageType type;
    switch (mediaType.toLowerCase()) {
      case 'image':
        type = MessageType.image;
        break;
      case 'video':
        type = MessageType.video;
        break;
      case 'audio':
        type = MessageType.audio;
        break;
      default:
        throw Exception('Invalid media type: $mediaType');
    }

    return await sendMessage(
      chatId: chatId,
      content: caption ?? '',
      type: type,
      mediaPath: mediaPath,
      replyToId: replyToId,
      isGroup: isGroup,
      onProgressUpdate: onProgressUpdate,
    );
  }

  /// Enviar mensaje con UX optimista (internal method)
  Future<String?> sendMessage({
    required String chatId,
    required String content,
    MessageType type = MessageType.text,
    String? mediaPath,
    String? replyToId,
    Map<String, dynamic>? metadata,
    bool isGroup = false,
    Function(String messageId, double progress)? onProgressUpdate,
  }) async {
    final currentUserId = _messageRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 🔒 VALIDACIÓN DE SEGURIDAD P0: Verificar usuarios bloqueados
    await _validateBlockStatus(chatId, currentUserId);

    // 🚦 VALIDACIÓN DE RATE LIMITING P2: Verificar throttling y rate limits
    await _rateLimitingService.validateMessageSending(currentUserId);

    // 1. Generar ID temporal
    final tempMessageId = _generateTempMessageId();

    try {
      // 2. Crear mensaje optimista
      final optimisticMessage = await _createOptimisticMessage(
        messageId: tempMessageId,
        chatId: chatId,
        senderId: currentUserId,
        content: content,
        type: type,
        mediaPath: mediaPath,
        replyToId: replyToId,
        metadata: metadata,
      );

      // 3. Agregar a cache optimista (aparece inmediatamente en UI)
      _cacheManager.addOptimisticMessage(chatId, optimisticMessage);

      // 4. Proceso de envío síncronamente
      final realMessageId = await _processMessageSending(
        tempMessageId: tempMessageId,
        chatId: chatId,
        optimisticMessage: optimisticMessage,
        isGroup: isGroup,
        onProgressUpdate: onProgressUpdate,
      );

      return realMessageId;
    } catch (e) {
      // Si el proceso falló, limpiar mensaje optimista
      _cacheManager.removeOptimisticMessage(chatId, tempMessageId);

      // Re-lanzar el error para que el UI pueda manejarlo
      rethrow;
    }
  }

  /// Editar mensaje existente
  Future<void> editMessage({
    required String chatId,
    required String messageId,
    required String newContent,
    bool isGroup = false,
  }) async {
    final currentUserId = _messageRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 🚦 VALIDAR RATE LIMITING para edición
    await _rateLimitingService.validateMessageEditing(currentUserId);

    try {
      await _messageRepository.updateMessage(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
        updates: {
          'content': newContent,
          'editedAt': DateTime.now().toIso8601String(),
          'isEdited': true,
        },
      );

      // Actualizar cache
      _cacheManager.updateMessage(chatId, messageId, {
        'content': newContent,
        'editedAt': DateTime.now().toIso8601String(),
        'isEdited': true,
      });
    } catch (e) {
      throw Exception('Error editando mensaje: $e');
    }
  }

  /// Eliminar mensaje
  Future<void> deleteMessage({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    final currentUserId = _messageRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 🚦 VALIDAR RATE LIMITING para eliminación
    await _rateLimitingService.validateMessageDeletion(currentUserId);

    try {
      await _messageRepository.deleteMessage(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      // Remover del cache
      _cacheManager.removeMessage(chatId, messageId);
    } catch (e) {
      throw Exception('Error eliminando mensaje: $e');
    }
  }

  /// Reaccionar a mensaje
  Future<void> addReaction({
    required String chatId,
    required String messageId,
    required String reaction,
    bool isGroup = false,
  }) async {
    try {
      await _messageRepository.addReaction(
        chatId: chatId,
        messageId: messageId,
        reaction: reaction,
        isGroup: isGroup,
      );
    } catch (e) {
      throw Exception('Error añadiendo reacción: $e');
    }
  }

  /// Quitar reacción de mensaje
  Future<void> removeReaction({
    required String chatId,
    required String messageId,
    required String reaction,
    bool isGroup = false,
  }) async {
    try {
      await _messageRepository.removeReaction(
        chatId: chatId,
        messageId: messageId,
        reaction: reaction,
        isGroup: isGroup,
      );
    } catch (e) {
      throw Exception('Error quitando reacción: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // OPTIMISTIC MESSAGE CREATION
  // ═══════════════════════════════════════════════════════════════

  /// Crear mensaje optimista (temporal para UX inmediata)
  Future<ChatMessage> _createOptimisticMessage({
    required String messageId,
    required String chatId,
    required String senderId,
    required String content,
    required MessageType type,
    String? mediaPath,
    String? replyToId,
    Map<String, dynamic>? metadata,
  }) async {
    final now = DateTime.now();

    // Usar el constructor existente del modelo ChatMessage
    return ChatMessage(
      id: messageId,
      senderId: senderId,
      text: type == MessageType.text ? content : null,
      imageUrl: type == MessageType.image ? null : null, // Se establecerá después del upload
      videoUrl: type == MessageType.video ? null : null, // Se establecerá después del upload
      audioUrl: type == MessageType.audio ? null : null, // Se establecerá después del upload
      timestamp: Timestamp.fromDate(now),
      isRead: false,
      replyTo: replyToId != null ? {'messageId': replyToId} : null,
      reactions: {},
      type: type.name, // Convertir enum a string
      status: MessageStatus.sending,
      localTimestamp: now,
      localPath: mediaPath,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE SENDING PROCESS
  // ═══════════════════════════════════════════════════════════════

  /// Procesar envío de mensaje (síncronamente)
  Future<String> _processMessageSending({
    required String tempMessageId,
    required String chatId,
    required ChatMessage optimisticMessage,
    required bool isGroup,
    Function(String messageId, double progress)? onProgressUpdate,
  }) async {
    try {
      String? mediaUrl;

      // 1. Upload archivo si es necesario
      if (optimisticMessage.localPath != null) {
        mediaUrl = await _uploadManager.uploadWithRetry(
          filePath: optimisticMessage.localPath!,
          chatId: chatId,
          messageId: tempMessageId,
          onProgressUpdate: onProgressUpdate != null
              ? (progress) => onProgressUpdate(tempMessageId, progress)
              : null,
        );
      }

      // 2. Crear mensaje final en Firestore - usar constructor adaptor
      final finalMessage = ChatMessage(
        id: optimisticMessage.id,
        senderId: optimisticMessage.senderId,
        text: optimisticMessage.text,
        imageUrl: optimisticMessage.type == 'image' ? mediaUrl : optimisticMessage.imageUrl,
        videoUrl: optimisticMessage.type == 'video' ? mediaUrl : optimisticMessage.videoUrl,
        audioUrl: optimisticMessage.type == 'audio' ? mediaUrl : optimisticMessage.audioUrl,
        timestamp: optimisticMessage.timestamp,
        isRead: optimisticMessage.isRead,
        replyTo: optimisticMessage.replyTo,
        reactions: optimisticMessage.reactions,
        type: optimisticMessage.type,
        status: MessageStatus.sent,
        localTimestamp: optimisticMessage.localTimestamp,
        localPath: null, // Limpiar path local después del upload
      );

      final realMessageId = await _messageRepository.createOptimisticMessage(
        chatId: chatId,
        message: finalMessage,
        isGroup: isGroup,
      );

      // 3. Actualizar cache optimista con datos reales
      _cacheManager.updateOptimisticMessage(
        chatId,
        tempMessageId,
        finalMessage.copyWith(id: realMessageId),
      );

      return realMessageId;
    } catch (e) {
      // Log error y re-lanzar
      ReleaseLogger.error(
        'Error en proceso de envío de mensaje: $e',
        tag: 'ChatMessaging',
      );

      // Re-lanzar la excepción para que el usuario vea el error
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // READ/DELIVERY RECEIPTS
  // ═══════════════════════════════════════════════════════════════

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead({
    required String chatId,
    required List<String> messageIds,
    bool isGroup = false,
  }) async {
    try {
      await _messageRepository.markMessagesAsRead(
        chatId: chatId,
        messageIds: messageIds,
        isGroup: isGroup,
      );
    } catch (e) {
      ReleaseLogger.error('Error marcando mensajes como leídos: $e');
    }
  }

  /// Marcar mensajes como entregados
  Future<void> markMessagesAsDelivered({
    required String chatId,
    required List<String> messageIds,
    bool isGroup = false,
  }) async {
    try {
      await _messageRepository.markMessagesAsDelivered(
        chatId: chatId,
        messageIds: messageIds,
        isGroup: isGroup,
      );
    } catch (e) {
      ReleaseLogger.error('Error marcando mensajes como entregados: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SECURITY VALIDATION METHODS (P0)
  // ═══════════════════════════════════════════════════════════════

  /// 🔒 P0 CRÍTICO: Validar que el usuario no esté bloqueado antes de envío
  Future<void> _validateBlockStatus(String chatId, String currentUserId) async {
    try {
      // Extraer IDs de usuarios del chatId
      final userIds = _extractUserIdsFromChatId(chatId);
      final otherUserId = userIds.firstWhere((id) => id != currentUserId, orElse: () => '');

      if (otherUserId.isEmpty) {
        // Es un grupo - validación más compleja requerida
        ReleaseLogger.warning('Validación de grupo pendiente de implementar', tag: 'ChatSecurity');
        return;
      }

      // Verificar si current user está bloqueado por el otro usuario
      final blockStatus = await _blockService.getChatBlockStatus(
        childId: currentUserId,
        contactId: otherUserId,
      );

      if (blockStatus.isBlocked) {
        throw UserBlockedException(
          'No puedes enviar mensajes a este usuario. ${blockStatus.reason ?? "Usuario bloqueado"}'
        );
      }

      // Verificar si el otro usuario está bloqueado por current user
      final reverseBlockStatus = await _blockService.getChatBlockStatus(
        childId: otherUserId,
        contactId: currentUserId,
      );

      if (reverseBlockStatus.isBlocked) {
        throw UserBlockedException(
          'Has bloqueado a este usuario. No puedes enviar mensajes.'
        );
      }

      ReleaseLogger.info('✅ Validación de bloqueo pasada para chat $chatId', tag: 'ChatSecurity');

    } catch (e) {
      if (e is UserBlockedException) {
        rethrow;
      }
      ReleaseLogger.error('Error en validación de bloqueo: $e', tag: 'ChatSecurity');
      // En caso de error, permitir envío - el backend lo validará
    }
  }

  /// Extraer user IDs del chatId (formato: user1_user2)
  List<String> _extractUserIdsFromChatId(String chatId) {
    // Formato típico: "user1_user2" o "group_groupId"
    if (chatId.startsWith('group_')) {
      return []; // Es un grupo
    }

    final parts = chatId.split('_');
    if (parts.length >= 2) {
      return [parts[0], parts[1]];
    }

    return []; // Formato no reconocido
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Generar ID temporal único
  String _generateTempMessageId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return 'temp_message_${timestamp}_$random';
  }
}