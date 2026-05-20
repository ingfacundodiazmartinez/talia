import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../services/group_message_cache_service.dart';
import '../../services/reaction_service.dart';  // ✅ NEW: For reactions
import '../../services/media_compression_service.dart';
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
  StreamSubscription? _deletedMessagesSubscription;  // ✅ NEW: Para eventos de eliminación

  // ✅ Track message IDs that failed to mark as read (prevent infinite retry loop)
  final Set<String> _failedMarkAsReadIds = {};

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

  /// Get group avatar URL
  String? get groupAvatar => _group?.avatar;

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

      // ✅ NEW: Suscribirse a eventos de eliminación de mensajes
      _startListeningToDeletedMessages();
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

  /// ✅ NEW: Escuchar eventos de eliminación de mensajes
  /// Cuando otro usuario elimina un mensaje, lo marcamos como eliminado localmente
  void _startListeningToDeletedMessages() {
    _deletedMessagesSubscription?.cancel();

    _deletedMessagesSubscription = FirebaseFirestore.instance
        .collection('groups_v2')
        .doc(groupId)
        .collection('deletedMessages')
        .snapshots()
        .listen(
      (snapshot) {
        if (_isDisposed) return;

        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final messageId = change.doc.id;
            _markMessageAsDeletedLocally(messageId);
          }
        }
      },
      onError: (error) {
        if (_isDisposed || _isPermissionError(error)) {
          _deletedMessagesSubscription?.cancel();
          return;
        }
        ReleaseLogger.error(
          'Error in deletedMessages stream: $error',
          tag: 'GroupChatController',
        );
      },
    );
  }

  /// ✅ NEW: Marcar un mensaje como eliminado en memoria y cache
  void _markMessageAsDeletedLocally(String messageId) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;

    final message = _messages[index];
    if (message.isDeleted) return; // Ya está eliminado

    // Crear copia con isDeleted = true
    final deletedMessage = GroupMessage(
      id: message.id,
      senderId: message.senderId,
      senderName: message.senderName,
      senderPhotoURL: message.senderPhotoURL,
      text: null, // Limpiar texto
      imageUrl: null,
      videoUrl: null,
      audioUrl: null,
      timestamp: message.timestamp,
      readBy: message.readBy,
      reactions: message.reactions,
      replyTo: message.replyTo,
      isDeleted: true,
      localId: message.localId,
    );

    _messages[index] = deletedMessage;
    _cacheService.saveMessages(groupId, [deletedMessage]);
    onMessagesChanged?.call(messages);

    ReleaseLogger.log(
      'Message $messageId marked as deleted locally',
      tag: 'GroupChatController',
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
    // ✅ Filtro unificado por visibleTo (mismo criterio que chats 1-1):
    // - Mensajes propios: siempre visibles para el sender.
    // - Mensajes ajenos: solo si visibleTo es null o me incluye.
    // Esto cubre tanto bloqueos (sender en grupos con miembros que lo bloquearon)
    // como moderación pendiente (visibleTo=[senderId] hasta que CF apruebe).
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null) {
      firestoreMessages = firestoreMessages
          .where((m) => m.senderId == currentUid || m.isVisibleTo(currentUid))
          .toList();
    }

    // Guardar mensajes nuevos en cache
    _cacheService.saveMessages(groupId, firestoreMessages);

    // Crear mapa de mensajes existentes por ID
    final existingById = {for (final m in _messages) m.id: m};

    // Actualizar con mensajes de Firestore (más recientes tienen prioridad)
    for (final msg in firestoreMessages) {
      existingById[msg.id] = msg;

      // Remove corresponding optimistic message if localId matches
      if (msg.localId != null) {
        _optimisticMessages.removeWhere(
          (m) => m.localId == msg.localId || m.id == msg.localId,
        );
      }
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
  /// ✅ FIX: Track failed IDs to prevent infinite retry loop on PERMISSION_DENIED
  Future<void> _autoMarkMessagesAsRead(List<GroupMessage> newMessages) async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    // Find messages not sent by current user and not yet read by them
    // ✅ FIX: Exclude messages that previously failed (prevent infinite loop)
    final unreadMessageIds = newMessages
        .where((m) =>
            m.senderId != currentUserId &&
            !m.readBy.contains(currentUserId) &&
            !_failedMarkAsReadIds.contains(m.id))
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
        // ✅ FIX: Add failed IDs to prevent infinite retry loop
        _failedMarkAsReadIds.addAll(unreadMessageIds);
        ReleaseLogger.error(
          'Error auto-marking messages as read (will not retry): $e',
          tag: 'GroupChatController',
        );
      }
    }
  }

  /// Send a text message with optimistic UI updates
  /// When moderation is enabled, message shows with pending status until moderated
  Future<bool> sendTextMessage(String text, {
    String? senderName,
    String? senderPhotoURL,
  }) async {
    if (text.trim().isEmpty) return false;

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return false;

    // Generate local ID for optimistic matching
    final localId = const Uuid().v4();
    final trimmedText = text.trim();

    // Check if group has moderation enabled
    final hasModeration = _group?.moderationEnabled ?? false;

    // Create optimistic message (shows immediately)
    final optimisticMessage = GroupMessage(
      id: localId, // Use localId as temporary ID
      senderId: currentUserId,
      senderName: senderName ?? FirebaseAuth.instance.currentUser?.displayName ?? 'Usuario',
      senderPhotoURL: senderPhotoURL ?? FirebaseAuth.instance.currentUser?.photoURL,
      text: trimmedText,
      timestamp: DateTime.now(),
      isDeleted: false,
      reactions: {},
      readBy: [currentUserId],
      // Show pending status if moderation is enabled
      moderationStatus: hasModeration ? 'pending' : null,
      isOptimistic: true,
      localId: localId,
      replyTo: _replyingTo != null
          ? ReplyPreview(
              messageId: _replyingTo!.id,
              senderId: _replyingTo!.senderId,
              senderName: _replyingTo!.senderName,
              text: _replyingTo!.text,
              hasMedia: _replyingTo!.hasMedia,
            )
          : null,
    );

    // Add optimistic message immediately
    _optimisticMessages.add(optimisticMessage);
    onMessagesChanged?.call(messages);

    // Clear reply immediately for better UX
    final replyToSend = _replyingTo;
    clearReply();

    _setSending(true);

    try {
      final messageId = await _groupService.sendTextMessage(
        groupId: groupId,
        text: trimmedText,
        senderName: senderName,
        senderPhotoURL: senderPhotoURL,
        replyTo: replyToSend,
        localId: localId,
      );

      if (messageId != null) {
        // Message sent successfully - Firestore stream will bring the real message
        // which will replace the optimistic one via localId matching
        ReleaseLogger.log(
          'Message sent: $messageId (localId: $localId)',
          tag: 'GroupChatController',
        );
        return true;
      } else {
        // Failed to send - mark optimistic message as error
        _removeOptimisticMessage(localId);
        _setError('Error enviando mensaje');
        return false;
      }
    } catch (e) {
      // Error - remove optimistic message
      _removeOptimisticMessage(localId);
      _setError('Error enviando mensaje: $e');
      return false;
    } finally {
      _setSending(false);
    }
  }

  /// Remove an optimistic message by its localId
  void _removeOptimisticMessage(String localId) {
    _optimisticMessages.removeWhere((m) => m.id == localId || m.localId == localId);
    onMessagesChanged?.call(messages);
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
    String? localId, // For optimistic UI matching
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
        localId: localId,
      );

      if (messageId != null) {
        clearReply();
        return true;
      } else {
        _setError('Error enviando mensaje (messageId null)');
        return false;
      }
    } catch (e, stack) {
      // ✅ DEBUG: incluir tipo y mensaje específico para diagnóstico via snackbar
      _setError('Error: ${e.runtimeType} → $e');
      ReleaseLogger.error(
        'sendMediaMessage threw: $e',
        error: e,
        stackTrace: stack,
        tag: 'GroupChatController',
      );
      return false;
    } finally {
      _setSending(false);
    }
  }

  /// Pick image from source, upload to Storage, and send. Handles optimistic UI.
  /// Returns true on success, false on failure (optimistic message removed automatically).
  Future<bool> sendImageFromPicker(ImageSource source) async {
    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: source,
      maxWidth: 1080,
      maxHeight: 1080,
      imageQuality: 85,
    );
    if (image == null) return false;

    return _uploadAndSendMedia(
      localPath: image.path,
      isVideo: false,
    );
  }

  /// Pick video from gallery, upload to Storage, and send. Handles optimistic UI.
  Future<bool> sendVideoFromPicker() async {
    final picker = ImagePicker();
    final XFile? video = await picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 2),
    );
    if (video == null) return false;

    return _uploadAndSendMedia(
      localPath: video.path,
      isVideo: true,
    );
  }

  /// Common path: optimistic → upload → send. Used by both image and video.
  Future<bool> _uploadAndSendMedia({
    required String localPath,
    required bool isVideo,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return false;

    // Get sender info (cached or from Firestore)
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .get();
    final userData = userDoc.data();
    final senderName = userData?['name'] ?? currentUser.displayName ?? 'Usuario';
    final senderPhotoURL = userData?['photoURL'] ?? currentUser.photoURL;

    // Optimistic message
    final tempId = 'temp_${isVideo ? 'video' : 'image'}_${DateTime.now().millisecondsSinceEpoch}';
    final optimisticMessage = GroupMessage(
      id: tempId,
      senderId: currentUser.uid,
      senderName: senderName,
      senderPhotoURL: senderPhotoURL,
      localImagePath: localPath,
      isOptimistic: true,
      timestamp: DateTime.now(),
      isDeleted: false,
      reactions: {},
      readBy: [],
    );
    addOptimisticMessage(optimisticMessage);

    try {
      // Compress image if applicable (videos pass through)
      File fileToUpload = File(localPath);
      if (!isVideo) {
        final compressed = await MediaCompressionService().compressImage(fileToUpload);
        fileToUpload = compressed ?? fileToUpload;
      }

      // Upload to Firebase Storage
      final folder = isVideo ? 'videos' : 'images';
      final ext = isVideo ? 'mp4' : 'jpg';
      final contentType = isVideo ? 'video/mp4' : 'image/jpeg';
      final fileName = '${isVideo ? 'vid' : 'img'}_${DateTime.now().millisecondsSinceEpoch}.$ext';

      final storageRef = FirebaseStorage.instance
          .ref()
          .child('groups_v2/$groupId/${currentUser.uid}/$folder/$fileName');

      final uploadTask = await storageRef.putFile(
        fileToUpload,
        SettableMetadata(contentType: contentType),
      );
      final mediaUrl = await uploadTask.ref.getDownloadURL();

      // Send via existing sendMediaMessage (handles moderation + optimistic reconciliation by localId)
      final ok = await sendMediaMessage(
        imageUrl: isVideo ? null : mediaUrl,
        videoUrl: isVideo ? mediaUrl : null,
        senderName: senderName,
        senderPhotoURL: senderPhotoURL,
        localId: tempId,
      );

      if (!ok) {
        _removeOptimisticMessage(tempId);
      } else {
        ReleaseLogger.log(
          '${isVideo ? 'Video' : 'Image'} sent to group $groupId',
          tag: 'GroupChatController',
        );
      }
      return ok;
    } catch (e, stack) {
      _removeOptimisticMessage(tempId);
      _setError('Error: ${e.runtimeType} → $e');
      ReleaseLogger.error(
        '_uploadAndSendMedia threw: $e',
        error: e,
        stackTrace: stack,
        tag: 'GroupChatController',
      );
      return false;
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

  /// Delete a message for everyone
  /// ✅ FIX: Usar deleteForEveryone que setea isDeleted: true
  /// (deleteForMe usa deletedFor[] que GroupMessage no parsea)
  /// ✅ FIX: También maneja "ghost messages" que solo existen en cache
  /// ✅ FIX: Marcar como eliminado en lugar de remover (mostrar "Este mensaje fue eliminado")
  Future<bool> deleteMessage(String messageId) async {
    try {
      ReleaseLogger.log(
        'Attempting to delete message: $messageId',
        tag: 'GroupChatController',
      );

      final result = await _deleteMessageService.deleteForEveryone(
        chatId: groupId,
        messageId: messageId,
        isGroup: true,
      );

      ReleaseLogger.log(
        'Delete result: success=${result.success}, message=${result.message}',
        tag: 'GroupChatController',
      );

      // ✅ FIX: Marcar como eliminado en lugar de remover
      // Esto permite mostrar "Este mensaje fue eliminado" en la UI
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        final deletedMessage = _messages[index].copyWith(
          isDeleted: true,
          text: null,
          imageUrl: null,
          videoUrl: null,
          audioUrl: null,
        );
        _messages[index] = deletedMessage;
        // Actualizar cache con el mensaje marcado como eliminado
        await _cacheService.updateMessage(groupId, deletedMessage);
        onMessagesChanged?.call(messages);
      }

      if (!result.success) {
        // Si el mensaje no existe en Firestore pero estaba en cache,
        // lo marcamos como eliminado y consideramos éxito
        if (result.message == 'Mensaje no encontrado') {
          ReleaseLogger.log(
            'Ghost message marked as deleted: $messageId',
            tag: 'GroupChatController',
          );
          return true;
        }
        _setError('Error eliminando mensaje: ${result.message}');
        return false;
      }

      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Delete exception: $e',
        tag: 'GroupChatController',
      );
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

  /// Cancel all subscriptions (called before leaving group)
  /// This prevents permission errors when the user loses access
  void cancelSubscriptions() {
    _isDisposed = true;
    _groupSubscription?.cancel();
    _messagesSubscription?.cancel();
    _reactionsSubscription?.cancel();
    ReleaseLogger.log('Subscriptions cancelled for group $groupId', tag: 'GroupChatController');
  }

  /// Dispose resources
  void dispose() {
    _isDisposed = true;  // ✅ FIX: Marcar como disposed PRIMERO para ignorar errores pendientes
    _groupSubscription?.cancel();
    _messagesSubscription?.cancel();
    _reactionsSubscription?.cancel();
    _deletedMessagesSubscription?.cancel();
  }
}
