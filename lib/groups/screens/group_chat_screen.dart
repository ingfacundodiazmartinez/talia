import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
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
import '../../services/reaction_service.dart';
import '../../services/favorite_service.dart';
import '../../services/media_compression_service.dart';
import '../../notification_service.dart';
import '../../widgets/reaction_picker.dart';
import '../../utils/release_logger.dart';
import '../../services/local_unread_count_service.dart';

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
    with WidgetsBindingObserver {
  // Controller
  late GroupChatController _controller;
  bool _controllerInitialized = false;

  // UI Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final ReactionService _reactionService = ReactionService();
  final FavoriteService _favoriteService = FavoriteService();

  // Favorites tracking
  Set<String> _favoriteMessageIds = {};
  StreamSubscription<Set<String>>? _favoritesSubscription;

  // Local UI state
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  Map<String, dynamic>? _replyingTo;
  OverlayEntry? _reactionOverlay;

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
      if (mounted) setState(() {});
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
    _audioRecorder.dispose();
    _reactionOverlay?.remove();
    super.dispose();
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
      await _audioRecorder.stop();
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

      // Upload to Firebase Storage
      final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('groups_v2/${widget.groupId}/images/$fileName');

      final uploadTask = await storageRef.putFile(
        fileToUpload,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      final imageUrl = await uploadTask.ref.getDownloadURL();

      // Remove optimistic message (real one will come from stream)
      _controller.removeOptimisticMessage(tempId);

      // Send message with image
      final success = await _controller.sendMediaMessage(
        imageUrl: imageUrl,
        senderName: senderName,
        senderPhotoURL: senderPhotoURL,
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
      final hasPermission = await _audioRecorder.hasPermission();

      if (!hasPermission) {
        return;
      }

      HapticFeedback.heavyImpact();

      final directory = await getApplicationDocumentsDirectory();
      final path =
          '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al iniciar grabacion'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);

      if (path != null && path.isNotEmpty) {
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
          localAudioPath: path,
          isOptimistic: true,
          timestamp: DateTime.now(),
          isDeleted: false,
          reactions: {},
          readBy: [],
        );

        // Add optimistic message immediately
        _controller.addOptimisticMessage(optimisticMessage);

        try {
          final audioFile = File(path);

          // Upload to Firebase Storage
          final fileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
          final storageRef = FirebaseStorage.instance
              .ref()
              .child('groups_v2/${widget.groupId}/audios/$fileName');

          final uploadTask = await storageRef.putFile(
            audioFile,
            SettableMetadata(contentType: 'audio/mp4'),
          );

          final audioUrl = await uploadTask.ref.getDownloadURL();

          // Remove optimistic message (real one will come from stream)
          _controller.removeOptimisticMessage(tempId);

          // Send message with audio
          final success = await _controller.sendMediaMessage(
            audioUrl: audioUrl,
            senderName: senderName,
            senderPhotoURL: senderPhotoURL,
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
      body: Column(
        children: [
          Expanded(child: _buildMessagesList()),
          if (_replyingTo != null) _buildReplyBar(),
          _buildInputBar(),
          if (_showEmojiPicker) _buildEmojiPicker(),
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
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => GroupProfileScreenV2(
                groupId: widget.groupId,
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _controller.groupName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
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
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => GroupProfileScreenV2(
                  groupId: widget.groupId,
                ),
              ),
            );
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

    // Handle optimistic messages (uploading)
    if (message.isOptimistic) {
      return _buildOptimisticMessageBubble(message, timeString);
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
        'senderName': message.replyTo!.senderName,
        'hasMedia': message.replyTo!.hasMedia,
      };
    }

    return MessageBubble(
      key: ValueKey('msg_${message.id}'),
      messageId: message.id,
      chatId: widget.groupId,
      text: message.text,
      imageUrl: message.imageUrl,
      videoUrl: message.videoUrl,
      audioUrl: message.audioUrl,
      status: MessageStatus.sent,
      replyTo: replyToMap,
      reactions: reactionsMap.isNotEmpty ? reactionsMap : null,
      isMe: isMe,
      time: timeString,
      senderId: message.senderId,
      senderName: message.senderName,
      timestamp: timestamp,
      isGroupChat: true,
      senderPhotoURL: message.senderPhotoURL,
      contactName: widget.groupName,
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
            'senderName': message.senderName,
            if (message.imageUrl != null) 'imageUrl': message.imageUrl,
            if (message.videoUrl != null) 'videoUrl': message.videoUrl,
            if (message.audioUrl != null) 'audioUrl': message.audioUrl,
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

  void _showReactionPicker(BuildContext messageContext, String messageId) async {
    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 100));

    final RenderBox? renderBox = messageContext.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;

    const pickerWidth = 280.0;
    double leftPosition = position.dx;

    if (leftPosition + pickerWidth > screenWidth) {
      leftPosition = position.dx + size.width - pickerWidth;
      if (leftPosition < 0) {
        leftPosition = (screenWidth - pickerWidth) / 2;
      }
    }

    _reactionOverlay?.remove();
    _reactionOverlay = OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: () {
          _reactionOverlay?.remove();
          _reactionOverlay = null;
        },
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                top: position.dy - 60,
                left: leftPosition,
                child: Material(
                  color: Colors.transparent,
                  child: ReactionPicker(
                    onReactionSelected: (reaction) {
                      _reactionOverlay?.remove();
                      _reactionOverlay = null;
                      _reactionService.toggleReaction(
                        chatId: widget.groupId,
                        messageId: messageId,
                        reaction: reaction,
                        isGroup: true,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_reactionOverlay!);

    Future.delayed(const Duration(seconds: 5), () {
      _reactionOverlay?.remove();
      _reactionOverlay = null;
    });
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
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 250,
      child: EmojiPicker(
        onEmojiSelected: (category, emoji) {
          _messageController.text += emoji.emoji;
        },
        config: Config(
          height: 250,
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            columns: 7,
            emojiSizeMax: 32.0,
            verticalSpacing: 0,
            horizontalSpacing: 0,
            gridPadding: EdgeInsets.zero,
            backgroundColor:
                isDarkMode ? colorScheme.surface : const Color(0xFFF2F2F2),
            buttonMode: ButtonMode.MATERIAL,
            recentsLimit: 28,
            noRecents: const Text(
              'Sin emojis recientes',
              style: TextStyle(fontSize: 20, color: Colors.black26),
              textAlign: TextAlign.center,
            ),
            loadingIndicator: const SizedBox.shrink(),
          ),
          categoryViewConfig: CategoryViewConfig(
            initCategory: Category.RECENT,
            indicatorColor: colorScheme.primary,
            iconColor: Colors.grey,
            iconColorSelected: colorScheme.primary,
            backspaceColor: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
