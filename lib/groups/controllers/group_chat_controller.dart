import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../services/group_message_cache_service.dart';
import '../../utils/release_logger.dart';

/// Controller for group chat
///
/// Manages messages, reactions, and real-time updates for a group chat.
/// Uses cache-first pattern:
/// 1. Load ALL messages from local cache (Hive)
/// 2. Subscribe to Firestore stream (last 50) to sync updates
/// 3. Save new messages to cache
class GroupChatController {
  final String groupId;
  final GroupService _groupService;
  final GroupMessageCacheService _cacheService;

  // State
  Group? _group;
  List<GroupMessage> _messages = [];
  final List<GroupMessage> _optimisticMessages = []; // Mensajes locales enviándose
  bool _isLoading = false;
  bool _isSending = false;
  GroupMessage? _replyingTo;
  String? _error;

  // Subscriptions
  StreamSubscription? _groupSubscription;
  StreamSubscription? _messagesSubscription;

  // Callbacks
  Function(Group?)? onGroupChanged;
  Function(List<GroupMessage>)? onMessagesChanged;
  Function(bool)? onLoadingChanged;
  Function(bool)? onSendingChanged;
  Function(GroupMessage?)? onReplyingToChanged;
  Function(String)? onError;

  GroupChatController({
    required this.groupId,
    GroupService? groupService,
    GroupMessageCacheService? cacheService,
  }) : _groupService = groupService ?? GroupService(),
       _cacheService = cacheService ?? GroupMessageCacheService();

  // Getters
  Group? get group => _group;
  /// Combined list of optimistic + real messages, sorted by timestamp
  List<GroupMessage> get messages {
    final combined = [..._optimisticMessages, ..._messages];
    // Remove duplicates (optimistic messages replaced by real ones)
    final seen = <String>{};
    final unique = combined.where((m) {
      if (seen.contains(m.id)) return false;
      seen.add(m.id);
      return true;
    }).toList();
    // Sort by timestamp descending (newest first for reverse ListView)
    unique.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return unique;
  }
  List<GroupMessage> get optimisticMessages => _optimisticMessages;
  bool get isLoading => _isLoading;
  bool get isSending => _isSending;
  GroupMessage? get replyingTo => _replyingTo;
  String? get error => _error;

  /// Get group name safely
  String get groupName => _group?.name ?? 'Grupo';

  /// Get member count
  int get memberCount => _group?.memberCount ?? 0;

  /// Check if current user is admin
  bool isAdmin(String userId) => _group?.isAdmin(userId) ?? false;

  /// Get member by ID
  GroupMember? getMember(String userId) => _group?.getMember(userId);

