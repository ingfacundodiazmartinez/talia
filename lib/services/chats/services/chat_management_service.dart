import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/chat_message.dart';
import '../repositories/chat_repository.dart';
import '../repositories/message_repository.dart';
import '../managers/chat_cache_manager.dart';
import '../utils/chat_exceptions.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado para gestión y administración de chats
///
/// Responsabilidades:
/// - Operaciones de gestión de mensajes (editar, eliminar, forward)
/// - Validaciones de ownership y límites de tiempo
/// - Gestión de read receipts y estado de chats
/// - Operaciones administrativas de chats
class ChatManagementService {
  final ChatRepository _chatRepository;
  final MessageRepository _messageRepository;
  final ChatCacheManager _cacheManager;
  final FirebaseAuth _auth;

  // Configuración de límites de tiempo
  static const Duration _deleteTimeLimit = Duration(minutes: 5);
  static const Duration _editTimeLimit = Duration(minutes: 5);

  ChatManagementService({
    required ChatRepository chatRepository,
    required MessageRepository messageRepository,
    required ChatCacheManager cacheManager,
    FirebaseAuth? auth,
  }) : _chatRepository = chatRepository,
       _messageRepository = messageRepository,
       _cacheManager = cacheManager,
       _auth = auth ?? FirebaseAuth.instance;

