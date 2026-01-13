import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import '../controllers/controllers.dart';
import '../models/models.dart';
import 'group_profile_screen.dart';
import 'group_message_info_screen.dart';
import '../../screens/chat/widgets/chat_input_bar.dart';
import '../../screens/chat/widgets/message_bubble.dart';
import '../../screens/chat/widgets/reply_bar.dart';
import '../../models/chat_message.dart';
// ReactionService imported via ReactionPickerMixin
import '../../services/favorite_service.dart';
import '../../services/media_compression_service.dart';
import '../../notification_service.dart';
// ReactionPicker imported via ReactionPickerMixin
import '../../utils/release_logger.dart';
import '../../services/local_unread_count_service.dart';
import '../../services/notification_tracking_service.dart';
import '../../screens/chat/widgets/recording_input_bar.dart';
import '../../screens/chat/widgets/emoji_picker_widget.dart';
import '../../screens/chat/mixins/reaction_picker_mixin.dart';
import '../../widgets/profile_photo_viewer.dart';
import '../../services/contact_alias_service.dart';

/// Chat screen for Groups V2
///
/// Displays messages, handles sending, and provides real-time updates.
class GroupChatScreenV2 extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? scrollToMessageId;

  const GroupChatScreenV2({
    super.key,
    required this.groupId,
    required this.groupName,
    this.scrollToMessageId,
  });

  @override
  State<GroupChatScreenV2> createState() => _GroupChatScreenV2State();
}

