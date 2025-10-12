import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../controllers/group_chat_controller.dart';
import '../notification_service.dart';
import '../services/reaction_service.dart';
import '../services/contact_alias_service.dart';
import '../widgets/reaction_picker.dart';
import '../models/chat_message.dart';
import 'chat/widgets/group_chat_app_bar.dart';
import 'chat/widgets/message_bubble.dart';
import 'chat/widgets/chat_input_bar.dart';
import 'chat/widgets/reply_bar.dart';
import 'chat/widgets/group_typing_indicator.dart';
import 'chat/widgets/attachment_options.dart';
import 'chat/widgets/recording_indicator.dart';
import 'group_profile/group_profile_screen.dart';

/// Pantalla de chat grupal
///
/// Responsabilidades (SOLO UI):
/// - Renderizar interfaz del chat grupal
/// - Manejar estado local de UI (emoji picker, grabación, reply)
/// - Coordinar llamadas al controller
/// - Navegación
class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> with WidgetsBindingObserver {
  // Controller (maneja toda la lógica de negocio)
  late GroupChatController _controller;

  // Controllers de UI
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final ReactionService _reactionService = ReactionService();
  final ContactAliasService _aliasService = ContactAliasService();

  // Estado local de UI SOLAMENTE
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  String? _audioPath;
  Map<String, dynamic>? _replyingTo;
  OverlayEntry? _reactionOverlay;

  // Paginación (estado UI)
  bool _isLoadingMore = false;
  final List<DocumentSnapshot> _loadedMessages = [];

