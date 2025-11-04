import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../controllers/chat_controller_optimistic.dart';
import '../notification_service.dart';
import '../services/foreground_message_listener.dart';
import '../services/reaction_service.dart';
import '../widgets/reaction_picker.dart';
import 'chat/widgets/chat_app_bar.dart';
import 'chat/widgets/chat_input_bar.dart';
import 'chat/widgets/reply_bar.dart';
import 'chat/widgets/editing_bar.dart';
import 'chat/widgets/attachment_options.dart';
import 'chat/widgets/recording_indicator.dart';
import 'chat/widgets/blocked_message_bar.dart';
import 'chat/widgets/emoji_picker_widget.dart';
import 'chat/widgets/message_list_widget.dart';
import 'chat/widgets/chat_selection_bar_widget.dart';
import 'chat/widgets/media_handlers_mixin.dart';
import 'contact_profile_screen.dart';
import 'video_call_screen.dart';
import 'audio_call_screen.dart';
import 'forward_messages_screen.dart';

/// Pantalla de chat individual (1 a 1) - REFACTORIZADA
///
/// Responsabilidades (SOLO UI):
/// - Renderizar interfaz del chat
/// - Manejar estado local de UI
/// - Coordinar llamadas al controller
/// - Navegación
class ChatDetailScreen extends StatefulWidget {
  final String contactId;
  final String contactName;
  final String chatId;
  final String? scrollToMessageId;

  const ChatDetailScreen({
    super.key,
    required this.contactId,
    required this.contactName,
    required this.chatId,
    this.scrollToMessageId,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen>
    with WidgetsBindingObserver, MediaHandlersMixin {
  // Controller
  late ChatControllerOptimistic _controller;

  // UI Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final ReactionService _reactionService = ReactionService();

  // Local UI state
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  bool _isSendingMessage = false;
  Map<String, dynamic>? _replyingTo;
  OverlayEntry? _reactionOverlay;
  bool _isSelectionMode = false;
  final Set<String> _selectedMessageIds = {};
  String? _highlightedMessageId;
  bool _hasScrolledToMessage = false;
  Map<String, dynamic>? _editingBlockedMessage;

  @override
  ChatControllerOptimistic get controller => _controller;

  @override
  void initState() {
    super.initState();
    // ReleaseLogger.log('Inicializando ChatDetailScreen para chatId: ${widget.chatId}', tag: 'ChatDetail');

    WidgetsBinding.instance.addObserver(this);
    NotificationService().setCurrentChat(widget.chatId);
    ForegroundMessageListener().setCurrentOpenChat(widget.chatId);

    // 🗑️ Limpiar notificaciones de este chat al abrirlo
    NotificationService().clearChatNotifications(widget.chatId);

    _controller = ChatControllerOptimistic(
      chatId: widget.chatId,
      contactId: widget.contactId,
      contactName: widget.contactName,
    );
    _controller.initialize();
    _controller.addListener(_onControllerChanged);
    _messageController.addListener(_onTypingChanged);
    _scrollController.addListener(_onScroll);
    _controller.markChatAsRead();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.scrollToMessageId != null) {
        _scrollToSpecificMessage(widget.scrollToMessageId!);
      } else {
        _scrollToBottom(animate: false);
      }
    });
  }

  @override
  void dispose() {
    // ReleaseLogger.log('Disposing ChatDetailScreen para chatId: ${widget.chatId}', tag: 'ChatDetail');
    NotificationService().clearCurrentChat();
    ForegroundMessageListener().setCurrentOpenChat(null);
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.removeListener(_onScroll);
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
  }

