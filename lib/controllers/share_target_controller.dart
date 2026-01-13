import 'dart:async';
import 'dart:io';
import '../models/shared_content.dart';
import '../services/share_target_service.dart';
import '../services/chats/chat_orchestrator.dart';
import '../services/stories/story_orchestrator.dart';
import '../services/chats/services/chat_messaging_service.dart';
import '../utils/release_logger.dart';
import 'forward_messages_controller.dart';

/// Estado del controller de share target
class ShareTargetState {
  final List<SharedContent> content;
  final ShareDestination? destination;
  final String? selectedChatId;
  final bool isGroup;
  final bool isLoading;
  final bool isSending;

  ShareTargetState({
    required this.content,
    this.destination,
    this.selectedChatId,
    this.isGroup = false,
    required this.isLoading,
    required this.isSending,
  });

  ShareTargetState copyWith({
    List<SharedContent>? content,
    ShareDestination? destination,
    String? selectedChatId,
    bool? isGroup,
    bool? isLoading,
    bool? isSending,
  }) {
    return ShareTargetState(
      content: content ?? this.content,
      destination: destination ?? this.destination,
      selectedChatId: selectedChatId ?? this.selectedChatId,
      isGroup: isGroup ?? this.isGroup,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
    );
  }
}

/// Controller para el flujo de selección de share target
///
/// Responsabilidades:
/// - Coordinar entre ShareTargetService y UI
/// - Manejar selección de destino (chat vs story)
/// - Manejar selección de chat/grupo
/// - Coordinar con ChatOrchestrator y StoryOrchestrator
class ShareTargetController {
  final ShareTargetService _shareTargetService;
  final ChatOrchestrator _chatOrchestrator;
  final StoryOrchestrator _storyOrchestrator;
  final ForwardMessagesController _chatsController;

  // Estado
  List<SharedContent> _sharedContent = [];
  ShareDestination? _selectedDestination;
  String? _selectedChatId;
  bool _isGroup = false;
  bool _isLoading = false;
  bool _isSending = false;

  // Stream controller para notificar cambios de estado
  final _stateController = StreamController<ShareTargetState>.broadcast();
  Stream<ShareTargetState> get stateStream => _stateController.stream;

  // Callbacks
  void Function(String message)? onSuccess;
  void Function(String message)? onError;
  void Function()? onComplete;

  ShareTargetController({
    ShareTargetService? shareTargetService,
    ChatOrchestrator? chatOrchestrator,
    StoryOrchestrator? storyOrchestrator,
    ForwardMessagesController? chatsController,
  })  : _shareTargetService = shareTargetService ?? ShareTargetService(),
        _chatOrchestrator = chatOrchestrator ?? ChatOrchestrator(),
        _storyOrchestrator = storyOrchestrator ?? StoryOrchestrator(),
        _chatsController = chatsController ?? ForwardMessagesController();

  // ═══════════════════════════════════════════════════════════════
  // GETTERS
  // ═══════════════════════════════════════════════════════════════

  List<SharedContent> get sharedContent => _sharedContent;
  ShareDestination? get selectedDestination => _selectedDestination;
  String? get selectedChatId => _selectedChatId;
  bool get isLoading => _isLoading;
  bool get isSending => _isSending;

  /// Indica si hay contenido multimedia
  bool get hasMediaContent => _sharedContent.any((c) => c.isMedia);

  /// Indica si hay contenido de texto
  bool get hasTextContent => _sharedContent.any((c) => c.isText || c.isUrl);

  /// Indica si se puede crear una historia (solo 1 imagen o video)
  bool get canCreateStory =>
      hasMediaContent && _sharedContent.length == 1 && _sharedContent.first.canBeStory;

  /// Obtener controller de chats para el listado
  ForwardMessagesController get chatsController => _chatsController;

  // ═══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar con contenido pendiente desde ShareTargetService
  Future<void> initialize() async {
    _isLoading = true;
    _emitState();

    // ✅ FIX: Forzar refresh del contenido para asegurar que tenemos lo más reciente
    await _shareTargetService.refreshPendingContent();

    final pending = _shareTargetService.pendingContent;
    if (pending != null && pending.isNotEmpty) {
      _sharedContent = pending;
      ReleaseLogger.log(
        '📤 [ShareController] Initialized with ${pending.length} items',
        tag: 'ShareController',
      );
    } else {
      ReleaseLogger.log(
        '📤 [ShareController] No pending content found after refresh',
        tag: 'ShareController',
      );
    }

    // Cargar lista de chats
    await _chatsController.initialize(originalChatId: '');

    _isLoading = false;
    _emitState();
  }

