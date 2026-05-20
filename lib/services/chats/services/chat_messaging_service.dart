import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../models/chat_message.dart';
import '../../video_frame_extractor.dart';
import '../repositories/message_repository.dart';
import '../managers/chat_cache_manager.dart';
import '../managers/message_upload_manager.dart';
import '../../../services/chat_block_service.dart';
import '../utils/chat_exceptions.dart';
import '../../../utils/release_logger.dart';
import 'rate_limiting_service.dart';

/// Excepción específica para bloqueos de moderación
class ModerationBlockedException implements Exception {
  final String reason;
  ModerationBlockedException(this.reason);

  @override
  String toString() => reason;
}

/// Contexto resuelto para enviar un mensaje, computado en una sola pasada
/// a partir del estado del chat doc.
class _SendContext {
  /// Lista de UIDs que pueden ver el mensaje (campo `visibleTo` del doc).
  final List<String> visibleTo;

  /// Estado de moderación inicial del mensaje.
  /// - pending: chat con moderación, CF lo resolverá y expandirá visibleTo.
  /// - approved: chat normal, mensaje visible inmediato.
  final ModerationStatus moderationStatus;

  /// true cuando el chat tiene moderación activa. Se usa para decidir si pasar
  /// videoFrames extraídos y otros datos auxiliares a la CF de moderación.
  final bool hasModeration;

