import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../services/group_message_cache_service.dart';
import '../../services/reaction_service.dart';  // ✅ NEW: For reactions
// ✅ Nuevos servicios atómicos
import '../../services/chats/chat_services.dart';
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
  final ReactionService _reactionService;  // ✅ NEW
  // ✅ Nuevos servicios atómicos
  final EditMessageService _editMessageService;
  final DeleteMessageService _deleteMessageService;

  // State
  Group? _group;
  List<GroupMessage> _messages = [];
  final List<GroupMessage> _optimisticMessages = []; // Mensajes locales enviándose
  bool _isLoading = false;
  bool _isSending = false;
  GroupMessage? _replyingTo;
  String? _error;
  bool _isDisposed = false;  // ✅ NEW: Para ignorar errores después de dispose

  // Subscriptions
  StreamSubscription? _groupSubscription;
  StreamSubscription? _messagesSubscription;
  StreamSubscription<Map<String, Map<String, List<String>>>>? _reactionsSubscription;  // ✅ NEW

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
    ReactionService? reactionService,
    EditMessageService? editMessageService,
    DeleteMessageService? deleteMessageService,
  }) : _groupService = groupService ?? GroupService(),
       _cacheService = cacheService ?? GroupMessageCacheService(),
       _reactionService = reactionService ?? ReactionService(),
       _editMessageService = editMessageService ?? EditMessageService(),
       _deleteMessageService = deleteMessageService ?? DeleteMessageService();

  // Getters
  Group? get group => _group;
  /// Combined list of optimistic + real messages, sorted by timestamp
  /// ✅ FIX: Filtra mensajes anteriores a clearedAt (cuando el usuario "limpia" el grupo)
  List<GroupMessage> get messages {
    final combined = [..._optimisticMessages, ..._messages];
    // Remove duplicates (optimistic messages replaced by real ones)
    final seen = <String>{};
    var unique = combined.where((m) {
      if (seen.contains(m.id)) return false;
      seen.add(m.id);
      return true;
    }).toList();

    // ✅ FIX: Filtrar mensajes anteriores a clearedAt
    final clearedAt = ChatPreferencesCache().getClearedAt(groupId);
    if (clearedAt != null) {
      unique = unique.where((m) => m.timestamp.isAfter(clearedAt)).toList();
    }

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
          if (_isDisposed) return;
          _group = group;
          onGroupChanged?.call(_group);
        },
        onError: (e) {
          // ✅ FIX: Ignorar errores de permisos (ocurre cuando el usuario sale del grupo)
          if (_isDisposed || _isPermissionError(e)) {
            _groupSubscription?.cancel();
            return;
          }
          _setError('Error en grupo: $e');
        },
      );

      _messagesSubscription = _groupService.watchMessages(groupId).listen(
        (firestoreMessages) {
          if (_isDisposed) return;
          // Merge: actualizar cache con mensajes de Firestore
          _mergeAndCacheMessages(firestoreMessages);
        },
        onError: (e) {
          // ✅ FIX: Ignorar errores de permisos (ocurre cuando el usuario sale del grupo)
          if (_isDisposed || _isPermissionError(e)) {
            _messagesSubscription?.cancel();
            return;
          }
          _setError('Error en mensajes: $e');
        },
      );

      // ✅ NEW: Suscribirse al stream de reacciones
      _startListeningToReactions();
    } catch (e) {
      _setError('Error inicializando chat: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// ✅ NEW: Start listening to reactions stream
  void _startListeningToReactions() {
    _reactionsSubscription?.cancel();

    _reactionsSubscription = _reactionService.watchReactions(
      chatId: groupId,
      isGroup: true,
    ).listen(
      (reactionsMap) {
        if (_isDisposed) return;
        _updateMessagesWithReactions(reactionsMap);
      },
      onError: (error) {
        // ✅ FIX: Ignorar errores de permisos (ocurre cuando el usuario sale del grupo)
        if (_isDisposed || _isPermissionError(error)) {
          _reactionsSubscription?.cancel();
          return;
        }
        ReleaseLogger.error('Error in reactions stream for group $groupId: $error', tag: 'GroupChatController');
      },
    );
  }

  /// ✅ Helper: Check if error is a permission error (expected when leaving group)
  bool _isPermissionError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('permission') ||
           errorStr.contains('permission_denied') ||
           errorStr.contains('permission-denied') ||
           errorStr.contains('insufficient');
  }

  /// ✅ NEW: Update messages with reactions from subcollection
  void _updateMessagesWithReactions(Map<String, Map<String, List<String>>> reactionsMap) {
    if (reactionsMap.isEmpty && _messages.every((m) => m.reactions.isEmpty)) {
      return;
    }

    bool hasChanges = false;

    for (int i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final messageReactions = reactionsMap[message.id] ?? {};

      // Comparar si hay cambios
      if (!_reactionsAreEqual(message.reactions, messageReactions)) {
        _messages[i] = message.copyWith(reactions: messageReactions);
        hasChanges = true;
      }
    }

    if (hasChanges) {
      onMessagesChanged?.call(messages);
      ReleaseLogger.log('✅ [Reactions] Updated reactions for group $groupId', tag: 'GroupChatController');
    }
  }

  /// ✅ Helper: Compare two reaction maps
  bool _reactionsAreEqual(Map<String, List<String>> a, Map<String, List<String>> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      final aList = a[key]!;
      final bList = b[key]!;
      if (aList.length != bList.length) return false;
      for (int i = 0; i < aList.length; i++) {
        if (aList[i] != bList[i]) return false;
      }
    }
    return true;
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
  /// ✅ Usa nuevo servicio atómico EditMessageService
  Future<bool> editMessage(String messageId, String newText) async {
    try {
      final result = await _editMessageService.call(
        chatId: groupId,
        messageId: messageId,
        newText: newText,
        isGroup: true,
      );
      if (!result.success) {
        _setError('Error editando mensaje: ${result.message}');
      }
      return result.success;
    } catch (e) {
      _setError('Error editando mensaje: $e');
      return false;
    }
  }

  /// Delete a message
  /// ✅ Usa nuevo servicio atómico DeleteMessageService
  Future<bool> deleteMessage(String messageId) async {
    try {
      final result = await _deleteMessageService.deleteForMe(
        chatId: groupId,
        messageId: messageId,
        isGroup: true,
      );
      if (!result.success) {
        _setError('Error eliminando mensaje: ${result.message}');
      }
      return result.success;
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
    _isDisposed = true;  // ✅ FIX: Marcar como disposed PRIMERO para ignorar errores pendientes
    _groupSubscription?.cancel();
    _messagesSubscription?.cancel();
    _reactionsSubscription?.cancel();
  }
}