  /// Inicializar con contenido específico (para testing o uso directo)
  void initializeWithContent(List<SharedContent> content) {
    _sharedContent = content;
    _emitState();
  }

  // ═══════════════════════════════════════════════════════════════
  // DESTINATION SELECTION
  // ═══════════════════════════════════════════════════════════════

  /// Seleccionar destino (chat o story)
  void selectDestination(ShareDestination destination) {
    _selectedDestination = destination;
    _selectedChatId = null;
    _isGroup = false;
    _emitState();
    ReleaseLogger.log(
      '📤 [ShareController] Selected destination: $destination',
      tag: 'ShareController',
    );
  }

  /// Seleccionar chat para enviar
  void selectChat(String chatId, {bool isGroup = false}) {
    _selectedChatId = chatId;
    _isGroup = isGroup;
    _emitState();
    ReleaseLogger.log(
      '📤 [ShareController] Selected ${isGroup ? "group" : "chat"}: $chatId',
      tag: 'ShareController',
    );
  }

  /// Limpiar selección de chat
  void clearChatSelection() {
    _selectedChatId = null;
    _isGroup = false;
    _emitState();
  }

  // ═══════════════════════════════════════════════════════════════
  // CONTENT SENDING
  // ═══════════════════════════════════════════════════════════════

  /// Enviar contenido compartido al chat seleccionado
  /// ✅ OPTIMISTIC: Muestra feedback inmediato y cierra pantalla mientras envía en background
  Future<void> sendToChat() async {
    // ✅ FIX: Validación temprana con feedback inmediato
    if (_selectedChatId == null) {
      ReleaseLogger.error(
        '📤 [ShareController] No chat selected',
        tag: 'ShareController',
      );
      onError?.call('Selecciona un chat primero');
      return;
    }

    if (_sharedContent.isEmpty) {
      ReleaseLogger.error(
        '📤 [ShareController] No content to share',
        tag: 'ShareController',
      );
      onError?.call('No hay contenido para compartir');
      return;
    }

    // ✅ FIX: Capturar chatId y content al inicio para evitar race conditions
    final chatIdToSend = _selectedChatId!;
    final contentToSend = List<SharedContent>.from(_sharedContent);
    final isGroupToSend = _isGroup;

    ReleaseLogger.log(
      '📤 [ShareController] sendToChat START: chatId=$chatIdToSend, items=${contentToSend.length}, isGroup=$isGroupToSend',
      tag: 'ShareController',
    );

    // ✅ OPTIMISTIC: Mostrar "Enviando..." inmediatamente
    _isSending = true;
    _emitState();

    // ✅ OPTIMISTIC: Limpiar contenido y notificar éxito ANTES de enviar
    // El usuario verá feedback inmediato mientras el envío ocurre en background
    _shareTargetService.clearPendingContent();
    _callSuccessSafe('Enviando...');
    _callCompleteSafe(); // Cierra la pantalla inmediatamente

    // ✅ OPTIMISTIC: Enviar en background sin bloquear
    _sendContentInBackground(
      contentToSend: contentToSend,
      chatId: chatIdToSend,
      isGroup: isGroupToSend,
    );
  }