  /// Initialize controller with cache-first pattern
  Future<void> initialize() async {
    _setLoading(true);

    try {
      // 1. PRIMERO: Cargar TODOS los mensajes del cache local (inmediato)
      final cachedMessages = await _cacheService.getMessages(groupId);
      if (cachedMessages.isNotEmpty) {
        _messages = cachedMessages;
        onMessagesChanged?.call(messages);
        ReleaseLogger.log(
          'Loaded ${cachedMessages.length} messages from cache for group $groupId',
          tag: 'GroupChatController',
        );
      }

      // 2. Cargar datos del grupo
      _group = await _groupService.getGroup(groupId);
      onGroupChanged?.call(_group);

      // 3. DESPUÉS: Suscribirse al stream de Firestore (últimos 50) para sincronizar
      _groupSubscription = _groupService.watchGroup(groupId).listen(
        (group) {
          _group = group;
          onGroupChanged?.call(_group);
        },
        onError: (e) {
          _setError('Error en grupo: $e');
        },
      );

      _messagesSubscription = _groupService.watchMessages(groupId).listen(
        (firestoreMessages) {
          // Merge: actualizar cache con mensajes de Firestore
          _mergeAndCacheMessages(firestoreMessages);
        },
        onError: (e) {
          _setError('Error en mensajes: $e');
        },
      );
    } catch (e) {
      _setError('Error inicializando chat: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Merge Firestore messages with cached messages
  void _mergeAndCacheMessages(List<GroupMessage> firestoreMessages) {
    // Guardar mensajes nuevos en cache
    _cacheService.saveMessages(groupId, firestoreMessages);

    // Crear mapa de mensajes existentes por ID
    final existingById = {for (final m in _messages) m.id: m};

    // Actualizar con mensajes de Firestore (más recientes tienen prioridad)
    for (final msg in firestoreMessages) {
      existingById[msg.id] = msg;
    }

    // Convertir a lista y ordenar
    _messages = existingById.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    onMessagesChanged?.call(messages);

    // Auto-mark new messages as read
    _autoMarkMessagesAsRead(firestoreMessages);

    ReleaseLogger.log(
      'Merged messages: ${firestoreMessages.length} from Firestore, total: ${_messages.length}',
      tag: 'GroupChatController',
    );
  }

  /// Automatically mark unread messages as read
  Future<void> _autoMarkMessagesAsRead(List<GroupMessage> newMessages) async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    // Find messages not sent by current user and not yet read by them
    final unreadMessageIds = newMessages
        .where((m) => m.senderId != currentUserId && !m.readBy.contains(currentUserId))
        .map((m) => m.id)
        .toList();

    if (unreadMessageIds.isNotEmpty) {
      try {
        await _groupService.markMessagesAsRead(
          groupId: groupId,
          messageIds: unreadMessageIds,
        );
        ReleaseLogger.log(
          'Auto-marked ${unreadMessageIds.length} messages as read',
          tag: 'GroupChatController',
        );
      } catch (e) {
        ReleaseLogger.error(
          'Error auto-marking messages as read: $e',
          tag: 'GroupChatController',
        );
      }
    }
  }

  /// Send a text message
  Future<bool> sendTextMessage(String text, {
    String? senderName,
    String? senderPhotoURL,
  }) async {
    if (text.trim().isEmpty) return false;

    _setSending(true);

    try {
      final messageId = await _groupService.sendTextMessage(
        groupId: groupId,
        text: text.trim(),
        senderName: senderName,
        senderPhotoURL: senderPhotoURL,
        replyTo: _replyingTo,
      );

      if (messageId != null) {
        clearReply();
        return true;
      } else {
        _setError('Error enviando mensaje');
        return false;
      }
    } catch (e) {
      _setError('Error enviando mensaje: $e');
      return false;
    } finally {
      _setSending(false);
    }
  }

  /// Send a media message
  Future<bool> sendMediaMessage({
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? audioUrl,
    String? thumbnailUrl,
    String? senderName,
    String? senderPhotoURL,
  }) async {
    _setSending(true);

    try {
      final messageId = await _groupService.sendMediaMessage(
        groupId: groupId,
        text: text,
        imageUrl: imageUrl,
        videoUrl: videoUrl,
        audioUrl: audioUrl,
        thumbnailUrl: thumbnailUrl,
        senderName: senderName,
        senderPhotoURL: senderPhotoURL,
        replyTo: _replyingTo,
      );

      if (messageId != null) {
        clearReply();
        return true;
      } else {
        _setError('Error enviando mensaje');
        return false;
      }
    } catch (e) {
      _setError('Error enviando mensaje: $e');
      return false;
    } finally {
      _setSending(false);
    }
  }

  /// Set message to reply to
  void setReplyTo(GroupMessage message) {
    _replyingTo = message;
    onReplyingToChanged?.call(_replyingTo);
  }

  /// Clear reply
  void clearReply() {
    _replyingTo = null;
    onReplyingToChanged?.call(_replyingTo);
  }

  /// Add reaction to message
  Future<void> addReaction(String messageId, String emoji) async {
    try {
      await _groupService.addReaction(
        groupId: groupId,
        messageId: messageId,
        emoji: emoji,
      );
    } catch (e) {
      _setError('Error agregando reacción: $e');
    }
  }

  /// Remove reaction from message
  Future<void> removeReaction(String messageId, String emoji) async {
    try {
      await _groupService.removeReaction(
        groupId: groupId,
        messageId: messageId,
        emoji: emoji,
      );
    } catch (e) {
      _setError('Error removiendo reacción: $e');
    }
  }

  /// Mark messages as read
  Future<void> markAsRead(List<String> messageIds) async {
    try {
      await _groupService.markMessagesAsRead(
        groupId: groupId,
        messageIds: messageIds,
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error marking messages as read: $e',
        tag: 'GroupChatController',
      );
    }
  }

  /// Edit a message
  Future<bool> editMessage(String messageId, String newText) async {
    try {
      await _groupService.editMessage(
        groupId: groupId,
        messageId: messageId,
        newText: newText,
      );
      return true;
    } catch (e) {
      _setError('Error editando mensaje: $e');
      return false;
    }
  }

  /// Delete a message
  Future<bool> deleteMessage(String messageId) async {
    try {
      await _groupService.deleteMessage(
        groupId: groupId,
        messageId: messageId,
      );
      return true;
    } catch (e) {
      _setError('Error eliminando mensaje: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // OPTIMISTIC SENDING
  // ═══════════════════════════════════════════════════════════════

  /// Add an optimistic message (shows immediately while uploading)
  void addOptimisticMessage(GroupMessage message) {
    _optimisticMessages.insert(0, message);
    onMessagesChanged?.call(messages);
    ReleaseLogger.log('Optimistic message added: ${message.id}', tag: 'GroupChatController');
  }

  /// Remove an optimistic message (after upload completes or fails)
  void removeOptimisticMessage(String messageId) {
    _optimisticMessages.removeWhere((m) => m.id == messageId);
    onMessagesChanged?.call(messages);
    ReleaseLogger.log('Optimistic message removed: $messageId', tag: 'GroupChatController');
  }

  /// Check if a message is optimistic (local, not yet uploaded)
  bool isOptimisticMessage(String messageId) {
    return _optimisticMessages.any((m) => m.id == messageId);
  }

  // Private helpers
  void _setLoading(bool value) {
    _isLoading = value;
    onLoadingChanged?.call(value);
  }

  void _setSending(bool value) {
    _isSending = value;
    onSendingChanged?.call(value);
  }

  void _setError(String message) {
    _error = message;
    onError?.call(message);
    ReleaseLogger.error(message, tag: 'GroupChatController');
  }

  /// Dispose resources
  void dispose() {
    _groupSubscription?.cancel();
    _messagesSubscription?.cancel();
  }
}