  // ═══════════════════════════════════════════════════════════════
  // CHAT READ STATUS MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Marcar chat como leído
  Future<void> markChatAsRead(String chatId) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        throw Exception('Usuario no autenticado');
      }

      // Determinar si es grupo
      final isGroup = chatId.startsWith('group_') || await _isGroupChat(chatId);

      await _chatRepository.markAsRead(chatId, isGroup: isGroup);

      // Actualizar cache local
      _cacheManager.invalidateChatCache(chatId);

      ReleaseLogger.info('✅ Chat $chatId marcado como leído');

    } catch (e) {
      ReleaseLogger.error('Error marcando chat como leído: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE EDITING WITH VALIDATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Editar mensaje con validaciones de ownership y límite de tiempo
  Future<void> editMessage(
    String chatId,
    String messageId,
    String newContent,
  ) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    try {
      // 1. Obtener mensaje actual
      final message = await _getMessageForValidation(chatId, messageId);

      // 2. Validar ownership
      await _validateMessageOwnership(message, currentUserId);

      // 3. Validar límite de tiempo para edición
      await _validateEditTimeLimit(message);

      // 4. Validar que no esté moderado
      await _validateMessageNotModerated(message);

      // 5. Validar contenido (si está disponible moderación)
      // await _validateContentModeration(newContent);

      // 6. Determinar si es grupo
      final isGroup = await _isGroupChat(chatId);

      // 7. Actualizar mensaje
      await _messageRepository.updateMessage(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
        updates: {
          'content': newContent,
          'text': newContent, // Para compatibilidad con modelo actual
          'editedAt': DateTime.now().toIso8601String(),
          'isEdited': true,
        },
      );

      // 8. Actualizar cache
      _cacheManager.updateMessage(chatId, messageId, {
        'content': newContent,
        'text': newContent,
        'editedAt': DateTime.now().toIso8601String(),
        'isEdited': true,
      });

      ReleaseLogger.info('✅ Mensaje $messageId editado exitosamente en chat $chatId');

    } catch (e) {
      ReleaseLogger.error('Error editando mensaje $messageId: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE DELETION WITH VALIDATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Eliminar mensaje con validaciones de ownership y límite de tiempo
  Future<void> deleteMessage(String chatId, String messageId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    try {
      // 1. Obtener mensaje actual
      final message = await _getMessageForValidation(chatId, messageId);

      // 2. Validar ownership
      await _validateMessageOwnership(message, currentUserId);

      // 3. Validar límite de tiempo para eliminación
      await _validateDeleteTimeLimit(message);

      // 4. Determinar si es grupo
      final isGroup = await _isGroupChat(chatId);

      // 5. Eliminar mensaje
      await _messageRepository.deleteMessage(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      // 6. Actualizar cache
      _cacheManager.removeMessage(chatId, messageId);

      ReleaseLogger.info('✅ Mensaje $messageId eliminado exitosamente de chat $chatId');

    } catch (e) {
      ReleaseLogger.error('Error eliminando mensaje $messageId: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE FORWARDING
  // ═══════════════════════════════════════════════════════════════

  /// Forward mensaje a otros chats
  Future<void> forwardMessage({
    required ChatMessage message,
    required List<String> targetChatIds,
    required List<String> targetGroupIds,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    try {
      final allTargets = [...targetChatIds, ...targetGroupIds];
      if (allTargets.isEmpty) {
        throw Exception('Debe especificar al menos un destino');
      }

      // Validar límite de destinos
      if (allTargets.length > 10) {
        throw Exception('Máximo 10 destinos permitidos');
      }

      final results = <String, bool>{};

      // Procesar chats individuales
      for (final chatId in targetChatIds) {
        try {
          await _forwardToIndividualChat(message, chatId, currentUserId);
          results[chatId] = true;
        } catch (e) {
          ReleaseLogger.warning('Error forwarding a chat $chatId: $e');
          results[chatId] = false;
        }
      }

      // Procesar grupos
      for (final groupId in targetGroupIds) {
        try {
          await _forwardToGroup(message, groupId, currentUserId);
          results[groupId] = true;
        } catch (e) {
          ReleaseLogger.warning('Error forwarding a grupo $groupId: $e');
          results[groupId] = false;
        }
      }

      final successCount = results.values.where((success) => success).length;
      ReleaseLogger.info('✅ Mensaje forwarded a $successCount/${allTargets.length} destinos');

    } catch (e) {
      ReleaseLogger.error('Error en forward de mensaje: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PRIVATE VALIDATION METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener mensaje para validaciones
  Future<ChatMessage> _getMessageForValidation(String chatId, String messageId) async {
    // Primero intentar obtener del cache
    final cachedMessages = _cacheManager.getCachedMessages(chatId);
    for (final message in cachedMessages) {
      if (message.id == messageId) {
        return message;
      }
    }

    // Si no está en cache, obtener de Firestore
    final isGroup = await _isGroupChat(chatId);

    try {
      final doc = await _messageRepository.getMessageById(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      if (doc == null || !doc.exists) {
        throw Exception('Mensaje $messageId no encontrado en chat $chatId');
      }

      // Crear ChatMessage desde DocumentSnapshot
      final message = ChatMessage.fromFirestore(doc, currentUserId: _auth.currentUser?.uid);
      return message;
    } catch (e) {
      throw Exception('Error obteniendo mensaje $messageId: $e');
    }
  }

  /// Validar ownership del mensaje
  Future<void> _validateMessageOwnership(ChatMessage message, String currentUserId) async {
    if (message.senderId != currentUserId) {
      throw UnauthorizedEditException(
        'No tienes permisos para modificar este mensaje',
        messageId: message.id,
        attemptedBy: currentUserId,
      );
    }
  }

  /// Validar límite de tiempo para edición (5 minutos)
  Future<void> _validateEditTimeLimit(ChatMessage message) async {
    final messageTime = message.localTimestamp ?? message.timestamp?.toDate();
    if (messageTime == null) {
      throw Exception('No se pudo determinar la fecha del mensaje');
    }

    final age = DateTime.now().difference(messageTime);
    if (age > _editTimeLimit) {
      throw MessageTooOldException(
        'Solo puedes editar mensajes enviados hace menos de ${_editTimeLimit.inMinutes} minutos',
        messageId: message.id,
        age: age,
        maxAge: _editTimeLimit,
      );
    }
  }

  /// Validar límite de tiempo para eliminación (5 minutos)
  Future<void> _validateDeleteTimeLimit(ChatMessage message) async {
    final messageTime = message.localTimestamp ?? message.timestamp?.toDate();
    if (messageTime == null) {
      throw Exception('No se pudo determinar la fecha del mensaje');
    }

    final age = DateTime.now().difference(messageTime);
    if (age > _deleteTimeLimit) {
      throw MessageTooOldException(
        'Solo puedes eliminar mensajes enviados hace menos de ${_deleteTimeLimit.inMinutes} minutos',
        messageId: message.id,
        age: age,
        maxAge: _deleteTimeLimit,
      );
    }
  }

  /// Validar que mensaje no esté moderado
  Future<void> _validateMessageNotModerated(ChatMessage message) async {
    // TODO: Implementar cuando tengamos sistema de moderación
    // if (message.isModerated) {
    //   throw MessageModerationException(
    //     'No puedes editar un mensaje moderado',
    //     messageId: message.id,
    //     moderationReason: message.moderationReason,
    //   );
    // }
  }

  /// Verificar si es chat de grupo
  Future<bool> _isGroupChat(String chatId) async {
    if (chatId.startsWith('group_')) return true;

    try {
      final groupDoc = await _chatRepository.getGroupById(chatId);
      return groupDoc != null;
    } catch (e) {
      return false;
    }
  }

  /// Forward a chat individual
  Future<void> _forwardToIndividualChat(
    ChatMessage originalMessage,
    String targetChatId,
    String currentUserId,
  ) async {
    // Crear mensaje forward
    final forwardedMessage = ChatMessage(
      id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
      senderId: currentUserId,
      text: originalMessage.text,
      imageUrl: originalMessage.imageUrl,
      videoUrl: originalMessage.videoUrl,
      audioUrl: originalMessage.audioUrl,
      timestamp: null, // Se establecerá en el servidor
      isRead: false,
      replyTo: null,
      reactions: {},
      type: originalMessage.type ?? 'text',
      status: MessageStatus.sending,
      localTimestamp: DateTime.now(),
    );

    await _messageRepository.createOptimisticMessage(
      chatId: targetChatId,
      message: forwardedMessage,
      isGroup: false,
    );
  }

  /// Forward a grupo
  Future<void> _forwardToGroup(
    ChatMessage originalMessage,
    String targetGroupId,
    String currentUserId,
  ) async {
    // TODO: Validar que usuario puede enviar al grupo
    // final canSend = await _groupService.canSendToGroup(currentUserId, targetGroupId);
    // if (!canSend) throw Exception('No tienes permisos para enviar a este grupo');

    final forwardedMessage = ChatMessage(
      id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
      senderId: currentUserId,
      text: originalMessage.text,
      imageUrl: originalMessage.imageUrl,
      videoUrl: originalMessage.videoUrl,
      audioUrl: originalMessage.audioUrl,
      timestamp: null,
      isRead: false,
      replyTo: null,
      reactions: {},
      type: originalMessage.type ?? 'text',
      status: MessageStatus.sending,
      localTimestamp: DateTime.now(),
    );

    await _messageRepository.createOptimisticMessage(
      chatId: targetGroupId,
      message: forwardedMessage,
      isGroup: true,
    );
  }
}