  /// ✅ NEW: Enviar contenido en background
  Future<void> _sendContentInBackground({
    required List<SharedContent> contentToSend,
    required String chatId,
    required bool isGroup,
  }) async {
    bool hasError = false;
    String? errorMessage;
    int successCount = 0;

    try {
      for (int i = 0; i < contentToSend.length; i++) {
        final content = contentToSend[i];
        ReleaseLogger.log(
          '📤 [ShareController] Sending item ${i + 1}/${contentToSend.length}: type=${content.type}',
          tag: 'ShareController',
        );

        try {
          await _sendSingleContentSafe(
            content: content,
            chatId: chatId,
            isGroup: isGroup,
          );
          successCount++;
          ReleaseLogger.log(
            '📤 [ShareController] Item ${i + 1} sent successfully',
            tag: 'ShareController',
          );
        } catch (itemError) {
          ReleaseLogger.error(
            '📤 [ShareController] Error sending item ${i + 1}: $itemError',
            tag: 'ShareController',
          );
          hasError = true;
          errorMessage = itemError.toString().replaceAll('Exception: ', '');
          // Continue with next item instead of stopping
        }
      }

      ReleaseLogger.log(
        '📤 [ShareController] sendToChat COMPLETE: success=$successCount/${contentToSend.length}, hasError=$hasError',
        tag: 'ShareController',
      );

      // ✅ Mostrar resultado final solo si hubo error
      if (hasError && successCount == 0) {
        _callErrorSafe('Error: ${errorMessage ?? "No se pudo enviar"}');
      } else if (hasError) {
        // Algunos fallaron - ya se mostró "Enviando..." así que no hacer nada
        ReleaseLogger.log(
          '📤 [ShareController] Partial success: $successCount/${contentToSend.length}',
          tag: 'ShareController',
        );
      }
      // Si todo fue exitoso, no mostrar nada más (ya se mostró "Enviando...")
    } catch (e, stackTrace) {
      ReleaseLogger.error(
        '📤 [ShareController] UNEXPECTED error in background send: $e\n$stackTrace',
        tag: 'ShareController',
      );
      _callErrorSafe('Error inesperado: ${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      _isSending = false;
      _emitState();
    }
  }

  /// ✅ NEW: Llamar onSuccess de manera segura
  void _callSuccessSafe(String message) {
    try {
      ReleaseLogger.log(
        '📤 [ShareController] Calling onSuccess: $message',
        tag: 'ShareController',
      );
      onSuccess?.call(message);
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareController] Error calling onSuccess: $e',
        tag: 'ShareController',
      );
    }
  }

  /// ✅ NEW: Llamar onError de manera segura
  void _callErrorSafe(String message) {
    try {
      ReleaseLogger.log(
        '📤 [ShareController] Calling onError: $message',
        tag: 'ShareController',
      );
      onError?.call(message);
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareController] Error calling onError: $e',
        tag: 'ShareController',
      );
    }
  }

  /// ✅ NEW: Llamar onComplete de manera segura
  void _callCompleteSafe() {
    try {
      ReleaseLogger.log(
        '📤 [ShareController] Calling onComplete',
        tag: 'ShareController',
      );
      onComplete?.call();
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareController] Error calling onComplete: $e',
        tag: 'ShareController',
      );
    }
  }

  /// ✅ NEW: Enviar un item de manera segura con todos los parámetros explícitos
  Future<void> _sendSingleContentSafe({
    required SharedContent content,
    required String chatId,
    required bool isGroup,
  }) async {
    ReleaseLogger.log(
      '📤 [ShareController] _sendSingleContentSafe: type=${content.type}, mediaPath=${content.mediaPath}, chatId=$chatId, isGroup=$isGroup',
      tag: 'ShareController',
    );

    if (content.isMedia && content.mediaPath != null) {
      // Verificar que el archivo source existe
      final sourceFile = File(content.mediaPath!);
      final sourceExists = await sourceFile.exists();
      if (!sourceExists) {
        ReleaseLogger.error(
          '📤 [ShareController] Source file does NOT exist: ${content.mediaPath}',
          tag: 'ShareController',
        );
        throw Exception('El archivo no existe o no es accesible');
      }

      final sourceSize = await sourceFile.length();
      ReleaseLogger.log(
        '📤 [ShareController] Source file exists, size: $sourceSize bytes',
        tag: 'ShareController',
      );

      // Copiar archivo a ubicación accesible
      final copiedPath =
          await _shareTargetService.copyToTempDirectory(content.mediaPath!);
      if (copiedPath == null) {
        throw Exception('No se pudo copiar el archivo');
      }

      // Verificar archivo destino
      final destFile = File(copiedPath);
      final destExists = await destFile.exists();
      final destSize = destExists ? await destFile.length() : 0;
      if (!destExists || destSize == 0) {
        throw Exception('Error al copiar archivo (destino vacío)');
      }

      ReleaseLogger.log(
        '📤 [ShareController] File copied: $copiedPath (size: $destSize bytes)',
        tag: 'ShareController',
      );

      // Determinar tipo de media
      final messageType = content.type == SharedContentType.image
          ? MessageType.image
          : MessageType.video;

      // Enviar via ChatOrchestrator
      ReleaseLogger.log(
        '📤 [ShareController] Calling chatOrchestrator.sendMessage...',
        tag: 'ShareController',
      );

      final messageId = await _chatOrchestrator.sendMessage(
        chatId: chatId,
        content: content.text ?? '',
        type: messageType,
        mediaPath: copiedPath,
        isGroup: isGroup,
      );

      if (messageId == null) {
        throw Exception('No se pudo crear el mensaje');
      }

      ReleaseLogger.log(
        '📤 [ShareController] Media sent successfully, messageId=$messageId',
        tag: 'ShareController',
      );
    } else if (content.isText && content.text != null) {
      final messageId = await _chatOrchestrator.sendMessage(
        chatId: chatId,
        content: content.text!,
        type: MessageType.text,
        isGroup: isGroup,
      );
      ReleaseLogger.log(
        '📤 [ShareController] Text sent, messageId=$messageId',
        tag: 'ShareController',
      );
    } else if (content.isUrl && content.url != null) {
      final messageId = await _chatOrchestrator.sendMessage(
        chatId: chatId,
        content: content.url!,
        type: MessageType.text,
        isGroup: isGroup,
      );
      ReleaseLogger.log(
        '📤 [ShareController] URL sent, messageId=$messageId',
        tag: 'ShareController',
      );
    } else {
      ReleaseLogger.error(
        '📤 [ShareController] Unknown content type or missing data: ${content.type}',
        tag: 'ShareController',
      );
      throw Exception('Tipo de contenido no soportado');
    }
  }

  /// Crear historia desde contenido compartido
  Future<void> createStory() async {
    if (!canCreateStory) {
      onError?.call('Solo puedes crear una historia con una imagen o video');
      return;
    }

    final mediaContent = _sharedContent.first;
    if (mediaContent.mediaPath == null) {
      onError?.call('No hay contenido multimedia');
      return;
    }

    _isSending = true;
    _emitState();

    try {
      // Copiar archivo a ubicación accesible
      final copiedPath =
          await _shareTargetService.copyToTempDirectory(mediaContent.mediaPath!);
      if (copiedPath == null) {
        throw Exception('No se pudo procesar el archivo');
      }

      final mediaType =
          mediaContent.type == SharedContentType.image ? 'image' : 'video';

      // Crear historia via StoryOrchestrator
      await _storyOrchestrator.createStory(
        mediaType: mediaType,
        mediaPath: copiedPath,
        text: mediaContent.text,
      );

      _shareTargetService.clearPendingContent();
      onSuccess?.call('Historia creada exitosamente');
      onComplete?.call();
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareController] Error creating story: $e',
        tag: 'ShareController',
      );
      onError?.call('Error al crear historia: ${e.toString()}');
    } finally {
      _isSending = false;
      _emitState();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // STATE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  void _emitState() {
    _stateController.add(ShareTargetState(
      content: _sharedContent,
      destination: _selectedDestination,
      selectedChatId: _selectedChatId,
      isGroup: _isGroup,
      isLoading: _isLoading,
      isSending: _isSending,
    ));
  }

  /// Obtener estado actual
  ShareTargetState get currentState => ShareTargetState(
        content: _sharedContent,
        destination: _selectedDestination,
        selectedChatId: _selectedChatId,
        isGroup: _isGroup,
        isLoading: _isLoading,
        isSending: _isSending,
      );

  /// Cancelar sharing y limpiar contenido pendiente
  void cancel() {
    _shareTargetService.clearPendingContent();
    _sharedContent = [];
    _selectedDestination = null;
    _selectedChatId = null;
    _isGroup = false;
    _emitState();
    ReleaseLogger.log(
      '📤 [ShareController] Cancelled and cleared',
      tag: 'ShareController',
    );
  }

  /// Liberar recursos
  void dispose() {
    _stateController.close();
    _chatsController.dispose();
    ReleaseLogger.log(
      '📤 [ShareController] Disposed',
      tag: 'ShareController',
    );
  }
}