  const _SendContext({
    required this.visibleTo,
    required this.moderationStatus,
    required this.hasModeration,
  });
}

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
  final RateLimitingService _rateLimitingService;

  ChatMessagingService({
    required MessageRepository messageRepository,
    required MessageUploadManager uploadManager,
    required ChatCacheManager cacheManager,
    // [blockService] se acepta por compatibilidad con callers existentes pero ya
    // no se usa: la validación de bloqueo se hace en `_resolveSendContext`
    // leyendo `chat.isBlocked`/`blockedBy` directamente.
    @Deprecated('No longer used — _resolveSendContext handles block state')
        ChatBlockService? blockService,
    RateLimitingService? rateLimitingService,
  }) : _messageRepository = messageRepository,
       _uploadManager = uploadManager,
       _cacheManager = cacheManager,
       _rateLimitingService = rateLimitingService ?? RateLimitingService();

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE SENDING - OPTIMISTIC UX
  // ═══════════════════════════════════════════════════════════════

  /// Write a text message to a chat
  Future<String?> writeMessage({
    required String chatId,
    required String content,
    Map<String, dynamic>? replyTo,  // ✅ FIX: Cambiar de replyToId a replyTo
    Map<String, dynamic>? metadata,
    bool isGroup = false,
  }) async {
    return await sendMessage(
      chatId: chatId,
      content: content,
      type: MessageType.text,
      replyTo: replyTo,
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
    Map<String, dynamic>? replyTo,  // ✅ FIX: Cambiar de replyToId a replyTo
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
      replyTo: replyTo,
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
    Map<String, dynamic>? replyTo,  // ✅ FIX: Cambiar de replyToId a replyTo completo
    Map<String, dynamic>? metadata,
    bool isGroup = false,
    Function(String messageId, double progress)? onProgressUpdate,
  }) async {
    final currentUserId = _messageRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 🔒 Resolver contexto de envío (bloqueo + moderación) en una sola lectura.
    // Esto reemplaza al validador antiguo y al check de moderación: ambos quedaban
    // duplicados. Si yo soy el bloqueador, esto lanza UserBlockedException. Si soy
    // el bloqueado, el envío continúa con visibleTo restringido (el otro no lo verá).
    final isOneOnOne = !chatId.startsWith('group_') && !isGroup;
    _SendContext? sendContext;
    if (isOneOnOne) {
      sendContext = await _resolveSendContext(
        chatId: chatId,
        currentUserId: currentUserId,
      );
    }

    // 🚦 VALIDACIÓN DE RATE LIMITING P2: Verificar throttling y rate limits
    await _rateLimitingService.validateMessageSending(currentUserId);

    // 1. Usar localId del metadata si está disponible, sino generar ID temporal
    final providedLocalId = metadata?['localId'] as String?;
    final tempMessageId = providedLocalId ?? _generateTempMessageId();

    if (providedLocalId != null) {
      ReleaseLogger.log('✅ [ChatMessagingService] Usando localId del controller: ${providedLocalId.substring(0, 8)}...');
    } else {
      ReleaseLogger.log('⚠️ [ChatMessagingService] No se recibió localId, generando nuevo: ${tempMessageId.substring(0, 8)}...');
    }

    try {
      // 2. Crear mensaje optimista
      final optimisticMessage = await _createOptimisticMessage(
        messageId: tempMessageId,
        chatId: chatId,
        senderId: currentUserId,
        content: content,
        type: type,
        mediaPath: mediaPath,
        replyTo: replyTo,  // ✅ FIX: Pasar replyTo completo
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
        metadata: metadata,
        onProgressUpdate: onProgressUpdate,
        sendContext: sendContext,
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
    Map<String, dynamic>? replyTo,  // ✅ FIX: Cambiar de replyToId a replyTo completo
    Map<String, dynamic>? metadata,
  }) async {
    final now = DateTime.now();

    // ✅ FIX: Construir replyTo completo con messageId para compatibilidad
    Map<String, dynamic>? finalReplyTo;
    if (replyTo != null) {
      finalReplyTo = {
        'messageId': replyTo['id'],           // ID del mensaje original
        'text': replyTo['text'],              // Texto del mensaje original
        'senderId': replyTo['senderId'],      // Quien envió el mensaje original
        'senderName': replyTo['senderName'],  // Nombre del remitente
        if (replyTo['contentType'] != null) 'contentType': replyTo['contentType'],
        if (replyTo['imageUrl'] != null) 'imageUrl': replyTo['imageUrl'],
        if (replyTo['videoUrl'] != null) 'videoUrl': replyTo['videoUrl'],
        if (replyTo['audioUrl'] != null) 'audioUrl': replyTo['audioUrl'],
      };
    }

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
      replyTo: finalReplyTo,  // ✅ FIX: Usar replyTo completo
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

  /// Procesar envío de mensaje (síncronamente).
  ///
  /// Flujo nuevo (siempre client-side):
  /// 1. Optimistic update del chat doc.
  /// 2. Upload de media (si aplica).
  /// 3. Construir mensaje final con `visibleTo` y `moderationStatus` del contexto.
  /// 4. Write directo a Firestore.
  /// 5. La CF trigger `moderateMessage` se encarga de expandir `visibleTo` para
  ///    moderación. Bloqueos no requieren CF (el cliente ya seteó `visibleTo`
  ///    apropiadamente). Push notifications respetan `visibleTo`.
  Future<String> _processMessageSending({
    required String tempMessageId,
    required String chatId,
    required ChatMessage optimisticMessage,
    required bool isGroup,
    Map<String, dynamic>? metadata,
    Function(String messageId, double progress)? onProgressUpdate,
    _SendContext? sendContext,
  }) async {
    try {
      String? mediaUrl;

      // ✅ FIX: Actualizar chat doc INMEDIATAMENTE (optimistic) para que la lista de chats
      // muestre el mensaje antes de que termine el upload
      if (optimisticMessage.localPath != null) {
        await _updateChatDocOptimistic(
          chatId: chatId,
          messageType: optimisticMessage.type ?? 'text',
          text: optimisticMessage.text,
          isGroup: isGroup,
        );
      }

      // 1. Upload archivo si es necesario
      // 🎬 Para videos: extraer frames ANTES del upload (para moderación)
      List<String>? videoFrames;
      if (optimisticMessage.localPath != null && optimisticMessage.type == 'video') {
        try {
          videoFrames = await VideoFrameExtractor().extractFrames(
            optimisticMessage.localPath!,
            frameCount: 4,
          );
          ReleaseLogger.log(
            '🎬 Extraídos ${videoFrames.length} frames del video para moderación',
            tag: 'ChatMessaging',
          );
        } catch (e) {
          ReleaseLogger.error('Error extrayendo frames de video: $e', tag: 'ChatMessaging');
          // Continuar sin frames - la moderación será más limitada
        }
      }

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

      // 🧮 Resolver visibleTo + moderationStatus. Si no hay contexto (caso edge
      // de grupos o chat con formato no estándar), usar defaults seguros.
      final List<String>? visibleTo = sendContext?.visibleTo;
      final ModerationStatus moderationStatus =
          sendContext?.moderationStatus ?? ModerationStatus.approved;
      final bool hasModeration = sendContext?.hasModeration ?? false;

      // ✅ Extraer transcripción y frames del metadata para el trigger de moderación.
      // Se incluyen en el doc del mensaje para que la CF los pueda leer en lugar
      // de tener que pasarlos por el call.
      final transcription = metadata?['transcription'] as String?;

      // Construir mensaje final
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
        localPath: null,
        localId: tempMessageId,
        moderationStatus: moderationStatus,
        transcription: transcription,
        visibleTo: visibleTo,
      );

      // ✅ Write directo a Firestore (siempre, sin Cloud Function intermedia).
      // - Con moderación: el trigger moderateMessage analizará y expandirá visibleTo.
      // - Bloqueo unidireccional: visibleTo ya restringe al sender, sin más trabajo.
      // - hasModeration se loggea para auditoría pero ya no determina el path.
      if (hasModeration) {
        ReleaseLogger.log(
          '🔒 Mensaje con moderación pendiente — trigger moderateMessage resolverá',
          tag: 'ChatMessaging',
        );
      }

      // Para mensajes con multimedia + moderación, también se incluyen frames como
      // campo del doc para el trigger. Si videoFrames está vacío no se escribe nada.
      final extraFields = <String, dynamic>{};
      if (hasModeration && videoFrames != null && videoFrames.isNotEmpty) {
        extraFields['videoFrames'] = videoFrames;
      }

      final realMessageId = await _messageRepository.createOptimisticMessage(
        chatId: chatId,
        message: finalMessage,
        isGroup: isGroup,
        extraFields: extraFields.isEmpty ? null : extraFields,
      );

      // 4. Actualizar mensaje optimista con ID real (sin eliminarlo para evitar flash en UI)
      // ✅ FIX: UPDATE en vez de REMOVE para UX suave
      // La deduplicación por localId evitará duplicados cuando llegue del stream
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

  /// Resuelve `visibleTo` + `moderationStatus` para un mensaje saliente en una
  /// sola lectura del chat doc. Además rechaza el envío si el usuario actual
  /// es el bloqueador (única dirección que aborta).
  ///
  /// Reglas:
  /// - Si yo soy `blockedBy` del chat → throw [UserBlockedException].
  /// - Si el chat tiene `isBlocked == true` y NO soy el bloqueador
  ///   → `visibleTo = [me]`. El destinatario nunca lo verá; queda en 1 tilde.
  /// - Si el chat tiene moderación activa → `visibleTo = [me]`. La CF de
  ///   moderación expandirá la lista cuando apruebe el mensaje.
  /// - Caso normal → `visibleTo = [me, other]`. Mensaje visible para ambos.
  Future<_SendContext> _resolveSendContext({
    required String chatId,
    required String currentUserId,
  }) async {
    final userIds = _extractUserIdsFromChatId(chatId);
    final otherUserId =
        userIds.firstWhere((id) => id != currentUserId, orElse: () => '');

    if (otherUserId.isEmpty) {
      // Defensa: chatId no tiene formato 1-1. Esta función es solo para 1-1.
      // Los grupos usan otro flujo (group_repository.sendMessage).
      throw UserBlockedException('chatId inválido para chat 1-1: $chatId');
    }

    bool isBlocked = false;
    String? blockedBy;
    String? blockedReason;
    bool moderationEnabled = false;

    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .get();

      if (chatDoc.exists) {
        final data = chatDoc.data() ?? const <String, dynamic>{};
        isBlocked = data['isBlocked'] == true;
        blockedBy = data['blockedBy'] as String?;
        blockedReason = data['blockedReason'] as String?;
        moderationEnabled = data['moderationEnabled'] == true;
      }
    } catch (e) {
      ReleaseLogger.error('Error leyendo chat doc para resolver contexto: $e',
          tag: 'ChatSecurity');
      // Si falla, asumimos contexto normal — backend validará con reglas.
    }

    // Si soy el bloqueador, NO puedo mandar mensajes.
    if (isBlocked && blockedBy == currentUserId) {
      throw UserBlockedException(
          'Has bloqueado a este usuario. No puedes enviar mensajes.');
    }

    // Si fue bloqueado por moderación parental (parent_revoked), ambos quedan
    // sin poder mandar.
    if (isBlocked && blockedReason == 'parent_revoked') {
      throw UserBlockedException(
          'Este contacto fue bloqueado por tu padre/madre.');
    }

    // Caso "otro me bloqueó": el envío SÍ avanza (1 tilde), pero `visibleTo`
    // se restringe al sender — el destinatario nunca lo recibe.
    final blockedByOther =
        isBlocked && blockedBy != null && blockedBy != currentUserId;

    List<String> visibleTo;
    ModerationStatus moderationStatus;

    if (blockedByOther) {
      visibleTo = [currentUserId];
      moderationStatus = ModerationStatus.approved;
    } else if (moderationEnabled) {
      visibleTo = [currentUserId];
      moderationStatus = ModerationStatus.pending;
    } else {
      visibleTo = [currentUserId, otherUserId];
      moderationStatus = ModerationStatus.approved;
    }

    return _SendContext(
      visibleTo: visibleTo,
      moderationStatus: moderationStatus,
      hasModeration: moderationEnabled,
    );
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

  /// ✅ Actualizar chat doc optimisticamente ANTES del upload
  /// Esto permite que la lista de chats muestre el mensaje inmediatamente
  Future<void> _updateChatDocOptimistic({
    required String chatId,
    required String messageType,
    String? text,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _messageRepository.currentUserId;
      if (currentUserId == null) return;

      final collection = isGroup ? 'groups_v2' : 'chats';
      final chatRef = FirebaseFirestore.instance.collection(collection).doc(chatId);

      // Verificar que el chat existe
      final chatDoc = await chatRef.get();
      if (!chatDoc.exists) return;

      // Generar preview del mensaje
      String messagePreview = text ?? '';
      if (messagePreview.isEmpty) {
        switch (messageType) {
          case 'image':
            messagePreview = '📷 Imagen';
            break;
          case 'video':
            messagePreview = '🎥 Video';
            break;
          case 'audio':
            messagePreview = '🎤 Audio';
            break;
        }
      }

      // Actualizar chat doc inmediatamente
      await chatRef.update({
        'lastMessage': messagePreview,
        'lastMessageType': messageType,
        'lastMessageSender': currentUserId,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageTime': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        '⚡ [ChatMessaging] Chat doc actualizado optimisticamente: $messagePreview',
        tag: 'ChatMessaging',
      );
    } catch (e) {
      // No fallar si no podemos actualizar optimisticamente
      ReleaseLogger.log(
        '⚠️ [ChatMessaging] Error en update optimista: $e',
        tag: 'ChatMessaging',
      );
    }
  }

  /// Verificar moderación de contenido sin crear mensaje en Firestore
  ///
  /// Usado para edición de mensajes bloqueados.
  /// Lanza ModerationBlockedException si el contenido es bloqueado.
  Future<void> checkModerationOnly({
    required String chatId,
    required String content,
  }) async {
    try {
      // ✅ FIX: Llamar a Cloud Function con checkOnly=true para verificar moderación real
      // sin crear/actualizar mensajes en Firestore
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final result = await functions.httpsCallable('checkMessageBeforeSending').call({
        'chatId': chatId,
        'text': content,
        'type': 'text',
        'checkOnly': true, // ✅ Solo verificar, no escribir en Firestore
      }).timeout(const Duration(seconds: 20));

      final approved = result.data['approved'] as bool;

      if (!approved) {
        final reason = result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
        ReleaseLogger.log('Moderation check blocked: $reason', tag: 'Moderation');
        throw ModerationBlockedException(reason);
      }

      ReleaseLogger.log('Moderation check passed for content', tag: 'Moderation');
    } on ModerationBlockedException {
      // Re-lanzar para que el llamador maneje el bloqueo
      rethrow;
    } catch (e) {
      // Errores técnicos - loguear pero no bloquear
      ReleaseLogger.error('Moderation check failed (network/technical): $e', tag: 'Moderation');
      // No rethrow - permitir mensaje en caso de error técnico
    }
  }

  /// Crear mensaje aprobado en Firestore después de pasar moderación
  ///
  /// Usado cuando un mensaje bloqueado es editado y aprobado.
  /// IMPORTANTE: Solo llamar después de verificar moderación con checkModerationOnly().
  ///
  /// Utiliza una Cloud Function para evitar problemas de permisos de Firestore
  Future<void> createApprovedMessage({
    required String chatId,
    required String messageId,
    required String senderId,
    required String text,
    String? localId, // ✅ FIX: Agregar localId para deduplicación
  }) async {
    try {
      // Llamar a la Cloud Function que crea el mensaje y actualiza el chat
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('createApprovedMessage');

      final result = await callable.call<Map<String, dynamic>>({
        'chatId': chatId,
        'messageId': messageId,
        'senderId': senderId,
        'text': text,
        'localId': localId, // ✅ FIX: Pasar localId a Cloud Function
      });

      ReleaseLogger.log('Approved message created via Cloud Function: ${result.data['messageId']}', tag: 'Moderation');
    } catch (e) {
      ReleaseLogger.error('Failed to create approved message: $e', tag: 'Moderation');
      rethrow;
    }
  }
}