class _GroupChatScreenV2State extends State<GroupChatScreenV2>
    with WidgetsBindingObserver, ReactionPickerMixin {
  // Controller
  late GroupChatController _controller;
  bool _controllerInitialized = false;

  // UI Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final RecorderController _recorderController = RecorderController();
  // ReactionService is provided by ReactionPickerMixin
  final FavoriteService _favoriteService = FavoriteService();
  final ContactAliasService _aliasService = ContactAliasService();

  // Cache de alias para mostrar nombres personalizados
  final Map<String, String> _aliasCache = {};

  // Favorites tracking
  Set<String> _favoriteMessageIds = {};
  StreamSubscription<Set<String>>? _favoritesSubscription;

  // Local UI state
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  String? _currentRecordingPath;
  Map<String, dynamic>? _replyingTo;
  bool _hasScrolledToMessage = false; // ✅ FIX: Track if we've scrolled to target message
  // _reactionOverlay is provided by ReactionPickerMixin

  // Current user ID
  String? get _currentUserId => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messageController.addListener(_onMessageTextChanged);
    // Set current chat to suppress notifications while viewing this group
    NotificationService().setCurrentChat(widget.groupId);
    // ✅ FIX: Marcar que estamos en el grupo y resetear contador de no leídos
    LocalUnreadCountService().enterChat(widget.groupId);
    // ✅ Auto-dismiss: Limpiar notificaciones de este grupo cuando el usuario entra
    NotificationTrackingService().dismissNotificationsForContext(
      type: NotificationContext.group,
      contextId: widget.groupId,
    );
    _initializeChat();
  }

  void _onMessageTextChanged() {
    // Force rebuild to update send/mic button
    if (mounted) setState(() {});
  }

  Future<void> _initializeChat() async {
    _controller = GroupChatController(groupId: widget.groupId);

    _controller.onGroupChanged = (group) {
      if (mounted) setState(() {});
    };

    _controller.onMessagesChanged = (messages) {
      // Cargar alias para usuarios que no sean yo
      _loadAliasesForMessages(messages);
      if (mounted) setState(() {});

      // ✅ FIX: Scroll to target message when messages are loaded
      if (widget.scrollToMessageId != null && !_hasScrolledToMessage && messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSpecificMessage(widget.scrollToMessageId!);
        });
      }
    };

    _controller.onLoadingChanged = (loading) {
      if (mounted) setState(() {});
    };

    _controller.onSendingChanged = (sending) {
      if (mounted) setState(() {});
    };

    _controller.onReplyingToChanged = (replyingTo) {
      if (mounted) setState(() {});
    };

    _controller.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Colors.red,
          ),
        );
      }
    };

    await _controller.initialize();

    // Subscribe to favorites stream
    _favoritesSubscription = _favoriteService
        .getFavoriteMessageIdsStream(
          chatId: widget.groupId,
          isGroupChat: true,
        )
        .listen((favoriteIds) {
      if (mounted) {
        setState(() {
          _favoriteMessageIds = favoriteIds;
        });
      }
    });

    if (mounted) {
      setState(() {
        _controllerInitialized = true;
      });
    }
  }

  /// ✅ FIX: Scroll to a specific message by ID
  void _scrollToSpecificMessage(String messageId) {
    if (!_scrollController.hasClients || _hasScrolledToMessage) return;

    final messages = _controller.messages;
    final messageIndex = messages.indexWhere((msg) => msg.id == messageId);

    if (messageIndex == -1) {
      // Message not found yet, will retry when more messages load
      return;
    }

    _hasScrolledToMessage = true;

    // Since ListView is reversed, we need to calculate position differently
    // Use estimated item height
    const estimatedItemHeight = 80.0;
    final targetPosition = messageIndex * estimatedItemHeight;

    _scrollController.animateTo(
      targetPosition,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.removeListener(_onMessageTextChanged);
    _favoritesSubscription?.cancel();
    // Clear current chat to allow notifications again
    NotificationService().clearCurrentChat();
    // ✅ FIX: Marcar que salimos del grupo
    LocalUnreadCountService().exitChat();
    _controller.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    _recorderController.dispose();
    disposeReactionPicker(); // From ReactionPickerMixin
    super.dispose();
  }

  /// Cargar alias para los remitentes de los mensajes
  Future<void> _loadAliasesForMessages(List<GroupMessage> messages) async {
    final currentUserId = _currentUserId;
    if (currentUserId == null) return;

    // Obtener IDs únicos de remitentes que no soy yo y que no están en cache
    final senderIds = messages
        .where((m) => m.senderId != currentUserId && !_aliasCache.containsKey(m.senderId))
        .map((m) => m.senderId)
        .toSet();

    if (senderIds.isEmpty) return;

    // Cargar alias para cada sender
    for (final senderId in senderIds) {
      final message = messages.firstWhere((m) => m.senderId == senderId);
      final displayName = await _aliasService.getDisplayName(senderId, message.senderName);
      _aliasCache[senderId] = displayName;
    }

    // Rebuild si se agregaron alias nuevos
    if (mounted && senderIds.isNotEmpty) {
      setState(() {});
    }
  }

  /// Obtener nombre a mostrar (alias si existe, sino nombre real)
  String _getDisplayName(String senderId, String realName) {
    return _aliasCache[senderId] ?? realName;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && _isRecording) {
      _cancelRecording();
    }

    // ✅ FIX: Manejar background/foreground para unread counts
    if (state == AppLifecycleState.paused) {
      LocalUnreadCountService().exitChat();
    } else if (state == AppLifecycleState.resumed) {
      LocalUnreadCountService().enterChat(widget.groupId);
    }
  }

  Future<void> _cancelRecording() async {
    try {
      await _recorderController.stop();
      _currentRecordingPath = null;
      setState(() => _isRecording = false);
    } catch (e) {
      setState(() => _isRecording = false);
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    // If replying, find the GroupMessage and set it in the controller
    if (_replyingTo != null) {
      final replyToId = _replyingTo!['id'] as String?;
      if (replyToId != null) {
        final replyMessage = _controller.messages.where((m) => m.id == replyToId).firstOrNull;
        if (replyMessage != null) {
          _controller.setReplyTo(replyMessage);
        }
      }
    }

    // Get current user info for sender name
    final currentUser = FirebaseAuth.instance.currentUser;
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser?.uid)
        .get();
    final userData = userDoc.data();

    await _controller.sendTextMessage(
      text,
      senderName: userData?['name'] ?? currentUser?.displayName ?? 'Usuario',
      senderPhotoURL: userData?['photoURL'] ?? currentUser?.photoURL,
    );

    // Clear reply state
    if (_replyingTo != null) {
      setState(() => _replyingTo = null);
    }
  }

  Future<void> _handleSendImage(ImageSource source) async {
    Navigator.pop(context);

    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: source,
      maxWidth: 1080,
      maxHeight: 1080,
      imageQuality: 85,
    );

    if (image == null) return;

    // Get current user info first
    final currentUser = FirebaseAuth.instance.currentUser;
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser?.uid)
        .get();
    final userData = userDoc.data();
    final senderName = userData?['name'] ?? currentUser?.displayName ?? 'Usuario';
    final senderPhotoURL = userData?['photoURL'] ?? currentUser?.photoURL;

    // Create optimistic message with local path
    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final optimisticMessage = GroupMessage(
      id: tempId,
      senderId: currentUser?.uid ?? '',
      senderName: senderName,
      senderPhotoURL: senderPhotoURL,
      localImagePath: image.path,
      isOptimistic: true,
      timestamp: DateTime.now(),
      isDeleted: false,
      reactions: {},
      readBy: [],
    );

    // Add optimistic message immediately
    _controller.addOptimisticMessage(optimisticMessage);

    try {
      // Compress image in background
      final compressedFile = await MediaCompressionService().compressImage(
        File(image.path),
      );

      final fileToUpload = compressedFile ?? File(image.path);

      // Upload to Firebase Storage (path includes userId for security rules)
      final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
      final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('groups_v2/${widget.groupId}/$userId/images/$fileName');

      final uploadTask = await storageRef.putFile(
        fileToUpload,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      final imageUrl = await uploadTask.ref.getDownloadURL();

      // Send message with image - pass localId for optimistic UI matching
      // The optimistic message will be replaced when Firestore returns the real message
      final success = await _controller.sendMediaMessage(
        imageUrl: imageUrl,
        senderName: senderName,
        senderPhotoURL: senderPhotoURL,
        localId: tempId, // For optimistic UI matching
      );

      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error enviando imagen'),
            backgroundColor: Colors.red,
          ),
        );
      }

      ReleaseLogger.log('Image sent to group ${widget.groupId}', tag: 'GroupChat');
    } catch (e) {
      // Remove optimistic message on error
      _controller.removeOptimisticMessage(tempId);
      ReleaseLogger.error('Error sending image: $e', tag: 'GroupChat');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error enviando imagen'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    try {
      HapticFeedback.heavyImpact();

      final directory = await getApplicationDocumentsDirectory();
      final path =
          '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _currentRecordingPath = path;

      await _recorderController.record(
        path: path,
        bitRate: 48000,
        sampleRate: 22050,
      );

      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al iniciar grabación'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _recorderController.stop();
      final recordedPath = path ?? _currentRecordingPath;
      _currentRecordingPath = null;
      setState(() => _isRecording = false);

      if (recordedPath != null && recordedPath.isNotEmpty) {
        // Get current user info first
        final currentUser = FirebaseAuth.instance.currentUser;
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser?.uid)
            .get();
        final userData = userDoc.data();
        final senderName = userData?['name'] ?? currentUser?.displayName ?? 'Usuario';
        final senderPhotoURL = userData?['photoURL'] ?? currentUser?.photoURL;

        // Create optimistic message with local path
        final tempId = 'temp_audio_${DateTime.now().millisecondsSinceEpoch}';
        final optimisticMessage = GroupMessage(
          id: tempId,
          senderId: currentUser?.uid ?? '',
          senderName: senderName,
          senderPhotoURL: senderPhotoURL,
          localAudioPath: recordedPath,
          isOptimistic: true,
          timestamp: DateTime.now(),
          isDeleted: false,
          reactions: {},
          readBy: [],
        );

        // Add optimistic message immediately
        _controller.addOptimisticMessage(optimisticMessage);

        try {
          final audioFile = File(recordedPath);

          // Upload to Firebase Storage (path includes userId for security rules)
          final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
          final fileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
          final storageRef = FirebaseStorage.instance
              .ref()
              .child('groups_v2/${widget.groupId}/$userId/audios/$fileName');

          final uploadTask = await storageRef.putFile(
            audioFile,
            SettableMetadata(contentType: 'audio/mp4'),
          );

          final audioUrl = await uploadTask.ref.getDownloadURL();

          // Send message with audio - pass localId for optimistic UI matching
          // The optimistic message will be replaced when Firestore returns the real message
          final success = await _controller.sendMediaMessage(
            audioUrl: audioUrl,
            senderName: senderName,
            senderPhotoURL: senderPhotoURL,
            localId: tempId, // For optimistic UI matching
          );

          if (!success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Error enviando audio'),
                backgroundColor: Colors.red,
              ),
            );
          }

          // Clean up temp file
          try {
            await audioFile.delete();
          } catch (_) {}

          ReleaseLogger.log('Audio sent to group ${widget.groupId}', tag: 'GroupChat');
        } catch (e) {
          // Remove optimistic message on error
          _controller.removeOptimisticMessage(tempId);
          ReleaseLogger.error('Error sending audio: $e', tag: 'GroupChat');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Error enviando audio'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } catch (e) {
      setState(() => _isRecording = false);
      ReleaseLogger.error('Error stopping recording: $e', tag: 'GroupChat');
    }
  }

  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camara'),
              onTap: () => _handleSendImage(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galeria'),
              onTap: () => _handleSendImage(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: _buildAppBar(colorScheme),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _buildMessagesList()),
              if (_replyingTo != null) _buildReplyBar(),
              _buildInputBar(),
              if (_showEmojiPicker) _buildEmojiPicker(),
            ],
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ColorScheme colorScheme) {
    return AppBar(
      backgroundColor: colorScheme.primary,
      foregroundColor: Colors.white,
      title: GestureDetector(
        onTap: () {
          Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (context) => GroupProfileScreenV2(
                groupId: widget.groupId,
                onBeforeLeave: _controller.cancelSubscriptions,
              ),
            ),
          ).then((result) {
            if (result == 'left' && mounted) {
              // Usuario salió del grupo - navegar a la pantalla principal
              Navigator.of(context).pop();
            }
          });
        },
        child: Row(
          children: [
            // Group avatar
            ClickableAvatar(
              photoUrl: _controller.groupAvatar,
              name: _controller.groupName,
              radius: 18,
            ),
            const SizedBox(width: 12),
            // Group name and member count
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _controller.groupName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${_controller.memberCount} miembros',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () {
            Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (context) => GroupProfileScreenV2(
                  groupId: widget.groupId,
                  onBeforeLeave: _controller.cancelSubscriptions,
                ),
              ),
            ).then((result) {
              if (result == 'left' && mounted) {
                // Usuario salió del grupo - navegar a la pantalla principal
                Navigator.of(context).pop();
              }
            });
          },
        ),
      ],
    );
  }

  Widget _buildMessagesList() {
    if (!_controllerInitialized || _controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final messages = _controller.messages;

    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Comienza la conversacion',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.all(16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _buildMessageBubble(message);
      },
    );
  }

  Widget _buildMessageBubble(GroupMessage message) {
    final isMe = message.senderId == _currentUserId;
    final timestamp = Timestamp.fromDate(message.timestamp);
    final timeString = _formatTime(message.timestamp);

    // Handle deleted messages
    if (message.isDeleted) {
      return _buildDeletedMessageBubble(message, isMe, timeString);
    }

    // Handle optimistic messages for MEDIA only (image, video, audio uploading)
    // Text messages (with or without moderation) should go through MessageBubble
    final isMediaOptimistic = message.isOptimistic &&
        (message.localImagePath != null ||
         message.localVideoPath != null ||
         message.localAudioPath != null);
    if (isMediaOptimistic) {
      return _buildOptimisticMessageBubble(message, timeString);
    }

    // Convert moderationStatus string to ModerationStatus enum
    ModerationStatus? moderationStatus;
    if (message.moderationStatus == 'blocked') {
      moderationStatus = ModerationStatus.blocked;
    } else if (message.moderationStatus == 'pending') {
      moderationStatus = ModerationStatus.pending;
    } else if (message.moderationStatus == 'approved') {
      moderationStatus = ModerationStatus.approved;
    }

    // Convert reactions from Map<String, List<String>> to Map<String, dynamic>
    final reactionsMap = <String, dynamic>{};
    for (final entry in message.reactions.entries) {
      reactionsMap[entry.key] = entry.value;
    }

    // Convert replyTo from ReplyPreview to Map<String, dynamic>
    Map<String, dynamic>? replyToMap;
    if (message.replyTo != null) {
      replyToMap = {
        'id': message.replyTo!.messageId,
        'text': message.replyTo!.text,
        'senderId': message.replyTo!.senderId,
        'senderName': _getDisplayName(message.replyTo!.senderId, message.replyTo!.senderName),
        'hasMedia': message.replyTo!.hasMedia,
      };
    }

    // Use 'sending' status for optimistic messages or pending moderation to show spinner
    final messageStatus = (message.isOptimistic || moderationStatus == ModerationStatus.pending)
        ? MessageStatus.sending
        : MessageStatus.sent;

    return MessageBubble(
      key: ValueKey('msg_${message.id}'),
      messageId: message.id,
      chatId: widget.groupId,
      text: message.text,
      imageUrl: message.imageUrl,
      videoUrl: message.videoUrl,
      audioUrl: message.audioUrl,
      status: messageStatus,
      replyTo: replyToMap,
      reactions: reactionsMap.isNotEmpty ? reactionsMap : null,
      isMe: isMe,
      time: timeString,
      senderId: message.senderId,
      senderName: _getDisplayName(message.senderId, message.senderName),
      timestamp: timestamp,
      isGroupChat: true,
      senderPhotoURL: message.senderPhotoURL,
      contactName: widget.groupName,
      // ✅ FIX #8: Pass forwarded message fields to MessageBubble
      isForwarded: message.isForwarded,
      originalContactName: message.originalContactName,
      // Moderation fields for blocked messages
      moderationStatus: moderationStatus,
      moderationReason: message.moderationReason,
      originalText: message.isBlocked ? message.text : null,
      isFavorite: _favoriteMessageIds.contains(message.id),
      onFavoriteToggled: () {
        // Force rebuild to update favorite indicator
        if (mounted) setState(() {});
      },
      onReply: () {
        setState(() {
          _replyingTo = {
            'id': message.id,
            'text': message.text ?? '',
            'senderId': message.senderId,
            'senderName': _getDisplayName(message.senderId, message.senderName),
            'contentType': message.contentType,
            if (message.imageUrl != null && message.imageUrl!.isNotEmpty)
              'imageUrl': message.imageUrl,
            if (message.videoUrl != null && message.videoUrl!.isNotEmpty)
              'videoUrl': message.videoUrl,
            if (message.audioUrl != null && message.audioUrl!.isNotEmpty)
              'audioUrl': message.audioUrl,
          };
        });
      },
      onLongPress: _showReactionPicker,
      onDelete: (messageId, _) => _handleDeleteMessage(messageId),
      onViewMessageInfo: isMe ? () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupMessageInfoScreen(
              groupId: widget.groupId,
              messageId: message.id,
            ),
          ),
        );
      } : null,
    );
  }

  String _formatTime(DateTime timestamp) {
    return '${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
  }

  /// Build a bubble for optimistic messages (uploading)
  Widget _buildOptimisticMessageBubble(GroupMessage message, String timeString) {
    final colorScheme = Theme.of(context).colorScheme;
    final isImage = message.localImagePath != null;
    final isAudio = message.localAudioPath != null;

    // Para audio: diseño simple sin overlay
    if (isAudio) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Enviando...',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.9)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white.withValues(alpha: 0.8)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Para imágenes: preview con overlay sutil
    if (isImage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Imagen
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(
                      File(message.localImagePath!),
                      fit: BoxFit.cover,
                      height: 200,
                      width: double.infinity,
                    ),
                  ),
                  // Overlay sutil con spinner
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Enviando...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Fallback para otros tipos
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Enviando...',
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(width: 8),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a placeholder for deleted messages
  /// Siempre muestra la foto del sender para identificar quién envió el mensaje eliminado
  Widget _buildDeletedMessageBubble(GroupMessage message, bool isMe, String timeString) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Foto del sender (siempre visible para mensajes eliminados)
          if (!isMe) ...[
            _buildSenderAvatar(message, colorScheme),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // Nombre del sender (solo para mensajes de otros)
                if (!isMe)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: Text(
                      message.senderName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.65,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMe
                        ? colorScheme.primary.withValues(alpha: 0.1)
                        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.block,
                        size: 16,
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Este mensaje fue eliminado',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        timeString,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Foto del sender a la derecha para mensajes propios eliminados
          if (isMe) ...[
            const SizedBox(width: 8),
            _buildSenderAvatar(message, colorScheme),
          ],
        ],
      ),
    );
  }

  /// Build avatar for sender
  Widget _buildSenderAvatar(GroupMessage message, ColorScheme colorScheme) {
    return CircleAvatar(
      radius: 16,
      backgroundColor: colorScheme.primaryContainer,
      child: message.senderPhotoURL != null && message.senderPhotoURL!.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: message.senderPhotoURL!,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                placeholder: (context, url) => Icon(
                  Icons.person,
                  size: 14,
                  color: colorScheme.onPrimaryContainer,
                ),
                errorWidget: (context, url, error) => Icon(
                  Icons.person,
                  size: 14,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            )
          : Text(
              message.senderName.isNotEmpty
                  ? message.senderName[0].toUpperCase()
                  : '?',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
    );
  }

  /// Shows reaction picker using the shared mixin
  void _showReactionPicker(BuildContext messageContext, String messageId) {
    showReactionPicker(
      messageContext,
      messageId,
      chatId: widget.groupId,
      isGroup: true,
    );
  }

  Future<void> _handleDeleteMessage(String messageId) async {
    final success = await _controller.deleteMessage(messageId);

    if (mounted && !success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo eliminar el mensaje'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildReplyBar() {
    return ReplyBar(
      messageData: _replyingTo!,
      onClose: () => setState(() => _replyingTo = null),
    );
  }

  Widget _buildInputBar() {
    // Mostrar UI de grabación estilo Instagram cuando está grabando
    if (_isRecording) {
      return RecordingInputBar(
        recorderController: _recorderController,
        onCancel: _cancelRecording,
        onSend: _stopRecording,
      );
    }

    return ChatInputBar(
      messageController: _messageController,
      showEmojiPicker: _showEmojiPicker,
      isRecording: _isRecording,
      onToggleEmojiPicker: () {
        setState(() {
          _showEmojiPicker = !_showEmojiPicker;
        });
        if (_showEmojiPicker) {
          FocusScope.of(context).unfocus();
        }
      },
      onAttachTap: _showAttachmentOptions,
      onSendTap: _handleSendMessage,
      onRecordStart: _startRecording,
      onRecordEnd: _stopRecording,
      onSubmitMessage: _handleSendMessage,
    );
  }

  Widget _buildEmojiPicker() {
    return EmojiPickerWidget(
      onEmojiSelected: (category, emoji) {
        _messageController.text += emoji.emoji;
      },
    );
  }
}
