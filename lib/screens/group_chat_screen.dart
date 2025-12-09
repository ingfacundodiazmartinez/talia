import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../controllers/group_chat_controller.dart';
import '../utils/release_logger.dart';
import '../notification_service.dart';
import '../services/local_unread_count_service.dart';
import '../services/reaction_service.dart';
import '../services/read_receipts_service.dart';
import '../services/delivery_receipts_service.dart';
import '../services/audio_processing_service.dart';
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
import 'message_info_screen.dart';

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
  final String? scrollToMessageId;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    this.scrollToMessageId,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> with WidgetsBindingObserver {
  // Controller (maneja toda la lógica de negocio)
  late GroupChatController _controller;
  bool _controllerInitialized = false;

  // Controllers de UI
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final ReactionService _reactionService = ReactionService();
  final ReadReceiptsService _readReceiptsService = ReadReceiptsService();
  final DeliveryReceiptsService _deliveryReceiptsService = DeliveryReceiptsService();

  // Estado local de UI SOLAMENTE
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  String? _audioPath;
  Map<String, dynamic>? _replyingTo;
  OverlayEntry? _reactionOverlay;

  // Paginación (estado UI)
  bool _isLoadingMore = false;
  final List<DocumentSnapshot> _loadedMessages = [];

  // Highlight message state
  String? _highlightedMessageId;
  bool _hasScrolledToMessage = false;

  @override
  void initState() {
    super.initState();

    // Agregar observer para lifecycle events (permisos, etc)
    WidgetsBinding.instance.addObserver(this);

    // 🔒 CRITICAL FIX: Inicialización async para evitar race condition
    _initializeGroupChat();
  }

  /// Inicializar grupo de forma asíncrona para evitar race condition con notificaciones
  Future<void> _initializeGroupChat() async {
    try {
      // 🔒 PASO 1: Establecer chat actual antes de inicializar controller
      await NotificationService().setCurrentChat(widget.groupId);
      print('📊📊📊 [GroupChatScreen] ANTES de enterChat para ${widget.groupId}');
      await LocalUnreadCountService().enterChat(widget.groupId); // ✅ FIX: Marcar que estamos en el grupo
      print('📊📊📊 [GroupChatScreen] DESPUÉS de enterChat para ${widget.groupId}');

      // 🗑️ PASO 2: Limpiar notificaciones de este grupo al abrirlo
      NotificationService().clearGroupNotifications(widget.groupId);

      // 🔒 PASO 3: Inicializar controller (la verificación de auth está en el controller)
      _controller = GroupChatController(
        groupId: widget.groupId,
        groupName: widget.groupName,
      );
      await _controller.initialize();
      _scrollController.addListener(_onScroll);
      _messageController.addListener(_onTypingChanged);

      // Marcar mensajes como entregados y leídos al abrir el grupo
      _markMessagesAsDeliveredAndSeen();

      // Scroll a mensaje específico si se proporciona
      if (widget.scrollToMessageId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSpecificMessage(widget.scrollToMessageId!);
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error inicializando grupo: $e', tag: 'GroupChatScreen');
      // En caso de error, crear un controller básico
      _controller = GroupChatController(
        groupId: widget.groupId,
        groupName: widget.groupName,
      );
    } finally {
      // ✅ SIEMPRE marcar como inicializado para evitar spinner infinito
      if (mounted) {
        setState(() {
          _controllerInitialized = true;
        });
      }
    }
  }

  /// Scroll a un mensaje específico por su ID
  void _scrollToSpecificMessage(String messageId) {
    if (!_scrollController.hasClients || _hasScrolledToMessage) return;

    // Esperar un frame para que la lista se haya construido
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !_scrollController.hasClients) return;

      // Buscar el índice del mensaje en los documentos cargados
      final messageIndex = _loadedMessages.indexWhere((doc) => doc.id == messageId);

      if (messageIndex == -1) {
        // Mensaje no encontrado todavía
        // Mensaje no encontrado todavía
        // Intentar de nuevo después de un tiempo
        Future.delayed(const Duration(milliseconds: 1000), () {
          if (!_hasScrolledToMessage) {
            _scrollToSpecificMessage(messageId);
          }
        });
        return;
      }

      // Scrolling to message
      _hasScrolledToMessage = true;

      // Calcular posición aproximada
      // Como la lista está en reverse, el índice 0 es el más reciente (abajo)
      // Cada item tiene aproximadamente 100-150px de altura
      const itemHeight = 120.0;
      final targetPosition = messageIndex * itemHeight;

      // Animar al mensaje
      _scrollController.animateTo(
        targetPosition,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );

      // Resaltar temporalmente el mensaje
      if (mounted) {
        setState(() {
          _highlightedMessageId = messageId;
        });

        // Quitar resaltado después de 2 segundos
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _highlightedMessageId = null;
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    // 🔒 NOTA: clearCurrentChat() es async pero no necesitamos await en dispose
    // Es una operación de limpieza - fire-and-forget está bien aquí
    NotificationService().clearCurrentChat();
    LocalUnreadCountService().exitChat(); // ✅ FIX: Marcar que salimos del grupo

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
      _cancelRecording();
    }

    // ✅ FIX: Limpiar current_chat_id cuando la app va a background
    // para que las notificaciones nativas se muestren correctamente
    if (state == AppLifecycleState.paused) {
      NotificationService().clearCurrentChat();
      LocalUnreadCountService().exitChat(); // ✅ FIX: Marcar que salimos del grupo
    } else if (state == AppLifecycleState.resumed) {
      // Restaurar el chat actual cuando vuelve a foreground
      NotificationService().setCurrentChat(widget.groupId);
      LocalUnreadCountService().enterChat(widget.groupId); // ✅ FIX: Marcar que volvemos al grupo
      // Marcar mensajes como leídos
      _markMessagesAsDeliveredAndSeen();
    }
  }

  /// Marca los mensajes del grupo como entregados y leídos
  Future<void> _markMessagesAsDeliveredAndSeen() async {
    // Marcar como entregados
    await _deliveryReceiptsService.markMessagesAsDelivered(
      chatId: widget.groupId,
      isGroupChat: true,
    );

    // Marcar como leídos
    await _readReceiptsService.markMessagesAsSeen(
      chatId: widget.groupId,
      isGroupChat: true,
    );
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      setState(() => _isRecording = false);

    } catch (e) {

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

      // Si estamos esperando scroll a un mensaje específico, intentarlo de nuevo
      if (widget.scrollToMessageId != null && !_hasScrolledToMessage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSpecificMessage(widget.scrollToMessageId!);
        });
      }
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    // Capturar replyTo antes de limpiarlo
    final replyToCapture = _replyingTo;

    // Limpiar input inmediatamente (UX optimista)
    _messageController.clear();
    if (mounted) {
      setState(() => _replyingTo = null);
    }

    // Envío fire-and-forget (permite encolar mensajes)
    // El controller maneja errores internamente y muestra mensaje optimista
    _controller.sendTextMessage(
      text: text,
      replyTo: replyToCapture,
    );
  }

  Future<void> _handleSendImage(ImageSource source) async {
    Navigator.pop(context); // Cerrar bottom sheet

    final success = await _controller.sendImage(source: source);

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

    // 1. Mostrar indicador de "Seleccionando video..." ANTES de abrir picker
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Seleccionando video...'),
          duration: Duration(seconds: 30),
        ),
      );
    }

    // 2. Abrir picker (esto puede tardar varios segundos en iOS)
    final ImagePicker picker = ImagePicker();
    final XFile? video = await picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 5),
    );

    // Ocultar el mensaje de "Seleccionando..."
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }

    if (video == null) return; // Usuario canceló

    // 2. Procesar y enviar video (la compresión ocurre antes de subir)
    try {
      await _controller.sendVideoFromFile(
        videoPath: video.path,
        onShowMessage: (message) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          }
        },
        onHideMessage: () {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          }
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar video: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    try {
      // PRIMERO verificar/solicitar permisos, LUEGO vibrar y grabar
      final hasPermission = await _audioRecorder.hasPermission();

      if (!hasPermission) {

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
        // 1. Procesar waveform inmediatamente
        final AudioProcessingService audioProcessing = AudioProcessingService();
        final File audioFile = File(path);
        final waveformData = await audioProcessing.extractWaveform(audioFile);

        // 2. Enviar via Cloud Function (seguro con TTL automático)
        final success = await _controller.sendAudio(
          audioPath: path,
          waveformData: waveformData,
        );

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
      // Error al detener grabación
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

  void _showReactionPicker(BuildContext messageContext, String messageId) async {
    // Cerrar el teclado si está abierto para evitar conflictos con el overlay
    FocusScope.of(context).unfocus();

    // Esperar un momento para que el teclado se cierre completamente y las posiciones se estabilicen
    await Future.delayed(const Duration(milliseconds: 100));

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

  /// Editar mensaje bloqueado
  void _handleEditBlockedMessage(String messageId, String originalText) {
    // Poner el texto original en el campo de input del chat
    _messageController.text = originalText;

    // Eliminar el mensaje bloqueado de Firestore
    _controller.deleteMessage(messageId, null);
  }

  /// Navegar a la pantalla de información del mensaje
  void _navigateToMessageInfo(String messageId) {
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MessageInfoScreen(
          groupId: widget.groupId,
          messageId: messageId,
        ),
      ),
    );
  }

  // Build Methods (SOLO UI)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GroupChatAppBar(
        groupId: widget.groupId,
        groupName: widget.groupName,
        onTap: () {
          Navigator.of(context).push(
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
              Expanded(
                child: SafeArea(
                  child: Stack(
                    children: [
                      // Lista de mensajes ocupa todo el espacio
                      Column(
                        children: [
                          Expanded(child: _buildMessagesList()),
                        ],
                      ),
                      // Indicador flotante en la parte inferior
                      _buildTypingIndicator(),
                    ],
                  ),
                ),
              ),
              if (_replyingTo != null) _buildReplyBar(),
              _buildInputBar(),
              if (_showEmojiPicker) _buildEmojiPicker(),
            ],
          ),
          // Indicador de grabación (overlay)
          // Usar IgnorePointer para permitir toques en el botón de detener
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
    final colorScheme = Theme.of(context).colorScheme;

    // ✅ CRITICAL FIX: Evitar usar _controller antes de que esté inicializado
    if (!_controllerInitialized) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // ✅ OPTIMISTIC: Usar ListenableBuilder para UI reactiva
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, child) {
        final allMessages = _controller.messages;

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
              // ✅ OPTIMISTIC: Ahora usamos ChatMessage directamente
              final message = allMessages[index];
              final senderId = message.senderId;
              final isMe = senderId == _controller.currentUserId;
              final timestamp = message.timestamp;
              final timeString = timestamp != null
                  ? '${timestamp.toDate().hour}:${timestamp.toDate().minute.toString().padLeft(2, '0')}'
                  : '';

              // Verificar si necesitamos mostrar separador de fecha
              final bool showDateSeparator = _shouldShowDateSeparatorFromMessages(index, allMessages);

              // ✅ Usar estado de moderación del ChatMessage
              final moderationStatus = message.moderationStatus;

              // ✅ Usar datos cacheados del controller (sin streams anidados)
              final realName = _controller.getUserName(senderId);
              final photoURL = _controller.getUserPhoto(senderId);
              final displayName = realName; // Por ahora sin alias para evitar más streams
              final isHighlighted = _highlightedMessageId == message.id;

              // ✅ OPTIMISTIC: Usar estado del mensaje directamente
              final messageStatus = message.status ?? MessageStatus.sent;

              Widget messageBubble = MessageBubble(
                key: ValueKey('msg_${message.id}'),
                messageId: message.id,
                chatId: widget.groupId,
                text: message.text,
                imageUrl: message.imageUrl,
                videoUrl: message.videoUrl,
                audioUrl: message.audioUrl,
                localPath: message.localPath,
                type: message.type, // ✅ FIX: Pasar type para detectar imagen/video/audio optimistas
                waveformData: message.waveformData,
                status: messageStatus,
                replyTo: message.replyTo,
                reactions: message.reactions,
                isMe: isMe,
                time: timeString,
                senderId: senderId,
                senderName: displayName,
                timestamp: timestamp,
                moderationStatus: moderationStatus,
                moderationReason: message.moderationReason,
                moderationSeverity: message.moderationSeverity,
                originalText: message.originalText,
                isGroupChat: true,
                senderPhotoURL: photoURL,
                isForwarded: message.isForwarded ?? false,
                originalContactName: message.originalContactName,
                contactName: widget.groupName,
                onReply: () {
                  setState(() {
                    _replyingTo = {
                      'id': message.id,
                      'text': message.text ?? '',
                      'senderId': senderId,
                      'senderName': displayName,
                      if (message.imageUrl != null) 'imageUrl': message.imageUrl,
                      if (message.videoUrl != null) 'videoUrl': message.videoUrl,
                      if (message.audioUrl != null) 'audioUrl': message.audioUrl,
                    };
                  });
                },
                onReplyTap: (String messageId) {
                  _scrollToSpecificMessage(messageId);
                },
                onLongPress: _showReactionPicker,
                onDelete: _handleDeleteMessage,
                onEdit: _handleEditBlockedMessage,
                onViewMessageInfo: isMe
                    ? () => _navigateToMessageInfo(message.id)
                    : null,
                isFavorite: _controller.favoriteIds.contains(message.id),  // ✅ NEW
                onFavoriteToggled: () => _controller.refreshFavorites(),  // ✅ NEW
              );

              // Wrap con highlight si es necesario
              if (isHighlighted) {
                messageBubble = Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: messageBubble,
                );
              }

              // Agregar separador de fecha si es necesario
              if (showDateSeparator && timestamp != null) {
                return Column(
                  children: [
                    _buildDateSeparator(timestamp.toDate()),
                    SizedBox(height: 16),
                    messageBubble,
                  ],
                );
              }

              return messageBubble;
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
    // ✅ FIX: Evitar usar _controller antes de que esté inicializado
    if (!_controllerInitialized) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<List<String>>(
      stream: _controller.watchTypingUsers(),
      builder: (context, snapshot) {
        // Si hay error de permisos, simplemente no mostrar nada
        if (snapshot.hasError) {
          return const SizedBox.shrink();
        }

        final typingUserIds = snapshot.data ?? [];

        // Indicador flotante - solo se muestra cuando alguien está escribiendo
        if (typingUserIds.isEmpty) return const SizedBox.shrink();

        // Obtener nombres de los usuarios escribiendo
        final typingUserNames = typingUserIds
            .map((userId) => _controller.getUserName(userId))
            .toList();

        return Positioned(
          bottom: 8, // Separación del borde inferior
          left: 8,
          child: AnimatedOpacity(
            opacity: typingUserIds.isNotEmpty ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: GroupTypingIndicator(typingUserNames: typingUserNames),
            ),
          ),
        );
      },
    );
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

  /// Determina si se debe mostrar un separador de fecha antes de este mensaje
  bool _shouldShowDateSeparator(int index, List<DocumentSnapshot> messages) {
    // Si es el último mensaje de la lista (el más antiguo), siempre mostrar fecha
    if (index == messages.length - 1) {
      return true;
    }

    final currentMessageData = messages[index].data() as Map<String, dynamic>;
    final nextMessageData = messages[index + 1].data() as Map<String, dynamic>;

    final currentTimestamp = currentMessageData['timestamp'] as Timestamp?;
    final nextTimestamp = nextMessageData['timestamp'] as Timestamp?;

    if (currentTimestamp == null || nextTimestamp == null) {
      return false;
    }

    final currentDate = DateTime(
      currentTimestamp.toDate().year,
      currentTimestamp.toDate().month,
      currentTimestamp.toDate().day,
    );

    final nextDate = DateTime(
      nextTimestamp.toDate().year,
      nextTimestamp.toDate().month,
      nextTimestamp.toDate().day,
    );

    // Mostrar separador si las fechas son diferentes
    return currentDate != nextDate;
  }

  /// ✅ OPTIMISTIC: Versión que trabaja con ChatMessage
  bool _shouldShowDateSeparatorFromMessages(int index, List<ChatMessage> messages) {
    // Si es el último mensaje de la lista (el más antiguo), siempre mostrar fecha
    if (index == messages.length - 1) {
      return true;
    }

    final currentMessage = messages[index];
    final nextMessage = messages[index + 1];

    final currentTimestamp = currentMessage.timestamp;
    final nextTimestamp = nextMessage.timestamp;

    if (currentTimestamp == null || nextTimestamp == null) {
      return false;
    }

    final currentDate = DateTime(
      currentTimestamp.toDate().year,
      currentTimestamp.toDate().month,
      currentTimestamp.toDate().day,
    );

    final nextDate = DateTime(
      nextTimestamp.toDate().year,
      nextTimestamp.toDate().month,
      nextTimestamp.toDate().day,
    );

    // Mostrar separador si las fechas son diferentes
    return currentDate != nextDate;
  }

  /// Construye el widget del separador de fecha
  Widget _buildDateSeparator(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    String dateText;
    if (messageDate == today) {
      dateText = 'Hoy';
    } else if (messageDate == yesterday) {
      dateText = 'Ayer';
    } else {
      // Formato: "25 Dic, 2023"
      const months = [
        '', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
        'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
      ];
      dateText = '${date.day} ${months[date.month]}, ${date.year}';
    }

    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          dateText,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