  @override
  void initState() {
    super.initState();

    // Agregar observer para lifecycle events (permisos, etc)
    WidgetsBinding.instance.addObserver(this);

    // Establecer el chat actual (grupo) para suprimir notificaciones de este grupo
    NotificationService().setCurrentChat(widget.groupId);

    _controller = GroupChatController(
      groupId: widget.groupId,
      groupName: widget.groupName,
    );
    _controller.initialize();
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTypingChanged);
  }

  @override
  void dispose() {
    // Limpiar el chat actual para permitir notificaciones de nuevo
    NotificationService().clearCurrentChat();

    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _reactionOverlay?.remove();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Si la app pierde el foco (ej: aparece diálogo de permisos) y estamos grabando,
    // detener la grabación para evitar que quede bloqueada
    if (state == AppLifecycleState.inactive && _isRecording) {
      print('⚠️ [GroupChatScreen] App inactive mientras grababa - cancelando grabación');
      _cancelRecording();
    }
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      setState(() => _isRecording = false);
      print('✅ [GroupChatScreen] Grabación cancelada');
    } catch (e) {
      print('❌ [GroupChatScreen] Error cancelando grabación: $e');
      setState(() => _isRecording = false);
    }
  }

  // Event Handlers (llaman al controller, NO tienen lógica compleja)

  void _onTypingChanged() {
    _controller.setTyping(_messageController.text.isNotEmpty);
  }

  void _onScroll() {
    if (_scrollController.position.pixels <= 100 &&
        _controller.hasMoreMessages &&
        !_isLoadingMore) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore) return;

    setState(() => _isLoadingMore = true);

    final newMessages = await _controller.loadMoreMessages();

    if (mounted) {
      setState(() {
        _loadedMessages.addAll(newMessages);
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    final success = await _controller.sendTextMessage(
      text: text,
      replyTo: _replyingTo,
    );

    if (success && mounted) {
      setState(() => _replyingTo = null);
    } else if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al enviar mensaje'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleSendImage(ImageSource source) async {
    Navigator.pop(context); // Cerrar bottom sheet

    final success = await _controller.sendImage(
      imagePath: '',
      fromCamera: source == ImageSource.camera,
    );

    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al enviar imagen'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleSendVideo() async {
    Navigator.pop(context); // Cerrar bottom sheet

    final success = await _controller.sendVideo();

    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al enviar video'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _startRecording() async {
    try {
      // PRIMERO verificar/solicitar permisos, LUEGO vibrar y grabar
      final hasPermission = await _audioRecorder.hasPermission();

      if (!hasPermission) {
        print('⚠️ [GroupChatScreen] No hay permisos de micrófono');
        return;
      }

      // Solo después de tener permisos confirmados: vibrar e iniciar
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
        _audioPath = path;
      });
    } catch (e) {
      print('❌ Error iniciando grabación: $e');
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
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);

      if (path != null && path.isNotEmpty) {
        final success = await _controller.sendAudio(path);
        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al enviar audio'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      print('❌ Error deteniendo grabación: $e');
    }
  }

  void _showAttachmentOptions() {
    AttachmentOptions.show(
      context,
      onCameraTap: () => _handleSendImage(ImageSource.camera),
      onGalleryTap: () => _handleSendImage(ImageSource.gallery),
      onVideoTap: _handleSendVideo,
    );
  }

  void _showReactionPicker(BuildContext messageContext, String messageId) {
    final RenderBox? renderBox =
        messageContext.findRenderObject() as RenderBox?;
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

  Future<void> _handleDeleteMessage(String messageId, Timestamp? timestamp) async {
    final success = await _controller.deleteMessage(messageId, timestamp);

    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo eliminar el mensaje'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Build Methods (SOLO UI)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GroupChatAppBar(
        groupId: widget.groupId,
        groupName: widget.groupName,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => GroupProfileScreen(
                groupId: widget.groupId,
              ),
            ),
          );
        },
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _buildMessagesList()),
              _buildTypingIndicator(),
              if (_replyingTo != null) _buildReplyBar(),
              _buildInputBar(),
              if (_showEmojiPicker) _buildEmojiPicker(),
            ],
          ),
          // Indicador de grabación (overlay)
          if (_isRecording)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: const RecordingIndicator(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessagesList() {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<QuerySnapshot>(
      stream: _controller.watchRecentMessages(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        if (snapshot.connectionState == ConnectionState.waiting &&
            _loadedMessages.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final recentMessages = snapshot.data?.docs ?? [];
        final recentIds = recentMessages.map((doc) => doc.id).toSet();
        final olderMessages =
            _loadedMessages.where((doc) => !recentIds.contains(doc.id)).toList();

        final allMessages = [...recentMessages, ...olderMessages];

        if (allMessages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 64,
                  color: colorScheme.outlineVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  'Comienza la conversación',
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        final hasLoader = _isLoadingMore ? 1 : 0;
        final totalCount = allMessages.length + hasLoader;

        return ListView.builder(
          controller: _scrollController,
          reverse: true,
          physics: const ClampingScrollPhysics(),
          cacheExtent: 1000,
          addAutomaticKeepAlives: true,
          addRepaintBoundaries: true,
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          itemCount: totalCount,
          findChildIndexCallback: (Key key) {
            if (key is ValueKey<String>) {
              final messageId = key.value.replaceFirst('msg_', '');
              final index = allMessages.indexWhere((doc) => doc.id == messageId);
              return index >= 0 ? index : null;
            }
            return null;
          },
          itemBuilder: (context, index) {
            if (index < allMessages.length) {
              final messageDoc = allMessages[index];
              final messageData = messageDoc.data() as Map<String, dynamic>;
              final senderId = messageData['senderId'] ?? '';
              final isMe = senderId == FirebaseAuth.instance.currentUser!.uid;
              final timestamp = messageData['timestamp'] as Timestamp?;
              final timeString = timestamp != null
                  ? '${timestamp.toDate().hour}:${timestamp.toDate().minute.toString().padLeft(2, '0')}'
                  : '';

              // Parse moderation status from Firestore
              ModerationStatus? moderationStatus;
              final modStatusString = messageData['moderationStatus'] as String?;
              if (modStatusString != null) {
                switch (modStatusString) {
                  case 'approved':
                    moderationStatus = ModerationStatus.approved;
                    break;
                  case 'blocked':
                    moderationStatus = ModerationStatus.blocked;
                    break;
                  case 'pending':
                    moderationStatus = ModerationStatus.pending;
                    break;
                }
              }

              // Obtener nombre real y alias en tiempo real
              return StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance.collection('users').doc(senderId).snapshots(),
                builder: (context, userSnapshot) {
                  String realName = 'Usuario';
                  String photoURL = '';

                  if (userSnapshot.hasData && userSnapshot.data!.exists) {
                    final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                    realName = userData?['name'] ?? 'Usuario';
                    photoURL = userData?['photoURL'] ?? '';
                  }

                  // Obtener alias (si existe) o nombre real
                  return StreamBuilder<String>(
                    stream: _aliasService.watchDisplayName(senderId, realName),
                    builder: (context, aliasSnapshot) {
                      final displayName = aliasSnapshot.data ?? realName;

                      return MessageBubble(
                        key: ValueKey('msg_${messageDoc.id}'),
                        messageId: messageDoc.id,
                        chatId: widget.groupId,
                        text: messageData['text'],
                        imageUrl: messageData['imageUrl'],
                        videoUrl: messageData['videoUrl'],
                        audioUrl: messageData['audioUrl'],
                        replyTo: messageData['replyTo'],
                        reactions: messageData['reactions'],
                        isMe: isMe,
                        time: timeString,
                        senderId: senderId,
                        senderName: displayName,
                        timestamp: timestamp,
                        moderationStatus: moderationStatus,
                        moderationReason: messageData['moderationReason'] as String?,
                        moderationSeverity: messageData['moderationSeverity'] as String?,
                        isGroupChat: true,
                        senderPhotoURL: photoURL,
                        onReply: () {
                          setState(() {
                            _replyingTo = {
                              'id': messageDoc.id,
                              'text': messageData['text'] ?? '',
                              'senderId': senderId,
                              'senderName': displayName,
                              if (messageData['imageUrl'] != null) 'imageUrl': messageData['imageUrl'],
                              if (messageData['videoUrl'] != null) 'videoUrl': messageData['videoUrl'],
                              if (messageData['audioUrl'] != null) 'audioUrl': messageData['audioUrl'],
                            };
                          });
                        },
                        onLongPress: _showReactionPicker,
                        onDelete: _handleDeleteMessage,
                      );
                    },
                  );
                },
              );
            }

            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTypingIndicator() {
    return StreamBuilder<List<String>>(
      stream: _controller.watchTypingUsers(),
      builder: (context, snapshot) {
        final typingUserIds = snapshot.data ?? [];
        if (typingUserIds.isEmpty) return const SizedBox();

        // Obtener nombres de los usuarios escribiendo
        final typingUserNames = typingUserIds
            .map((userId) => _controller.getUserName(userId))
            .toList();

        return GroupTypingIndicator(typingUserNames: typingUserNames);
      },
    );
  }

  Widget _buildReplyBar() {
    return ReplyBar(
      senderName: _replyingTo!['senderName'] ?? 'Usuario',
      text: _replyingTo!['text'] ?? '',
      onClose: () => setState(() => _replyingTo = null),
    );
  }

  Widget _buildInputBar() {
    return ChatInputBar(
      messageController: _messageController,
      showEmojiPicker: _showEmojiPicker,
      isRecording: _isRecording,
      onToggleEmojiPicker: () =>
          setState(() => _showEmojiPicker = !_showEmojiPicker),
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
          skinToneConfig: const SkinToneConfig(
            enabled: true,
            dialogBackgroundColor: Colors.white,
            indicatorColor: Colors.grey,
          ),
          categoryViewConfig: CategoryViewConfig(
            initCategory: Category.RECENT,
            indicatorColor: colorScheme.primary,
            iconColor: Colors.grey,
            iconColorSelected: colorScheme.primary,
            backspaceColor: colorScheme.primary,
            tabIndicatorAnimDuration: kTabScrollDuration,
            categoryIcons: const CategoryIcons(),
          ),
        ),
      ),
    );
  }
}
