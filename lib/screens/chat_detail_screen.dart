import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:path_provider/path_provider.dart';
import '../controllers/chat_controller_cache_first.dart';
import '../utils/release_logger.dart';
import '../notification_service.dart';
import '../services/local_unread_count_service.dart';
import '../services/notification_tracking_service.dart';
import '../services/user_cache_service.dart';
import '../services/speech_to_text_service.dart';
import '../calls_v2/screens/agora_call_screen.dart';
import 'chat/widgets/chat_app_bar.dart';
import 'chat/widgets/chat_input_bar.dart';
import 'chat/widgets/reply_bar.dart';
import 'chat/widgets/editing_bar.dart';
import 'chat/widgets/attachment_options.dart';
import 'chat/widgets/recording_input_bar.dart';
import 'chat/widgets/blocked_message_bar.dart';
import 'chat/widgets/emoji_picker_widget.dart';
import 'chat/widgets/message_list_widget.dart';
import 'chat/widgets/chat_selection_bar_widget.dart';
import 'chat/widgets/media_handlers_mixin.dart';
import 'chat/mixins/reaction_picker_mixin.dart';
import 'contact_profile_screen.dart';
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
    with WidgetsBindingObserver, MediaHandlersMixin, ReactionPickerMixin {
  // Controller - MIGRATED TO CACHE-FIRST
  late final ChatControllerCacheFirst _controller;

  // UI Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final RecorderController _recorderController = RecorderController();
  final UserCacheService _userCacheService = UserCacheService();
  final SpeechToTextService _sttService = SpeechToTextService();
  String? _currentRecordingPath;
  String? _currentTranscription;

  // Local UI state
  bool _showEmojiPicker = false;
  bool _isRecording = false;
  Map<String, dynamic>? _replyingTo;
  bool _isSelectionMode = false;
  final Set<String> _selectedMessageIds = {};
  String? _highlightedMessageId;
  bool _hasScrolledToMessage = false;
  Map<String, dynamic>? _editingBlockedMessage;

  // Nombre reactivo del contacto (se actualiza si cambia el alias)
  String? _displayName;

  /// Getter que retorna el nombre a mostrar con fallback seguro
  String get displayName => _displayName ?? widget.contactName;

  // Controller getter required by MediaHandlersMixin
  @override
  ChatControllerCacheFirst get controller => _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Inicializar nombre del contacto (reactivo a cambios de alias)
    _displayName = _userCacheService.getDisplayName(
      widget.contactId,
      fallback: widget.contactName,
    );

    // ✅ Inicializar controller SÍNCRONAMENTE (sin spinner)
    _controller = ChatControllerCacheFirst(
      chatId: widget.chatId,
      contactId: widget.contactId,
      contactName: displayName,
      isGroup: false,
    );

    // Listeners síncronos
    _messageController.addListener(_onTypingChanged);
    _scrollController.addListener(_onScroll);

    // ✅ FIX: Escuchar cambios en el controller para scroll a mensaje específico
    _controller.addListener(_onControllerChanged);

    // ✅ Escuchar cambios de alias para actualizar el nombre
    _userCacheService.aliasChangedNotifier.addListener(_onAliasChanged);

    // ✅ Inicializar cache de usuarios y forzar rebuild cuando termine
    _userCacheService.initialize().then((_) {
      if (mounted) {
        setState(() {
          _displayName = _userCacheService.getDisplayName(
            widget.contactId,
            fallback: widget.contactName,
          );
        });
      }
    });

    // ✅ Operaciones async en background (no bloquean UI)
    _initializeInBackground();

    // Scroll inicial (solo si no hay mensaje específico a buscar)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.scrollToMessageId == null) {
        _scrollToBottom(animate: false);
      }
      // Si hay scrollToMessageId, el listener _onControllerChanged lo manejará
    });
  }

  /// ✅ FIX: Listener para detectar cuando los mensajes están disponibles
  void _onControllerChanged() {
    if (widget.scrollToMessageId != null && !_hasScrolledToMessage) {
      ReleaseLogger.log(
        '🔍 [ChatDetail] onControllerChanged: scrollToMessageId=${widget.scrollToMessageId}, '
        'messages=${_controller.messages.length}, hasScrolled=$_hasScrolledToMessage',
        tag: 'ChatDetail',
      );
      if (_controller.messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSpecificMessage(widget.scrollToMessageId!);
        });
      }
    }
  }

  void _onAliasChanged() {
    // Solo actualizar si el alias que cambió es de este contacto
    final changedUserId = _userCacheService.aliasChangedNotifier.value;
    if (changedUserId == widget.contactId && mounted) {
      setState(() {
        _displayName = _userCacheService.getDisplayName(
          widget.contactId,
          fallback: widget.contactName,
        );
      });
    }
  }

  /// Operaciones de inicialización en background (no bloquean UI)
  void _initializeInBackground() {
    // Fire-and-forget: estas operaciones no deben bloquear la UI
    NotificationService().setCurrentChat(widget.chatId);
    LocalUnreadCountService().enterChat(widget.chatId);
    NotificationService().clearChatNotifications(widget.chatId);

    // ✅ FIX: Marcar mensajes como leídos cuando el usuario ENTRA al chat
    // Esto actualiza lastOpenedAt para que el sender vea los mensajes como "seen"
    // Arquitectura: Screen → Controller → Service
    _controller.markAsSeenForReceipts();

    // ✅ Auto-dismiss: Limpiar notificaciones de este chat cuando el usuario entra
    NotificationTrackingService().dismissNotificationsForContext(
      type: NotificationContext.chat,
      contextId: widget.chatId,
    );

    // Inicializar controller (carga mensajes del cache primero, luego Firestore)
    _controller.initialize().catchError((e) {
      ReleaseLogger.error('Error inicializando chat: $e', tag: 'ChatDetailScreen');
    });
  }

  @override
  void dispose() {
    NotificationService().clearCurrentChat();
    LocalUnreadCountService().exitChat();
    WidgetsBinding.instance.removeObserver(this);
    _userCacheService.aliasChangedNotifier.removeListener(_onAliasChanged);
    _controller.removeListener(_onControllerChanged); // ✅ FIX: Remove listener
    _controller.dispose();
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _recorderController.dispose();
    disposeReactionPicker();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && _isRecording) {
      _cancelRecording();
    }

    // ✅ FIX: NO limpiar current_chat_id cuando la app va a background
    // Mantenerlo permite detectar que el chat ya está abierto cuando el usuario
    // toca una notificación, evitando duplicar la pantalla en el stack
    // Las notificaciones nativas se manejan por el sistema operativo independientemente
    if (state == AppLifecycleState.resumed) {
      // Restaurar el chat actual cuando vuelve a foreground
      NotificationService().setCurrentChat(widget.chatId);

      // ✅ FIX: Marcar mensajes como leídos cuando la app resume con el chat abierto
      // Esto cubre el escenario donde el usuario desbloquea el teléfono
      // y el chat estaba abierto - actualiza lastOpenedAt para el sender
      // Arquitectura: Screen → Controller → Service
      _controller.markAsSeenForReceipts();
    }
  }

  // Event Handlers

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
    ReleaseLogger.log(
      '🔍 [ChatDetail] _scrollToSpecificMessage called: messageId=$messageId, '
      'hasClients=${_scrollController.hasClients}, hasScrolled=$_hasScrolledToMessage',
      tag: 'ChatDetail',
    );

    if (!_scrollController.hasClients || _hasScrolledToMessage) return;

    final messageIndex = _controller.messages.indexWhere((msg) => msg.id == messageId);

    ReleaseLogger.log(
      '🔍 [ChatDetail] Message index: $messageIndex (total messages: ${_controller.messages.length})',
      tag: 'ChatDetail',
    );

    if (messageIndex == -1) {
      ReleaseLogger.log('🔍 [ChatDetail] Mensaje $messageId no encontrado aún', tag: 'ChatDetail');
      return;
    }

    ReleaseLogger.log('🔍 [ChatDetail] Scroll a mensaje $messageId en índice $messageIndex', tag: 'ChatDetail');
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
    if (_controller.isBlocked == true || _controller.isBlockedBy == true) {
      _showBlockedSnackbar();
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final replyToCapture = _replyingTo;
    final editingMessageId = _editingBlockedMessage?['id'];

    // Limpiar input inmediatamente (UX optimista)
    _messageController.clear();
    if (mounted) {
      setState(() {
        _replyingTo = null;
        _editingBlockedMessage = null;
      });
    }

    if (editingMessageId != null) {
      // Edit blocked message - esperar resultado
      try {
        await _controller.editBlockedMessage(
          messageId: editingMessageId,
          newText: text,
        );
      } catch (e) {
        _handleSendError(e, text);
      }
    } else {
      // Envío normal - fire-and-forget (permite encolar mensajes)
      // El controller maneja errores internamente y muestra mensaje optimista
      _controller.sendTextMessage(text: text, replyTo: replyToCapture);
    }
  }

  void _showBlockedSnackbar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _controller.isBlocked == true
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
      await _recorderController.stop();
      await _sttService.cancel(); // ✅ Cancelar STT también
      _currentRecordingPath = null;
      _currentTranscription = null;
      // ✅ Detener indicador de grabación
      _controller.setRecording(false);
      setState(() => _isRecording = false);
    } catch (e) {
      _sttService.cancel();
      _controller.setRecording(false);
      setState(() => _isRecording = false);
    }
  }

  Future<void> _startRecording() async {
    try {
      final hasPermission = await _recorderController.checkPermission();
      if (!hasPermission) return;

      HapticFeedback.heavyImpact();

      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _currentRecordingPath = path;
      _currentTranscription = null;

      // ✅ Iniciar STT en paralelo para transcripción local (gratis)
      // Wrapped in try-catch para no crashear si STT no está disponible
      try {
        _sttService.startListening().then((success) {
          if (success) {
            ReleaseLogger.log('🎤 STT iniciado en paralelo con grabación', tag: 'Recording');
          } else {
            ReleaseLogger.log('⚠️ STT no disponible, continuando sin transcripción', tag: 'Recording');
          }
        }).catchError((e) {
          ReleaseLogger.log('⚠️ Error iniciando STT: $e', tag: 'Recording');
        });
      } catch (e) {
        ReleaseLogger.log('⚠️ STT no soportado: $e', tag: 'Recording');
      }

      // ✅ COMPRESIÓN MEJORADA: Usar bitRate y sampleRate más bajos para archivos más pequeños
      // Valores anteriores: defaults (~128kbps, 44100Hz) → ~960KB/minuto
      // Valores nuevos: 48kbps, 22050Hz → ~360KB/minuto (60% menos)
      await _recorderController.record(
        path: path,
        bitRate: 48000,      // 48 kbps (suficiente para voz)
        sampleRate: 22050,   // 22.05 kHz (calidad teléfono)
      );

      // ✅ Indicar que estamos grabando audio
      _controller.setRecording(true);

      if (mounted) {
        setState(() {
          _isRecording = true;
        });
      }
    } catch (e) {
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
      // ✅ Detener STT y obtener transcripción (gratis, local)
      // Wrapped in try-catch para no fallar si STT tuvo problemas
      String transcription = '';
      try {
        transcription = await _sttService.stopListening();
        _currentTranscription = transcription;
        if (transcription.isNotEmpty) {
          ReleaseLogger.log('🎤 Transcripción capturada: "${transcription.length > 50 ? '${transcription.substring(0, 50)}...' : transcription}"', tag: 'Recording');
        }
      } catch (e) {
        ReleaseLogger.log('⚠️ Error obteniendo transcripción: $e', tag: 'Recording');
        _currentTranscription = null;
      }

      final path = await _recorderController.stop();
      final recordedPath = path ?? _currentRecordingPath;
      _currentRecordingPath = null;

      // ✅ Detener indicador de grabación
      _controller.setRecording(false);

      setState(() => _isRecording = false);

      if (recordedPath != null && recordedPath.isNotEmpty) {
        // 1. Crear burbuja optimista inmediatamente con waveform real
        await _controller.createOptimisticAudioBubble(recordedPath);

        // 2. Subir en background con transcripción para moderación
        _controller.processAndUploadAudio(
          recordedPath,
          transcription: _currentTranscription,
        ).catchError((e) {
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
      // ✅ También detener STT e indicador si hay error
      _sttService.cancel();
      _controller.setRecording(false);
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

  /// Wrapper que utiliza el mixin compartido para mostrar el picker de reacciones
  void _showReactionPicker(BuildContext messageContext, String messageId) {
    showReactionPicker(
      messageContext,
      messageId,
      chatId: widget.chatId,
      isGroup: false,
    );
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
          contactName: displayName,
        ),
      ),
    );
  }

  Future<void> _handleCallBack(String callType) async {
    if (!mounted) return;

    // ✅ Navegación inmediata - la llamada se crea en background
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (context) => AgoraCallScreen.create(
          participantIds: [widget.contactId],
          isVideo: callType == 'video',
          isGroup: false,
        ),
      ),
    );
  }

  // Build Methods

  @override
  Widget build(BuildContext context) {
    // Use ListenableBuilder for ChangeNotifier pattern
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, child) => Scaffold(
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
              contactName: displayName,
              contactPhotoURL: _controller.contactPhotoURL,
              chatId: widget.chatId,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => ContactProfileScreen(
                      contactId: widget.contactId,
                      contactName: displayName,
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
              if (_controller.isBlocked == true || _controller.isBlockedBy == true)
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
        ],
      ),
    ),
    );
  }

  Widget _buildMessagesList() {
    return MessageListWidget(
      controller: _controller,
      scrollController: _scrollController,
      chatId: widget.chatId,
      contactName: displayName,
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
      messageData: _replyingTo!,
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
    if (_controller.isBlocked == true || _controller.isBlockedBy == true) {
      return const SizedBox.shrink();
    }

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