  // Event Handlers

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.scrollToMessageId == null || _hasScrolledToMessage) {
        _scrollToBottom();
      } else {
        _scrollToSpecificMessage(widget.scrollToMessageId!);
      }
    });
  }

  void _onTypingChanged() {
    _controller.setTyping(_messageController.text.isNotEmpty);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    if (currentScroll >= maxScroll * 0.8) {
      _controller.loadMoreMessages();
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels > 100) return;

    if (animate) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(0);
    }
  }

  void _scrollToSpecificMessage(String messageId) {
    if (!_scrollController.hasClients || _hasScrolledToMessage) return;

    final messageIndex = _controller.messages.indexWhere((msg) => msg.id == messageId);

    if (messageIndex == -1) {
      // ReleaseLogger.log('Mensaje $messageId no encontrado aún', tag: 'ChatDetail');
      return;
    }

    // ReleaseLogger.log('Scroll a mensaje $messageId en índice $messageIndex', tag: 'ChatDetail');
    _hasScrolledToMessage = true;

    const itemHeight = 120.0;
    final targetPosition = messageIndex * itemHeight;

    _scrollController.animateTo(
      targetPosition,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );

    setState(() {
      _highlightedMessageId = messageId;
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _highlightedMessageId = null;
        });
      }
    });
  }

  Future<void> _handleSendMessage() async {
    if (_controller.isBlocked || _controller.isBlockedBy) {
      _showBlockedSnackbar();
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty || _isSendingMessage) return;

    // Prevenir envíos duplicados
    setState(() => _isSendingMessage = true);

    try {
      final replyToCapture = _replyingTo;
      final editingMessageId = _editingBlockedMessage?['id'];

      _messageController.clear();

      if (mounted) {
        setState(() {
          _replyingTo = null;
          _editingBlockedMessage = null;
        });
      }

      if (editingMessageId != null) {
        await _controller.updateBlockedMessage(editingMessageId, text);
      } else {
        await _controller.sendTextMessage(text: text, replyTo: replyToCapture);
      }
    } catch (e) {
      _handleSendError(e, text);
    } finally {
      if (mounted) {
        setState(() => _isSendingMessage = false);
      }
    }
  }

  void _showBlockedSnackbar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _controller.isBlocked
              ? 'No puedes enviar mensajes a este contacto porque lo has bloqueado'
              : 'Este contacto te ha bloqueado',
        ),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _handleSendError(Object error, String text) {
    if (!mounted) return;

    _messageController.text = text;
    final dialogContent = error.toString().replaceFirst('Exception: ', '');

    _controller.getCurrentUserData().then((userData) {
      final isParent = userData?['isParent'] ?? true;

      final title = isParent ? 'Mensaje bloqueado' : 'Mensaje no permitido';
      final explanation = isParent
          ? 'Este mensaje contiene contenido inapropiado detectado por la moderación con IA:\n\n$dialogContent'
          : 'Tus padres han activado la moderación con IA en este chat.\n\nMotivo del bloqueo: $dialogContent';

      if (mounted) {
        _showModerationDialog(title, explanation);
      }
    }).catchError((_) {
      if (mounted) {
        _showModerationDialog('Mensaje bloqueado', dialogContent);
      }
    });
  }

  void _showModerationDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.block, color: Colors.red),
            const SizedBox(width: 12),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(content, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      setState(() => _isRecording = false);
    } catch (e) {
      // ReleaseLogger.error('Error cancelando grabación: $e', tag: 'ChatDetail');
      setState(() => _isRecording = false);
    }
  }

  Future<void> _startRecording() async {
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) return;

      HapticFeedback.heavyImpact();

      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      if (mounted) {
        setState(() {
          _isRecording = true;
        });
      }
    } catch (e) {
      // ReleaseLogger.error('Error iniciando grabación: $e', tag: 'ChatDetail');
      if (mounted) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar grabación: ${e.toString()}'),
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
        // 1. Crear burbuja optimista inmediatamente con waveform real
        await _controller.createOptimisticAudioBubble(path);

        // 2. Subir en background
        _controller.processAndUploadAudio(path).catchError((e) {
          // ReleaseLogger.error('Error subiendo audio en background: $e', tag: 'ChatDetail');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error enviando audio: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        });
      }
    } catch (e) {
      // ReleaseLogger.error('Error deteniendo grabación: $e', tag: 'ChatDetail');
    }
  }

  void _showAttachmentOptions() {
    AttachmentOptions.show(
      context,
      onCameraTap: () => handleSendImage(ImageSource.camera),
      onGalleryTap: () => handleSendImage(ImageSource.gallery),
      onVideoTap: handleSendVideo,
    );
  }

  void _showReactionPicker(BuildContext messageContext, String messageId) async {
    FocusScope.of(context).unfocus();
    final screenWidth = MediaQuery.of(context).size.width;
    final overlay = Overlay.of(context);
    final RenderBox? renderBox = messageContext.findRenderObject() as RenderBox?;

    await Future.delayed(const Duration(milliseconds: 100));

    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

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
                        chatId: widget.chatId,
                        messageId: messageId,
                        reaction: reaction,
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

    overlay.insert(_reactionOverlay!);

    Future.delayed(const Duration(seconds: 5), () {
      _reactionOverlay?.remove();
      _reactionOverlay = null;
    });
  }

  Future<void> _handleDeleteMessage(String messageId, Timestamp? timestamp) async {
    final success = await _controller.deleteMessage(messageId, timestamp);

    if (mounted && !success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo eliminar el mensaje'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleEditBlockedMessage(String messageId, String originalText) async {
    setState(() {
      _messageController.text = originalText;
      _editingBlockedMessage = {
        'id': messageId,
        'originalText': originalText,
      };
    });
    FocusScope.of(context).requestFocus(FocusNode());
  }

  Future<void> _handleClearChat() async {
    final success = await _controller.clearChat();

    if (mounted && !success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo limpiar el chat'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _forwardSelectedMessages(BuildContext context) async {
    if (_selectedMessageIds.isEmpty) return;

    final selectedMessages = _controller.messages
        .where((msg) => _selectedMessageIds.contains(msg.id))
        .toList();

    setState(() {
      _isSelectionMode = false;
      _selectedMessageIds.clear();
    });

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ForwardMessagesScreen(
          messages: selectedMessages,
          originalChatId: widget.chatId,
          contactName: widget.contactName,
        ),
      ),
    );
  }

  Future<void> _handleCallBack(String callType) async {
    try {
      // ReleaseLogger.log('Devolviendo llamada ($callType) a ${widget.contactName}', tag: 'ChatDetail');

      if (mounted) {
        if (callType == 'audio') {
          Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (context) => AudioCallScreen(
                callId: DateTime.now().millisecondsSinceEpoch.toString(),
                receiverId: widget.contactId,
                remoteName: widget.contactName,
                isCaller: true,
              ),
            ),
          );
        } else {
          Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (context) => VideoCallScreen(
                callId: DateTime.now().millisecondsSinceEpoch.toString(),
                receiverId: widget.contactId,
                remoteName: widget.contactName,
                isCaller: true,
                isVideo: true,
              ),
            ),
          );
        }
      }
    } catch (e) {
      // ReleaseLogger.error('Error devolviendo llamada: $e', tag: 'ChatDetail');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al devolver llamada: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Build Methods

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isSelectionMode
          ? ChatSelectionBarWidget(
              selectedCount: _selectedMessageIds.length,
              onForward: () => _forwardSelectedMessages(context),
              onCancel: () {
                setState(() {
                  _isSelectionMode = false;
                  _selectedMessageIds.clear();
                });
              },
            )
          : ChatAppBar(
              contactId: widget.contactId,
              contactName: widget.contactName,
              contactPhotoURL: _controller.contactPhotoURL,
              chatId: widget.chatId,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => ContactProfileScreen(
                      contactId: widget.contactId,
                      contactName: widget.contactName,
                      chatId: widget.chatId,
                    ),
                  ),
                );
              },
              onClearChat: _handleClearChat,
            ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: SafeArea(child: _buildMessagesList()),
              ),
              if (_controller.isBlocked || _controller.isBlockedBy)
                BlockedMessageBar(
                  isBlocked: _controller.isBlocked,
                  isBlockedBy: _controller.isBlockedBy,
                ),
              if (_replyingTo != null) _buildReplyBar(),
              if (_editingBlockedMessage != null) _buildEditingBar(),
              _buildInputBar(),
              if (_showEmojiPicker) _buildEmojiPicker(),
            ],
          ),
          if (_isRecording)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: const RecordingIndicator(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessagesList() {
    return MessageListWidget(
      controller: _controller,
      scrollController: _scrollController,
      chatId: widget.chatId,
      contactName: widget.contactName,
      isSelectionMode: _isSelectionMode,
      selectedMessageIds: _selectedMessageIds,
      highlightedMessageId: _highlightedMessageId,
      onToggleSelection: () {
        setState(() {
          _isSelectionMode = false;
          _selectedMessageIds.clear();
        });
      },
      onToggleMessageSelection: (messageId) {
        setState(() {
          if (_selectedMessageIds.contains(messageId)) {
            _selectedMessageIds.remove(messageId);
          } else {
            _selectedMessageIds.add(messageId);
          }
        });
      },
      onShowReactionPicker: _showReactionPicker,
      onReply: (messageId, messageData) {
        setState(() {
          _replyingTo = messageData;
        });
      },
      onReplyTap: _scrollToSpecificMessage,
      onDelete: _handleDeleteMessage,
      onEdit: _handleEditBlockedMessage,
      onSelectMessages: (messageId) {
        setState(() {
          _isSelectionMode = true;
          _selectedMessageIds.add(messageId);
        });
      },
      onCallBack: _handleCallBack,
    );
  }

  Widget _buildReplyBar() {
    return ReplyBar(
      senderName: _replyingTo!['senderName'] ?? 'Usuario',
      text: _replyingTo!['text'] ?? '',
      onClose: () => setState(() => _replyingTo = null),
    );
  }

  Widget _buildEditingBar() {
    return EditingBar(
      originalText: _editingBlockedMessage!['originalText'] ?? '',
      onClose: () {
        setState(() {
          _editingBlockedMessage = null;
          _messageController.clear();
        });
      },
    );
  }

  Widget _buildInputBar() {
    if (_controller.isBlocked || _controller.isBlockedBy) {
      return const SizedBox.shrink();
    }

    return ChatInputBar(
      messageController: _messageController,
      showEmojiPicker: _showEmojiPicker,
      isRecording: _isRecording,
      onToggleEmojiPicker: () => setState(() => _showEmojiPicker = !_showEmojiPicker),
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
