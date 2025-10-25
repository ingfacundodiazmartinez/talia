import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../controllers/chat_controller_optimistic.dart';
import '../notification_service.dart';
import '../services/foreground_message_listener.dart';
import '../services/reaction_service.dart';
import '../services/video_call_service.dart';
import '../services/block_service.dart';
import '../widgets/reaction_picker.dart';
import 'chat/widgets/chat_app_bar.dart';
import 'chat/widgets/message_bubble.dart';
import 'chat/widgets/chat_input_bar.dart';
import 'chat/widgets/reply_bar.dart';
import 'chat/widgets/typing_indicator.dart';
import 'chat/widgets/attachment_options.dart';
import 'chat/widgets/recording_indicator.dart';
import 'contact_profile_screen.dart';
import 'video_call_screen.dart';
import 'forward_messages_screen.dart';
import 'message_info_screen.dart';

/// Pantalla de chat individual (1 a 1)
///
/// Responsabilidades (SOLO UI):
/// - Renderizar interfaz del chat
/// - Manejar estado local de UI (emoji picker, grabación, reply)
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
    with WidgetsBindingObserver {
  // Controller (maneja toda la lógica de negocio) - OPTIMISTIC
  late ChatControllerOptimistic _controller;

  // Controllers de UI
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final ReactionService _reactionService = ReactionService();
  final VideoCallService _videoCallService = VideoCallService();
  final BlockService _blockService = BlockService();

  // Estado local de UI SOLAMENTE
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  bool _isBlocked = false;
  bool _isBlockedBy = false;
  Map<String, dynamic>? _replyingTo;
  OverlayEntry? _reactionOverlay;

  // Selection mode for forwarding multiple messages
  bool _isSelectionMode = false;
  final Set<String> _selectedMessageIds = {};

  // Highlight message state
  String? _highlightedMessageId;
  bool _hasScrolledToMessage = false;

  // Editing blocked message state
  String? _editingBlockedMessageId;

  @override
  void initState() {
    super.initState();
    print('🏗️ [ChatDetailScreen] initState para chatId: ${widget.chatId}');

    // Agregar observer para lifecycle events (permisos, etc)
    WidgetsBinding.instance.addObserver(this);

    // Establecer el chat actual para suprimir notificaciones de este chat
    NotificationService().setCurrentChat(widget.chatId);

    // Establecer el chat actual en ForegroundMessageListener para suprimir custom notifications
    ForegroundMessageListener().setCurrentOpenChat(widget.chatId);

    _controller = ChatControllerOptimistic(
      chatId: widget.chatId,
      contactId: widget.contactId,
      contactName: widget.contactName,
    );
    _controller.initialize();

    // Escuchar cambios del controller para rebuilds
    _controller.addListener(_onControllerChanged);
    _messageController.addListener(_onTypingChanged);

    // ✅ Escuchar scroll para cargar más mensajes (paginación)
    _scrollController.addListener(_onScroll);

    // Escuchar cambios en el estado de bloqueo
    _blockService.isBlockedStream(widget.contactId).listen((isBlocked) {
      if (mounted) {
        setState(() {
          _isBlocked = isBlocked;
        });
      }
    });

    _blockService.isBlockedByStream(widget.contactId).listen((isBlockedBy) {
      if (mounted) {
        setState(() {
          _isBlockedBy = isBlockedBy;
        });
      }
    });

    // Marcar chat como leído al abrirlo
    _markChatAsRead();

    // Scroll inicial al cargar mensajes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.scrollToMessageId != null) {
        _scrollToSpecificMessage(widget.scrollToMessageId!);
      } else {
        _scrollToBottom(animate: false);
      }
    });
  }

  /// Marcar el chat como leído (resetear contador de mensajes sin leer)
  Future<void> _markChatAsRead() async {
    try {
      final functions = FirebaseFunctions.instance;
      await functions.httpsCallable('markChatAsRead').call({
        'chatId': widget.chatId,
      });
      print('✅ Chat marcado como leído: ${widget.chatId}');
    } catch (e) {
      print('⚠️ Error marcando chat como leído: $e');
      // No mostrar error al usuario, es una operación secundaria
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;

    // Solo hacer scroll si estamos cerca del final (no interrumpir lectura)
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

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});

      // Auto-scroll al recibir nuevos mensajes (solo si no estamos esperando scroll a mensaje específico)
      if (widget.scrollToMessageId == null || _hasScrolledToMessage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      } else {
        // Intentar scroll a mensaje específico si aún no se ha hecho
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSpecificMessage(widget.scrollToMessageId!);
        });
      }
    }
  }

  /// ✅ Detectar scroll para cargar más mensajes (lazy loading)
  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    // Si el usuario scrolleó más del 80% hacia arriba, cargar más mensajes
    if (currentScroll >= maxScroll * 0.8) {
      _controller.loadMoreMessages();
    }
  }

  /// Scroll a un mensaje específico por su ID
  void _scrollToSpecificMessage(String messageId) {
    if (!_scrollController.hasClients || _hasScrolledToMessage) return;

    // Buscar el índice del mensaje
    final messageIndex = _controller.messages.indexWhere(
      (msg) => msg.id == messageId,
    );

    if (messageIndex == -1) {
      // Mensaje no encontrado todavía, intentar de nuevo más tarde
      print('⏳ Mensaje $messageId no encontrado aún, esperando...');
      return;
    }

    print('✅ Scroll a mensaje $messageId en índice $messageIndex');
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

  @override
  void dispose() {
    print('🗑️ [ChatDetailScreen] dispose para chatId: ${widget.chatId}');

    // Limpiar el chat actual para permitir notificaciones de nuevo
    NotificationService().clearCurrentChat();

    // Limpiar el chat actual en ForegroundMessageListener para permitir custom notifications
    ForegroundMessageListener().setCurrentOpenChat(null);

    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.removeListener(
      _onScroll,
    ); // ✅ Remover listener de paginación
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
      print(
        '⚠️ [ChatDetailScreen] App inactive mientras grababa - cancelando grabación',
      );
      _cancelRecording();
    }
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      setState(() => _isRecording = false);
      print('✅ [ChatDetailScreen] Grabación cancelada');
    } catch (e) {
      print('❌ [ChatDetailScreen] Error cancelando grabación: $e');
      setState(() => _isRecording = false);
    }
  }

  // Event Handlers (llaman al controller, NO tienen lógica compleja)

  void _onTypingChanged() {
    _controller.setTyping(_messageController.text.isNotEmpty);
  }

  Future<void> _handleSendMessage() async {
    // Verificar bloqueo antes de enviar
    if (_isBlocked || _isBlockedBy) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isBlocked
                ? 'No puedes enviar mensajes a este contacto porque lo has bloqueado'
                : 'Este contacto te ha bloqueado',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    // Capturar replyTo antes de limpiarlo (para el envío)
    final replyToCapture = _replyingTo;

    // Verificar si estamos editando un mensaje bloqueado
    final editingMessageId = _editingBlockedMessageId;

    _messageController.clear();

    // Limpiar el reply optimísticamente (ANTES de enviar)
    if (mounted) {
      setState(() {
        _replyingTo = null;
        _editingBlockedMessageId = null; // Limpiar estado de edición
      });
    }

    try {
      if (editingMessageId != null) {
        // Actualizar mensaje bloqueado existente (re-moderar)
        print('🔄 Actualizando mensaje bloqueado: $editingMessageId');
        await _controller.updateBlockedMessage(editingMessageId, text);
      } else {
        // Envío normal de mensaje nuevo
        await _controller.sendTextMessage(text: text, replyTo: replyToCapture);
      }
    } catch (e) {
      // Mensaje bloqueado por moderación o error
      print('❌ Error enviando mensaje: $e');

      // Restaurar texto en el campo
      if (mounted) {
        _messageController.text = text;

        // Obtener rol del usuario para mensaje apropiado
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        String dialogContent = e.toString().replaceFirst('Exception: ', '');

        if (currentUserId != null) {
          FirebaseFirestore.instance
              .collection('users')
              .doc(currentUserId)
              .get()
              .then((userDoc) {
                final userData = userDoc.data();
                final isParent = userData?['isParent'] ?? true;

                print('🔍 DEBUG - Usuario: $currentUserId');
                print('🔍 DEBUG - isParent: $isParent');
                print('🔍 DEBUG - userData: $userData');
                print('🔍 DEBUG - dialogContent: $dialogContent');

                // Texto personalizado según el rol
                String title;
                String explanation;

                if (isParent) {
                  // Para padres: mensaje neutral
                  title = 'Mensaje bloqueado';
                  explanation =
                      'Este mensaje contiene contenido inapropiado detectado por la moderación con IA:\n\n$dialogContent';
                  print('✅ Usando mensaje para PADRES');
                } else {
                  // Para niños: mencionar a los padres
                  title = 'Mensaje no permitido';
                  explanation =
                      'Tus padres han activado la moderación con IA en este chat.\n\nMotivo del bloqueo: $dialogContent';
                  print('✅ Usando mensaje para HIJOS');
                }

                if (mounted) {
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
                      content: Text(
                        explanation,
                        style: const TextStyle(fontSize: 15),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Entendido'),
                        ),
                      ],
                    ),
                  );
                }
              })
              .catchError((error) {
                // Si hay error obteniendo el rol, mostrar mensaje genérico
                if (mounted) {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Row(
                        children: [
                          Icon(Icons.block, color: Colors.red),
                          SizedBox(width: 12),
                          Text('Mensaje bloqueado'),
                        ],
                      ),
                      content: Text(
                        dialogContent,
                        style: const TextStyle(fontSize: 15),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Entendido'),
                        ),
                      ],
                    ),
                  );
                }
              });
        }
      }
    }
  }

  Future<void> _handleSendImage(ImageSource source) async {
    Navigator.pop(context); // Cerrar bottom sheet

    // Verificar bloqueo
    if (_isBlocked || _isBlockedBy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isBlocked
                  ? 'No puedes enviar mensajes a este contacto porque lo has bloqueado'
                  : 'Este contacto te ha bloqueado',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Envío optimista de imagen
    await _controller.sendImage(source: source);
  }

  Future<void> _handleSendVideo() async {
    Navigator.pop(context); // Cerrar bottom sheet

    // Verificar bloqueo
    if (_isBlocked || _isBlockedBy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isBlocked
                  ? 'No puedes enviar mensajes a este contacto porque lo has bloqueado'
                  : 'Este contacto te ha bloqueado',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Envío optimista de video
    await _controller.sendVideo();
  }

  Future<void> _startRecording() async {
    try {
      // Verificar primero si ya tenemos permisos
      final hasPermission = await _audioRecorder.hasPermission();

      if (!hasPermission) {
        print(
          '⚠️ [ChatDetailScreen] Permisos de micrófono denegados o pendientes',
        );
        return;
      }

      // Solo después de confirmar permisos: vibrar e iniciar
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

      if (mounted) {
        setState(() {
          _isRecording = true;
        });
      }

      print('✅ [ChatDetailScreen] Grabación iniciada');
    } catch (e) {
      print('❌ Error iniciando grabación: $e');

      // Asegurarse de que el estado se resetee en caso de error
      if (mounted) {
        setState(() {
          _isRecording = false;
        });

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
        // Envío optimista de audio
        await _controller.sendAudio(path);
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

  void _showReactionPicker(
    BuildContext messageContext,
    String messageId,
  ) async {
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

    Overlay.of(context).insert(_reactionOverlay!);

    Future.delayed(const Duration(seconds: 5), () {
      _reactionOverlay?.remove();
      _reactionOverlay = null;
    });
  }

  Future<void> _handleDeleteMessage(
    String messageId,
    Timestamp? timestamp,
  ) async {
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
  Future<void> _handleEditBlockedMessage(
    String messageId,
    String originalText,
  ) async {
    // Poner el texto original en el campo de input del chat
    setState(() {
      _messageController.text = originalText;
      _editingBlockedMessageId = messageId; // Guardar ID para actualizar en lugar de crear nuevo
    });

    // Enfocar el campo de texto
    FocusScope.of(context).requestFocus(FocusNode());
  }

  Future<void> _handleClearChat() async {
    final success = await _controller.clearChat();

    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo limpiar el chat'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Reenviar mensajes seleccionados
  Future<void> _forwardSelectedMessages(BuildContext context) async {
    if (_selectedMessageIds.isEmpty) return;

    // Obtener los mensajes seleccionados
    final selectedMessages = _controller.messages
        .where((msg) => _selectedMessageIds.contains(msg.id))
        .toList();

    // Salir del modo de selección
    setState(() {
      _isSelectionMode = false;
      _selectedMessageIds.clear();
    });

    // Navegar a pantalla de reenvío con los mensajes seleccionados
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

  /// Devolver llamada (con lógica optimista)
  Future<void> _handleCallBack(String callType) async {
    try {
      print('📞 Devolviendo llamada ($callType) a ${widget.contactName}');

      // LÓGICA OPTIMISTA: Abrir pantalla inmediatamente sin esperar
      if (mounted) {
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (context) => VideoCallScreen(
              callId: DateTime.now().millisecondsSinceEpoch.toString(), // ID temporal
              receiverId: widget.contactId,
              remoteName: widget.contactName,
              isCaller: true,
              isVideo: callType == 'video',
              // No pasar channelName, token, uid - se obtienen en background
            ),
          ),
        );
      }
    } catch (e) {
      print('❌ Error devolviendo llamada: $e');
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

  // Build Methods (SOLO UI)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isSelectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedMessageIds.clear();
                  });
                },
              ),
              title: Text('${_selectedMessageIds.length} seleccionados'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.forward),
                  onPressed: _selectedMessageIds.isEmpty
                      ? null
                      : () => _forwardSelectedMessages(context),
                ),
              ],
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
                child: SafeArea(
                  child: Stack(
                    children: [
                      // Lista de mensajes ocupa todo el espacio
                      Column(children: [Expanded(child: _buildMessagesList())]),
                      // Indicador flotante en la parte inferior
                      _buildTypingIndicator(),
                    ],
                  ),
                ),
              ),
              if (_isBlocked || _isBlockedBy) _buildBlockedBar(),
              if (_replyingTo != null) _buildReplyBar(),
              _buildInputBar(),
              if (_showEmojiPicker) _buildEmojiPicker(),
            ],
          ),
          // Indicador de grabación (overlay)
          // Usar Stack para permitir toques en el botón de detener pero mostrar overlay visual
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

    // Usar controller.messages directamente (optimistic)
    if (_controller.isLoading && _controller.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_controller.messages.isEmpty) {
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

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      physics: const ClampingScrollPhysics(),
      cacheExtent: 1000,
      addAutomaticKeepAlives: true,
      addRepaintBoundaries: true,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 16),
      itemCount: _controller.messages.length,
      findChildIndexCallback: (Key key) {
        if (key is ValueKey<String>) {
          final messageId = key.value.replaceFirst('msg_', '');
          final index = _controller.messages.indexWhere(
            (msg) => msg.id == messageId,
          );
          return index >= 0 ? index : null;
        }
        return null;
      },
      itemBuilder: (context, index) {
        final message = _controller.messages[index];
        final isMe = message.senderId == FirebaseAuth.instance.currentUser!.uid;
        final timeString =
            '${message.effectiveTimestamp.hour}:${message.effectiveTimestamp.minute.toString().padLeft(2, '0')}';
        final isSelected = _selectedMessageIds.contains(message.id);

        // Debug forwarding fields antes de crear el widget
        if (message.isForwarded) {
          print(
            '🔨 Construyendo MessageBubble(${message.id.substring(0, 8)}...): isForwarded=${message.isForwarded}, originalContactName="${message.originalContactName}"',
          );
        }

        // Verificar si necesitamos mostrar separador de fecha
        final bool showDateSeparator = _shouldShowDateSeparator(index);

        // Aplicar highlight si es el mensaje buscado
        final isHighlighted = _highlightedMessageId == message.id;

        Widget messageBubble = MessageBubble(
          key: ValueKey('msg_${message.id}'),
          messageId: message.id,
          chatId: widget.chatId,
          text: message.text,
          imageUrl: message.imageUrl,
          videoUrl: message.videoUrl,
          audioUrl: message.audioUrl,
          localPath: message.localPath,
          waveformData: message.waveformData,
          status: message.status,
          replyTo: message.replyTo,
          reactions: message.reactions,
          isMe: isMe,
          time: timeString,
          senderId: message.senderId,
          senderName: widget.contactName,
          timestamp: message.timestamp,
          allMessages: _controller.messages,
          moderationStatus: message.moderationStatus,
          moderationReason: message.moderationReason,
          moderationSeverity: message.moderationSeverity,
          originalText: message.originalText,
          type: message.type,
          callType: message.callType,
          callDuration: message.callDuration,
          onCallBack: message.callType != null
              ? () => _handleCallBack(message.callType!)
              : null,
          isForwarded: message.isForwarded,
          originalContactName: message.originalContactName,
          contactName: widget.contactName,
          onReply: () {
            setState(() {
              _replyingTo = {
                'id': message.id,
                'text': message.text ?? '',
                'senderId': message.senderId,
                'senderName': widget.contactName,
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
          onSelectMessages: () {
            setState(() {
              _isSelectionMode = true;
              _selectedMessageIds.add(message.id);
            });
          },
        );

        // Wrap con highlight si es necesario
        if (isHighlighted) {
          messageBubble = Container(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: messageBubble,
          );
        }

        // Wrap with selection mode support
        Widget finalWidget;
        if (_isSelectionMode) {
          finalWidget = GestureDetector(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selectedMessageIds.remove(message.id);
                } else {
                  _selectedMessageIds.add(message.id);
                }
              });
            },
            child: Container(
              color: isSelected
                  ? Colors.blue.withValues(alpha: 0.1)
                  : Colors.transparent,
              child: Row(
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selectedMessageIds.add(message.id);
                        } else {
                          _selectedMessageIds.remove(message.id);
                        }
                      });
                    },
                  ),
                  Expanded(child: messageBubble),
                ],
              ),
            ),
          );
        } else {
          finalWidget = messageBubble;
        }

        // Agregar separador de fecha si es necesario
        if (showDateSeparator) {
          return Column(
            children: [
              _buildDateSeparator(message.effectiveTimestamp),
              SizedBox(height: 16),
              finalWidget,
            ],
          );
        }

        return finalWidget;
      },
    );
  }

  Widget _buildTypingIndicator() {
    return StreamBuilder<bool>(
      stream: _controller.watchTypingIndicator(),
      builder: (context, snapshot) {
        final isTyping = snapshot.data ?? false;

        // Indicador flotante - solo se muestra cuando está escribiendo
        if (!isTyping) return const SizedBox.shrink();

        return Positioned(
          bottom: 8, // Separación del borde inferior
          left: 8,
          child: AnimatedOpacity(
            opacity: isTyping ? 1.0 : 0.0,
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
              child: TypingIndicator(userName: widget.contactName),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBlockedBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.red.withValues(alpha: 0.1),
      child: Row(
        children: [
          Icon(Icons.block, color: Colors.red, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _isBlocked
                  ? 'Has bloqueado a este contacto. No puedes enviar ni recibir mensajes.'
                  : 'Este contacto te ha bloqueado.',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
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
    // Deshabilitar input si hay bloqueo
    if (_isBlocked || _isBlockedBy) {
      return const SizedBox.shrink();
    }

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
            backgroundColor: isDarkMode
                ? colorScheme.surface
                : const Color(0xFFF2F2F2),
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
  bool _shouldShowDateSeparator(int index) {
    // Si es el último mensaje de la lista (el más antiguo), siempre mostrar fecha
    if (index == _controller.messages.length - 1) {
      return true;
    }

    final currentMessage = _controller.messages[index];
    final nextMessage = _controller.messages[index + 1]; // Mensaje más antiguo

    final currentDate = DateTime(
      currentMessage.effectiveTimestamp.year,
      currentMessage.effectiveTimestamp.month,
      currentMessage.effectiveTimestamp.day,
    );

    final nextDate = DateTime(
      nextMessage.effectiveTimestamp.year,
      nextMessage.effectiveTimestamp.month,
      nextMessage.effectiveTimestamp.day,
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
        '',
        'Ene',
        'Feb',
        'Mar',
        'Abr',
        'May',
        'Jun',
        'Jul',
        'Ago',
        'Sep',
        'Oct',
        'Nov',
        'Dic',
      ];
      dateText = '${date.day} ${months[date.month]}, ${date.year}';
    }

    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withOpacity(0.7),
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
