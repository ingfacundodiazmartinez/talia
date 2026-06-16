import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../models/chat_message.dart';
import '../services/chats/chat_orchestrator.dart';
import '../services/chats/repositories/user_repository.dart';
import '../services/chats/services/chat_messaging_service.dart';  // For MessageType enum
// ✅ Nuevos servicios atómicos
import '../services/chats/chat_services.dart';
import '../services/typing_indicator_service.dart';
import '../services/block_service.dart';
import '../services/audio_processing_service.dart';
import '../services/message_cache_service.dart';
import '../services/sound_service.dart';
import '../services/favorite_service.dart';  // ✅ NEW: For favorite tracking
import '../services/media_compression_service.dart';
import '../services/reaction_service.dart';  // ✅ NEW: For reactions
import '../services/read_receipts_service.dart';  // ✅ FIX: For V2 read receipts
import '../services/message_status_helper.dart';  // ✅ V2 Read Receipts
import '../notification_service.dart';
import '../utils/release_logger.dart';
import 'package:uuid/uuid.dart';

/// ✅ Mensaje en cola para envío secuencial
/// Garantiza que los mensajes se envíen en orden FIFO
class _QueuedMessage {
  final String tempId;
  final String type; // 'text', 'image', 'audio', 'video', 'file'
  final String? text;
  final Map<String, dynamic>? replyTo;
  final Completer<void> completer;

  _QueuedMessage({
    required this.tempId,
    required this.type,
    this.text,
    this.replyTo,
  }) : completer = Completer<void>();
}

/// Controller for chat functionality (CACHE-FIRST ARCHITECTURE)
///
/// This controller properly delegates all operations to services.
/// It NEVER directly accesses Firestore.
///
/// Responsibilities:
/// - Coordinate between UI and services
/// - Manage stream subscriptions
/// - Transform data for UI presentation
/// - Handle cleanup on dispose
class ChatControllerCacheFirst extends ChangeNotifier {
  final String chatId;
  final String contactId;
  final String contactName;
  final bool isGroup;

  // Services
  late final ChatOrchestrator _orchestrator;
  late final UserRepository _userRepository;
  late final TypingIndicatorService _typingService;
  late final BlockService _blockService;
  late final AudioProcessingService _audioService;
  late final NotificationService _notificationService;
  late final FavoriteService _favoriteService;  // ✅ NEW
  late final ReactionService _reactionService;  // ✅ NEW: For reactions

  // ✅ Nuevos servicios atómicos
  late final DeleteMessageService _deleteMessageService;
  late final EditMessageService _editMessageService;
  late final ClearChatService _clearChatService;
  late final MarkMessagesReadService _markReadService;

  // Stream subscription management
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  StreamSubscription<bool>? _isBlockedSubscription;
  StreamSubscription<bool>? _isBlockedBySubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription<Set<String>>? _favoritesSubscription;  // ✅ NEW
  StreamSubscription<Map<String, Map<String, List<String>>>>? _reactionsSubscription;  // ✅ NEW
  StreamSubscription<DocumentSnapshot>? _chatDocSubscription;  // ✅ V2 Read Receipts

  // State
  List<ChatMessage> _messages = [];
  final List<ChatMessage> _pendingMessages = [];

  /// IDs (localId/tempId) de mensajes cuyo envío sigue EN CURSO. El status bar
  /// muestra "error" tras 30s aunque el upload todavía esté subiendo (cold start,
  /// archivo grande); este set permite distinguir "todavía enviando" de "falló de
  /// verdad" y evitar que el retry dispare un segundo envío → burbuja duplicada.
  ///
  /// ✅ STATIC: el upload corre en el orchestrator (singleton) y sigue vivo aunque
  /// el usuario salga del chat (dispone el controller). Compartir el set entre
  /// instancias permite que, al reentrar, el controller nuevo sepa que el envío
  /// sigue en curso y NO muestre "error" prematuro. Los IDs son uuid → únicos
  /// globalmente, sin colisión entre chats.
  static final Set<String> _inFlightSends = {};

  /// IDs ya vistos en el stream — para detectar mensajes ENTRANTES nuevos y
  /// reproducir el sonido de recepción una sola vez por mensaje.
  final Set<String> _seenMessageIds = {};
  /// La primera emisión del stream es el historial (cache); solo siembra el
  /// baseline, no suena. A partir de la segunda, los entrantes frescos suenan.
  bool _receiveSoundBaselineSet = false;

  bool _isInitialized = false;
  bool _isLoading = true;  // ✅ FIX: Start as true, set to false when first messages arrive
  bool _hasLoadedInitialMessages = false;
  bool _isLoadingMore = false;

  // Contact state
  String _contactPhotoURL = '';
  bool _contactIsOnline = false;

  // Block state
  // _isBlocked = true SOLO si el usuario actual fue quien bloqueó (es el "blocker").
  // _isBlockedBy = true si el contacto bloqueó al usuario actual (uso INTERNO, NUNCA mostrar
  // en UI: el bloqueado no debe enterarse de que fue bloqueado).
  //
  // NOTA: el filtrado de mensajes ya no se hace por timestamp aquí; lo hace el
  // stream manager por `visibleTo`. Estos flags quedan solo para UI gating
  // (barra de bloqueo, deshabilitar input, ocultar foto).
  bool _isBlocked = false;
  bool _isBlockedBy = false;

  // ✅ NEW: Favorite tracking
  Set<String> _favoriteIds = {};

  // ✅ V2 Read Receipts: lastOpenedAt del destinatario para calcular status
  DateTime? _recipientLastOpenedAt;
  DateTime? _recipientLastReceivedAt;

  // ✅ MESSAGE QUEUE: Garantiza que los mensajes se envíen en orden FIFO
  final List<_QueuedMessage> _messageQueue = [];
  bool _isProcessingQueue = false;
  static const _messageTimeout = Duration(seconds: 30);

  // Current user
  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  // Public getters
  List<ChatMessage> get messages => [..._messages];
  List<ChatMessage> get pendingMessages => [..._pendingMessages];

  /// true si el envío de este mensaje sigue EN CURSO (upload activo). El UI lo
  /// usa para NO mostrar "error" mientras el mensaje todavía se está subiendo
  /// (el timeout visual de 30s no significa que falló).
  bool isSendInFlight(String messageId) => _inFlightSends.contains(messageId);
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  bool get hasLoadedInitialMessages => _hasLoadedInitialMessages;
  bool get isLoadingMore => _isLoadingMore;
  String get contactPhotoURL => _contactPhotoURL;
  bool get contactIsOnline => _contactIsOnline;
  bool get isBlocked => _isBlocked;
  bool get isBlockedBy => _isBlockedBy;
  bool get hasMoreMessages => _messages.length >= 20; // Simple heuristic
  Set<String> get favoriteIds => _favoriteIds;  // ✅ NEW

  ChatControllerCacheFirst({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    this.isGroup = false,
    ChatOrchestrator? orchestrator,
    UserRepository? userRepository,
    TypingIndicatorService? typingService,
    BlockService? blockService,
    AudioProcessingService? audioService,
    NotificationService? notificationService,
  }) {
    // Initialize services (dependency injection pattern)
    _orchestrator = orchestrator ?? ChatOrchestrator();
    _userRepository = userRepository ?? UserRepository(
      firestore: FirebaseFirestore.instance,
      auth: FirebaseAuth.instance,
    );
    _typingService = typingService ?? TypingIndicatorService();
    _blockService = blockService ?? BlockService();
    _audioService = audioService ?? AudioProcessingService();
    _notificationService = notificationService ?? NotificationService();
    _favoriteService = FavoriteService();  // ✅ NEW
    _reactionService = ReactionService();  // ✅ NEW: For reactions

    // ✅ Inicializar nuevos servicios atómicos
    _deleteMessageService = DeleteMessageService();
    _editMessageService = EditMessageService();
    _clearChatService = ClearChatService();
    _markReadService = MarkMessagesReadService();
  }

  /// Initialize the controller and start listening to messages
  Future<void> initialize() async {
    if (_isInitialized) {
      ReleaseLogger.log('ChatController already initialized for chat $chatId');
      return;
    }

    // ✅ Reset loading state for fresh initialization
    _isLoading = true;

    // ✅ Verificar autenticación antes de hacer queries
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      ReleaseLogger.error('No hay usuario autenticado - abortando inicialización', tag: 'ChatController');
      _isInitialized = true; // Marcar para evitar spinner infinito
      _isLoading = false; // ✅ FIX: Stop loading on auth error
      return;
    }

    ReleaseLogger.log('Initializing ChatController for chat $chatId');

    try {
      await _loadContactInfo();
    } catch (e) {
      ReleaseLogger.error('Error en _loadContactInfo: $e', tag: 'ChatController');
    }

    try {
      await _startListeningToMessages();
    } catch (e) {
      ReleaseLogger.error('Error en _startListeningToMessages: $e', tag: 'ChatController');
      _isLoading = false; // ✅ FIX: Stop loading on error
    }

    _setupBlockListeners();
    _setupNotificationListener();

    try {
      await _loadFavorites();
    } catch (e) {
      ReleaseLogger.error('Error en _loadFavorites: $e', tag: 'ChatController');
    }

    // ✅ NEW: Start listening to reactions from subcollection
    _startListeningToReactions();

    // ✅ V2 Read Receipts: Listen to chat document for lastOpenedAt changes
    if (!isGroup) {
      _startListeningToChatDoc();
    }

    _isInitialized = true;
    _hasLoadedInitialMessages = true;

    // ✅ V2: Delay para que se ejecute DESPUÉS de que los mensajes
    // se rendericen en el UI. Esto evita que el mensaje aparezca como "leído"
    // antes de que la burbuja sea visible en pantalla.
    Future.delayed(const Duration(milliseconds: 1500), () async {
      try {
        // ✅ V2 ONLY: Actualiza lastOpenedAt en chat/group doc - O(1) operación
        // Usado por calculateStatusV2/calculateGroupStatusWithTimestamps para ticks azules
        // ELIMINADO V1 (markChatAsRead/readBy[]) por ser O(n) y causar inconsistencias
        await markAsSeenForReceipts();
      } catch (e) {
        if (e.toString().contains('permission-denied')) {
          ReleaseLogger.warning('Sin permisos para marcar chat como leído (¿usuario no es participante?)', tag: 'ChatController');
        } else {
          ReleaseLogger.error('Error en markAsSeenForReceipts: $e', tag: 'ChatController');
        }
      }
    });

    // ✅ FIX: Safety timeout - if stream hasn't emitted after 5 seconds, stop loading
    // This prevents infinite spinner if cache is empty and Firestore fails
    Future.delayed(const Duration(seconds: 5), () {
      if (_isLoading && _messages.isEmpty) {
        ReleaseLogger.warning('⏱️ Loading timeout - stopping spinner for chat $chatId', tag: 'ChatController');
        _isLoading = false;
        notifyListeners();
      }
    });

    ReleaseLogger.log('ChatController initialized for chat $chatId');
  }

  /// Load contact information
  /// ✅ REFACTORED: Now uses UserRepository instead of direct Firestore access
  Future<void> _loadContactInfo() async {
    try {
      final userData = await _userRepository.getUserData(contactId);
      if (userData != null) {
        _contactPhotoURL = userData['photoURL'] ?? '';
        _contactIsOnline = userData['isOnline'] ?? false;
        notifyListeners();
      }
    } catch (e) {
      ReleaseLogger.error('Error loading contact info: $e');
    }
  }

  /// Setup block status listeners.
  ///
  /// Solo actualizamos los flags para UI. El filtrado de mensajes por
  /// visibilidad lo hace el stream manager (filtro `visibleTo`).
  void _setupBlockListeners() {
    _isBlockedSubscription = _blockService.iBlockedStream(contactId).listen((iBlocked) {
      _isBlocked = iBlocked;
      notifyListeners();
    });

    _isBlockedBySubscription = _blockService.isBlockedByStream(contactId).listen((isBlockedBy) {
      _isBlockedBy = isBlockedBy;
      notifyListeners();
    });
  }

  /// Setup notification listener
  void _setupNotificationListener() {
    _notificationSubscription = _notificationService.chatNotificationTapStream.listen((data) {
      final notifChatId = data['chatId'] as String?;
      if (notifChatId == chatId) {
        loadMoreMessages();
      }
    });
  }

  /// ✅ NEW: Load favorite message IDs for this chat
  Future<void> _loadFavorites() async {
    try {
      // Load initial favorites
      _favoriteIds = await _favoriteService.getFavoriteMessageIds(
        chatId: chatId,
        isGroupChat: isGroup,
      );

      // Subscribe to changes
      _favoritesSubscription = _favoriteService.getFavoriteMessageIdsStream(
        chatId: chatId,
        isGroupChat: isGroup,
      ).listen((ids) {
        _favoriteIds = ids;
        notifyListeners();
      });

      notifyListeners();
    } catch (e) {
      ReleaseLogger.error('Error loading favorites: $e');
    }
  }

  /// ✅ NEW: Refresh favorites (call after toggling favorite)
  Future<void> refreshFavorites() async {
    try {
      _favoriteIds = await _favoriteService.getFavoriteMessageIds(
        chatId: chatId,
        isGroupChat: isGroup,
      );
      notifyListeners();
    } catch (e) {
      ReleaseLogger.error('Error refreshing favorites: $e');
    }
  }

  /// ✅ NEW: Start listening to reactions stream
  /// Las reacciones vienen de la subcollection separada y se vinculan
  /// a los mensajes por messageId (funciona aunque el mensaje se elimine de Firestore)
  void _startListeningToReactions() {
    _reactionsSubscription?.cancel();

    _reactionsSubscription = _reactionService.watchReactions(
      chatId: chatId,
      isGroup: isGroup,
    ).listen(
      (reactionsMap) {
        // reactionsMap: {messageId: {emoji: [userId1, userId2, ...]}}
        _updateMessagesWithReactions(reactionsMap);
      },
      onError: (error) {
        ReleaseLogger.error('Error in reactions stream for chat $chatId: $error');
      },
    );
  }

  /// ✅ NEW: Update cached messages with reactions from subcollection
  void _updateMessagesWithReactions(Map<String, Map<String, List<String>>> reactionsMap) {
    if (reactionsMap.isEmpty && _messages.every((m) => m.reactions == null || m.reactions!.isEmpty)) {
      return; // No changes needed
    }

    bool hasChanges = false;

    for (int i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final messageReactions = reactionsMap[message.id];

      // Convertir a formato esperado por ChatMessage.reactions
      final Map<String, dynamic>? newReactions = messageReactions != null && messageReactions.isNotEmpty
          ? messageReactions.map((emoji, userIds) => MapEntry(emoji, userIds))
          : null;

      // Comparar si hay cambios
      final currentReactions = message.reactions;
      final reactionsChanged = _reactionsAreDifferent(currentReactions, newReactions);

      if (reactionsChanged) {
        _messages[i] = message.copyWith(reactions: newReactions);
        hasChanges = true;
      }
    }

    if (hasChanges) {
      notifyListeners();
      ReleaseLogger.log('✅ [Reactions] Updated reactions for chat $chatId');
    }
  }

  /// ✅ Helper: Compare two reaction maps
  bool _reactionsAreDifferent(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    if (a.length != b.length) return true;

    for (final key in a.keys) {
      if (!b.containsKey(key)) return true;
      final aList = a[key] as List?;
      final bList = b[key] as List?;
      if (aList == null && bList == null) continue;
      if (aList == null || bList == null) return true;
      if (aList.length != bList.length) return true;
      for (int i = 0; i < aList.length; i++) {
        if (aList[i] != bList[i]) return true;
      }
    }
    return false;
  }

  /// ✅ V2 Read Receipts: Listen to chat document for lastOpenedAt changes
  /// When recipient's lastOpenedAt changes, recalculate message statuses
  void _startListeningToChatDoc() {
    _chatDocSubscription?.cancel();

    final collection = isGroup ? 'groups_v2' : 'chats';
    _chatDocSubscription = FirebaseFirestore.instance
        .collection(collection)
        .doc(chatId)
        .snapshots()
        .listen(
      (docSnapshot) {
        if (!docSnapshot.exists) return;

        final data = docSnapshot.data();
        if (data == null) return;

        // Para chats 1-1: leer ambos timestamps del destinatario.
        // - lastOpenedAt: necesario para tildes azules (seen).
        // - lastReceivedAt: necesario para doble tilde gris (delivered) — el
        //   receptor lo escribe en background al detectar el mensaje, incluso
        //   sin abrir el chat.
        final newLastOpenedAt =
            (data['lastOpenedAt_$contactId'] as Timestamp?)?.toDate();
        final newLastReceivedAt =
            (data['lastReceivedAt_$contactId'] as Timestamp?)?.toDate();

        final openedChanged = newLastOpenedAt != _recipientLastOpenedAt;
        final receivedChanged = newLastReceivedAt != _recipientLastReceivedAt;

        if (openedChanged || receivedChanged) {
          _recipientLastOpenedAt = newLastOpenedAt;
          _recipientLastReceivedAt = newLastReceivedAt;
          _recalculateMessageStatuses();
        }
      },
      onError: (error) {
        ReleaseLogger.error('Error listening to chat doc $chatId: $error');
      },
    );
  }

  /// ✅ V2 Read Receipts: Recalcula status de mensajes propios usando
  /// `lastReceivedAt` (delivered) y `lastOpenedAt` (seen) del destinatario.
  void _recalculateMessageStatuses() {
    // Si ninguno de los dos timestamps está cargado, no hay nada que recalcular.
    if (_recipientLastOpenedAt == null && _recipientLastReceivedAt == null) {
      return;
    }
    if (_messages.isEmpty) return;

    bool hasChanges = false;

    for (int i = 0; i < _messages.length; i++) {
      final message = _messages[i];

      // Solo recalcular mensajes propios que no estén en estado sending/error
      if (message.senderId != currentUserId) continue;
      if (message.status == MessageStatus.sending || message.status == MessageStatus.error) continue;

      // Calcular nuevo status usando V2
      final newStatus = MessageStatusHelper.calculateStatusV2(
        messageTimestamp: message.timestamp?.toDate(),
        senderId: message.senderId,
        recipientLastOpenedAt: _recipientLastOpenedAt,
        recipientLastReceivedAt: _recipientLastReceivedAt,
      );

      // Solo actualizar si cambió
      if (newStatus != message.status) {
        _messages[i] = message.copyWith(status: newStatus);
        hasChanges = true;
      }
    }

    if (hasChanges) {
      notifyListeners();
      ReleaseLogger.log('✅ [V2 ReadReceipts] Recalculated message statuses for chat $chatId');
    }
  }

  /// Start listening to messages stream (CACHE-FIRST)
  /// Detecta mensajes ENTRANTES nuevos (de otros, frescos) en cada emisión del
  /// stream y reproduce el sonido de recepción una sola vez por mensaje.
  /// El filtro de frescura (15s) evita sonar en backfill/paginación de
  /// mensajes viejos.
  void _maybePlayReceiveSound(List<ChatMessage> incoming) {
    final incomingIds = incoming.map((m) => m.id).toSet();

    // Primera emisión = historial: solo fijar baseline, sin sonar.
    if (!_receiveSoundBaselineSet) {
      _seenMessageIds.addAll(incomingIds);
      _receiveSoundBaselineSet = true;
      return;
    }

    final now = DateTime.now();
    bool hasFreshIncoming = false;
    for (final m in incoming) {
      if (_seenMessageIds.contains(m.id)) continue;
      if (m.senderId == currentUserId) continue; // no mis propios mensajes
      if (m.isDeletedForEveryone) continue;
      final ts = m.timestamp?.toDate() ?? m.localTimestamp;
      if (ts != null && now.difference(ts).abs() < const Duration(seconds: 15)) {
        hasFreshIncoming = true;
      }
    }

    _seenMessageIds.addAll(incomingIds);
    // Acotar para que el set no crezca sin límite en chats largos.
    if (_seenMessageIds.length > 2000) {
      _seenMessageIds
        ..clear()
        ..addAll(incomingIds);
    }

    if (hasFreshIncoming) {
      SoundService().playReceiveSound();
    }
  }

  Future<void> _startListeningToMessages() async {
    // Cancel existing subscription if any
    await _messagesSubscription?.cancel();

    // Create new subscription to CACHE-FIRST stream via orchestrator
    _messagesSubscription = _orchestrator.getMessagesStream(chatId).listen(
      (messages) {
        ReleaseLogger.log('Received ${messages.length} messages from cache for chat $chatId');
        // ✅ Sonido de recepción: mensaje entrante nuevo con el chat abierto.
        _maybePlayReceiveSound(messages);
        // ✅ FIX: Merge with locally deleted messages to preserve isDeletedForEveryone state
        _messages = _mergeWithLocalDeletedState(messages);
        // El filtrado por bloqueo lo hace el stream manager vía `visibleTo`.
        // ✅ V2 Read Receipts: Recalcular status (delivered/seen) si tenemos
        // cualquiera de los dos timestamps del destinatario cargado.
        if (!isGroup &&
            (_recipientLastOpenedAt != null ||
                _recipientLastReceivedAt != null)) {
          _recalculateMessageStatuses();
        }
        // ✅ FIX: Mark loading as done when first messages arrive
        if (_isLoading) {
          _isLoading = false;
        }
        notifyListeners();
      },
      onError: (error) {
        ReleaseLogger.error('Error in messages stream for chat $chatId: $error');
        // ✅ FIX: Also stop loading on error to prevent infinite spinner
        if (_isLoading) {
          _isLoading = false;
          notifyListeners();
        }
      },
    );
  }

  /// ✅ Merge incoming messages with local state
  /// Preserva:
  /// - isDeletedForEveryone de mensajes marcados localmente
  /// - reactions del stream de reacciones (para evitar titileo)
  List<ChatMessage> _mergeWithLocalDeletedState(List<ChatMessage> incomingMessages) {
    // Build maps of local state to preserve
    final locallyDeletedIds = <String>{};
    final localReactions = <String, Map<String, dynamic>>{};

    for (final msg in _messages) {
      if (msg.isDeletedForEveryone) {
        locallyDeletedIds.add(msg.id);
      }
      // ✅ FIX: Preservar reacciones del stream de reacciones
      // El stream de reacciones puede tener datos más recientes que Firestore
      if (msg.reactions != null && msg.reactions!.isNotEmpty) {
        localReactions[msg.id] = msg.reactions!;
      }
    }

    // If no local state to preserve, just return incoming
    if (locallyDeletedIds.isEmpty && localReactions.isEmpty) {
      return incomingMessages;
    }

    // Merge: preserve local state
    return incomingMessages.map((msg) {
      var updatedMsg = msg;

      // Preserve isDeletedForEveryone
      if (locallyDeletedIds.contains(msg.id) && !msg.isDeletedForEveryone) {
        updatedMsg = updatedMsg.copyWith(isDeletedForEveryone: true);
      }

      // ✅ FIX: Preserve reactions from reactions stream if incoming has none/outdated
      // Solo preservar si el mensaje entrante NO tiene reacciones o tiene menos
      final localMsgReactions = localReactions[msg.id];
      if (localMsgReactions != null) {
        final incomingReactions = msg.reactions;
        // Preservar si incoming no tiene reacciones, o si local tiene más/diferentes
        if (incomingReactions == null || incomingReactions.isEmpty) {
          updatedMsg = updatedMsg.copyWith(reactions: localMsgReactions);
        }
      }

      return updatedMsg;
    }).toList();
  }

  /// Get messages stream for UI (CACHE-FIRST)
  Stream<List<ChatMessage>> get messagesStream {
    // Return cache-first stream via orchestrator
    return _orchestrator.getMessagesStream(chatId);
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE SENDING - Cola FIFO para garantizar orden
  // ═══════════════════════════════════════════════════════════════

  /// Send text message with optimistic update (QUEUED FOR ORDER)
  ///
  /// ✅ Los mensajes se encolan y envían secuencialmente para garantizar orden FIFO
  ///
  /// Flow:
  /// 1. Create optimistic message and show in UI immediately
  /// 2. Queue message for sequential sending
  /// 3. Process queue (waits for previous message to complete)
  Future<void> sendTextMessage({
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    if (text.trim().isEmpty || currentUserId.isEmpty) return;

    // 1. Create optimistic message
    final tempId = const Uuid().v4();
    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      text: text,
      replyTo: replyTo,
      type: 'text',
    );

    // 2. Save to cache and show in UI immediately
    await MessageCacheService().saveMessage(chatId, optimisticMessage);
    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
    SoundService().playSendSound(); // ✅ sonido corto de envío
    notifyListeners();

    final textPreview = text.length > 10 ? '${text.substring(0, 10)}...' : text;
    ReleaseLogger.log('📨 [Queue] Mensaje encolado: $textPreview (${_messageQueue.length + 1} en cola)');

    // 3. Queue for sequential sending
    final queuedMessage = _QueuedMessage(
      tempId: tempId,
      type: 'text',
      text: text,
      replyTo: replyTo,
    );
    _messageQueue.add(queuedMessage);

    // 4. Start processing queue (no-op if already processing)
    _processMessageQueue();

    // 5. Wait for this message to complete (success or error)
    try {
      await queuedMessage.completer.future;
    } catch (e) {
      // Error already handled in _processMessageQueue
      rethrow;
    }
  }

  /// ✅ Process message queue sequentially (FIFO)
  /// Only one message is sent at a time, ensuring order is preserved
  Future<void> _processMessageQueue() async {
    // Prevent concurrent processing
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    try {
      while (_messageQueue.isNotEmpty) {
        final queuedMsg = _messageQueue.first;
        ReleaseLogger.log('📤 [Queue] Procesando mensaje: ${queuedMsg.type} (${_messageQueue.length} restantes)');

        try {
          // Send with timeout to prevent blocking
          await _sendQueuedMessage(queuedMsg).timeout(
            _messageTimeout,
            onTimeout: () {
              throw TimeoutException('Mensaje timeout después de ${_messageTimeout.inSeconds}s');
            },
          );
          queuedMsg.completer.complete();
        } catch (e) {
          // ✅ FIX: Update message status to error when timeout/exception occurs
          // (TimeoutException is thrown at this level, not inside _sendQueuedMessage)
          final msgIndex = _messages.indexWhere((m) => m.id == queuedMsg.tempId);
          if (msgIndex != -1) {
            final errorMessage = _messages[msgIndex].copyWith(
              status: MessageStatus.error,
            );
            _messages[msgIndex] = errorMessage;
            await MessageCacheService().updateMessage(chatId, errorMessage);
            notifyListeners();
            ReleaseLogger.error('❌ [Queue] Error/timeout en mensaje: $e');
          }
          queuedMsg.completer.completeError(e);
        }

        // Remove from queue (whether success or error)
        _messageQueue.remove(queuedMsg);
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  /// ✅ Send a single queued message (internal)
  Future<void> _sendQueuedMessage(_QueuedMessage queuedMsg) async {
    final tempId = queuedMsg.tempId;

    // Find the optimistic message in UI state
    final msgIndex = _messages.indexWhere((m) => m.id == tempId);
    if (msgIndex == -1) {
      ReleaseLogger.warning('[Queue] Mensaje no encontrado en UI: $tempId');
      return;
    }
    final optimisticMessage = _messages[msgIndex];

    try {
      // Send based on type
      switch (queuedMsg.type) {
        case 'text':
          await _orchestrator.sendMessage(
            chatId: chatId,
            content: queuedMsg.text!,
            type: MessageType.text,
            replyTo: queuedMsg.replyTo,
            metadata: {'localId': tempId},
          );
          break;
        // Other types will be handled when we refactor sendImage, sendAudio, etc.
        default:
          throw UnsupportedError('Tipo de mensaje no soportado en cola: ${queuedMsg.type}');
      }

      // Success - remove from pending
      _pendingMessages.removeWhere((m) => m.id == tempId);
      ReleaseLogger.log('✅ [Queue] Mensaje enviado: ${queuedMsg.type}');

    } on ModerationBlockedException catch (e) {
      // Moderation blocked - update message in place
      final updatedMessage = optimisticMessage.copyWith(
        text: null,
        status: MessageStatus.sent,
        moderationStatus: ModerationStatus.blocked,
        moderationReason: e.reason,
        originalText: queuedMsg.text,
      );

      _messages[msgIndex] = updatedMessage;
      _pendingMessages.removeWhere((m) => m.id == tempId);
      await MessageCacheService().updateMessage(chatId, updatedMessage);
      notifyListeners();

      ReleaseLogger.log('🚫 [Queue] Mensaje bloqueado por moderación: ${e.reason}');
      // Don't rethrow - blocked messages are shown in UI

    } catch (e) {
      // Other errors - mark as error
      final errorMessage = optimisticMessage.copyWith(
        status: MessageStatus.error,
      );

      _messages[msgIndex] = errorMessage;
      await MessageCacheService().updateMessage(chatId, errorMessage);
      notifyListeners();

      ReleaseLogger.error('❌ [Queue] Error enviando mensaje: $e');
      rethrow;
    }
  }

  /// Marca el mensaje optimista [tempId] como error preservando su path local
  /// para que la preview siga visible y el retry pueda re-subir el archivo.
  void _markOptimisticAsError(String tempId, {String? localPath}) {
    final idx = _messages.indexWhere((m) => m.id == tempId);
    if (idx == -1) return;
    final errored = _messages[idx].copyWith(
      status: MessageStatus.error,
      localPath: localPath ?? _messages[idx].localPath,
    );
    _messages[idx] = errored;
    _pendingMessages.removeWhere((m) => m.id == tempId);
    MessageCacheService().updateMessage(chatId, errored);
    notifyListeners();
  }

  /// Devuelve el path local de un archivo multimedia adjunto, o null si no hay.
  /// Considera `localPath` y, como fallback, los campos *Url cuando apuntan a un
  /// archivo local (no a una URL http remota ya subida).
  String? _localMediaPath(ChatMessage m) {
    if (m.localPath != null && m.localPath!.isNotEmpty) return m.localPath;
    for (final url in [m.imageUrl, m.videoUrl, m.audioUrl]) {
      if (url != null && url.isNotEmpty && !url.startsWith('http')) return url;
    }
    return null;
  }

  /// Mapea el `type` string del mensaje al enum MessageType para reenvío.
  MessageType _mediaTypeFor(String? type) {
    switch (type) {
      case 'image':
        return MessageType.image;
      case 'video':
        return MessageType.video;
      case 'audio':
        return MessageType.audio;
      default:
        return MessageType.text;
    }
  }

  /// Retry sending a failed message (keeps same position in chat)
  ///
  /// Flow:
  /// 1. Find the failed message
  /// 2. Update status to "sending"
  /// 3. Try to send via orchestrator
  /// 4. If success: message will be updated via stream
  /// 5. If error: update status back to "error"
  Future<void> retryMessage(String messageId) async {
    // 1. Find the failed message
    final messageIndex = _messages.indexWhere((m) => m.id == messageId);
    if (messageIndex == -1) {
      ReleaseLogger.error('Cannot retry message: not found $messageId');
      return;
    }

    final failedMessage = _messages[messageIndex];

    // Only retry messages with error status or sending status (timeout)
    if (failedMessage.status != MessageStatus.error &&
        failedMessage.status != MessageStatus.sending) {
      ReleaseLogger.warning('Cannot retry message with status ${failedMessage.status}');
      return;
    }

    // ⚠️ El envío original SIGUE EN CURSO: el status bar mostró "error" por el
    // timeout de 30s (cold start / archivo grande), pero el upload no falló.
    // Disparar un retry ahora crearía un SEGUNDO mensaje en Firestore (duplicado).
    // Solo reseteamos el timer visual a "sending" y dejamos que el envío termine.
    if (_inFlightSends.contains(messageId)) {
      final idx = _messages.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          status: MessageStatus.sending,
          localTimestamp: DateTime.now(),
        );
        notifyListeners();
      }
      ReleaseLogger.log('⏳ Retry ignorado: envío aún en curso para ${messageId.substring(0, 8)}...');
      return;
    }

    // 2. Update to "sending" state
    final sendingMessage = failedMessage.copyWith(
      status: MessageStatus.sending,
      localTimestamp: DateTime.now(), // Reset timestamp for new timeout
    );

    _messages[messageIndex] = sendingMessage;
    await MessageCacheService().updateMessage(chatId, sendingMessage);
    notifyListeners();

    ReleaseLogger.log('🔄 Retrying message ${messageId.substring(0, 8)}...');

    _inFlightSends.add(messageId);
    try {
      // 3. Send to backend via orchestrator
      final mediaPath = _localMediaPath(failedMessage);
      final isTextMessage = (failedMessage.type == null ||
              failedMessage.type == 'text') &&
          failedMessage.text != null &&
          failedMessage.text!.isNotEmpty;

      if (isTextMessage) {
        await _orchestrator.sendMessage(
          chatId: chatId,
          content: failedMessage.text!,
          type: MessageType.text,
          replyTo: failedMessage.replyTo,
          metadata: {'localId': messageId}, // Use same ID for correlation
        );

        // Success - message will be updated via stream with real ID
        ReleaseLogger.log('✅ Message retry successful for ${messageId.substring(0, 8)}...');
      } else if (mediaPath != null) {
        // ✅ FIX: Retry de mensajes multimedia (imagen/video/audio).
        // Antes esto era un TODO y el retry no hacía nada: la burbuja quedaba
        // colgada y, si el envío original terminaba en paralelo, aparecía una
        // segunda burbuja. Re-subimos usando el path local preservado y el MISMO
        // localId para que la dedup colapse todo en una sola burbuja.
        await _orchestrator.sendMessage(
          chatId: chatId,
          content: failedMessage.text ?? '',
          type: _mediaTypeFor(failedMessage.type),
          mediaPath: mediaPath,
          replyTo: failedMessage.replyTo,
          metadata: {'localId': messageId},
        );
        ReleaseLogger.log('✅ Media retry successful for ${messageId.substring(0, 8)}...');
      } else {
        // Sin texto ni archivo local disponible: no se puede reintentar.
        throw Exception('No hay contenido ni archivo local para reenviar');
      }
    } catch (e) {
      // 4. Error - update status back to error
      final errorMessage = sendingMessage.copyWith(
        status: MessageStatus.error,
      );

      final currentIndex = _messages.indexWhere((m) => m.id == messageId);
      if (currentIndex != -1) {
        _messages[currentIndex] = errorMessage;
        await MessageCacheService().updateMessage(chatId, errorMessage);
        notifyListeners();
      }

      ReleaseLogger.error('❌ Message retry failed for ${messageId.substring(0, 8)}...: $e');
    } finally {
      _inFlightSends.remove(messageId);
    }
  }

  /// Edit a blocked message (calls moderation directly, no Firestore message)
  ///
  /// Flow:
  /// 1. Find blocked message
  /// 2. Update to "sending" state (clear moderation fields for UI)
  /// 3. Call Cloud Function for moderation check ONLY
  /// 4. If approved: update to normal message
  /// 5. If blocked: update with new blocked text and reason
  ///
  /// IMPORTANT: NEVER creates two bubbles - always updates the same message
  Future<void> editBlockedMessage({
    required String messageId,
    required String newText,
  }) async {
    if (newText.trim().isEmpty || currentUserId.isEmpty) return;

    // 1. Find the blocked message
    final messageIndex = _messages.indexWhere((m) => m.id == messageId);
    if (messageIndex == -1) {
      ReleaseLogger.error('Cannot edit blocked message: message not found $messageId');
      return;
    }

    final blockedMessage = _messages[messageIndex];

    // 2. Update to "sending" state (clear moderation for pending UI)
    // Create new message directly instead of copyWith to ensure fields are properly cleared
    final sendingMessage = ChatMessage(
      id: blockedMessage.id,
      senderId: blockedMessage.senderId,
      text: newText, // Show new text while sending
      status: MessageStatus.sending, // Show as pending (spinner)
      localTimestamp: DateTime.now(),
      // Clear all moderation fields so UI shows normal pending bubble
      moderationStatus: null,
      moderationReason: null,
      originalText: null,
      // Preserve other fields
      imageUrl: blockedMessage.imageUrl,
      videoUrl: blockedMessage.videoUrl,
      audioUrl: blockedMessage.audioUrl,
      timestamp: blockedMessage.timestamp,
      isRead: blockedMessage.isRead,
      replyTo: blockedMessage.replyTo,
      reactions: blockedMessage.reactions,
      type: blockedMessage.type,
    );

    _messages[messageIndex] = sendingMessage;
    await MessageCacheService().updateMessage(chatId, sendingMessage);
    notifyListeners();

    try {
      // 3. Call moderation check via orchestrator (no Firestore message creation)
      await _orchestrator.checkModerationOnly(chatId: chatId, content: newText);

      // 4. If approved: update to normal message and write to Firestore
      final approvedMessage = ChatMessage(
        id: sendingMessage.id,
        senderId: sendingMessage.senderId,
        text: newText,
        status: MessageStatus.sent,
        timestamp: sendingMessage.timestamp,
        localTimestamp: sendingMessage.localTimestamp,
        // Clear all moderation fields
        moderationStatus: ModerationStatus.approved,
        moderationReason: null,
        originalText: null,
        // Preserve other fields
        imageUrl: sendingMessage.imageUrl,
        videoUrl: sendingMessage.videoUrl,
        audioUrl: sendingMessage.audioUrl,
        isRead: sendingMessage.isRead,
        replyTo: sendingMessage.replyTo,
        reactions: sendingMessage.reactions,
        type: sendingMessage.type,
      );

      // Update local state first (optimistic update)
      _messages[messageIndex] = approvedMessage;
      await MessageCacheService().updateMessage(chatId, approvedMessage);
      notifyListeners();

      // Create approved message in Firestore via orchestrator
      await _orchestrator.createApprovedMessage(
        chatId: chatId,
        messageId: messageId,
        senderId: currentUserId,
        text: newText,
        localId: messageId, // ✅ FIX: Pasar messageId como localId para deduplicación
      );

      ReleaseLogger.log('Blocked message edited and approved: $messageId');
    } on ModerationBlockedException catch (e) {
      // 5. If blocked: update with new blocked text
      final reblockedMessage = ChatMessage(
        id: blockedMessage.id,
        senderId: blockedMessage.senderId,
        text: null, // Clear text for blocked display
        status: MessageStatus.sent,
        localTimestamp: DateTime.now(),
        // Set moderation fields
        moderationStatus: ModerationStatus.blocked,
        moderationReason: e.reason,
        originalText: newText, // Save new text for next edit attempt
        // Preserve other fields
        imageUrl: blockedMessage.imageUrl,
        videoUrl: blockedMessage.videoUrl,
        audioUrl: blockedMessage.audioUrl,
        timestamp: blockedMessage.timestamp,
        isRead: blockedMessage.isRead,
        replyTo: blockedMessage.replyTo,
        reactions: blockedMessage.reactions,
        type: blockedMessage.type,
      );

      // Update local state only (blocked messages don't go to Firestore)
      _messages[messageIndex] = reblockedMessage;
      await MessageCacheService().updateMessage(chatId, reblockedMessage);
      notifyListeners();

      ReleaseLogger.log('Edited message blocked again: $messageId - ${e.reason}');
      // NO rethrow - show as blocked bubble in UI
    } catch (e) {
      // 6. Other errors - restore to blocked state with original text
      final errorMessage = blockedMessage.copyWith(
        status: MessageStatus.error,
        text: blockedMessage.originalText, // Restore original for retry
      );

      _messages[messageIndex] = errorMessage;
      await MessageCacheService().updateMessage(chatId, errorMessage);
      notifyListeners();

      ReleaseLogger.error('Failed to edit blocked message $messageId: $e');
      rethrow;
    }
  }

  /// Create optimistic audio bubble
  Future<void> createOptimisticAudioBubble(String audioPath) async {
    final tempId = const Uuid().v4();

    // Process audio to get waveform
    final audioFile = File(audioPath);
    final waveform = await _audioService.extractWaveform(audioFile);
    // Duration could be used for UI display if needed
    // final duration = await _audioService.getAudioDuration(audioFile);

    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      type: 'audio',
      audioUrl: audioPath, // Local path temporarily
      waveformData: waveform,  // Correct parameter name from ChatMessage
    );

    // ✅ FIX: Persistir a Hive (ver sendImage) para que la burbuja sobreviva
    // salir/reentrar al chat durante una subida lenta.
    await MessageCacheService().saveMessage(chatId, optimisticMessage);
    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
    SoundService().playSendSound(); // ✅ sonido corto de envío
    notifyListeners();
  }

  /// Process and upload audio in background
  ///
  /// [transcription] - Transcripción local del audio (gratis, usando STT del dispositivo)
  /// Se envía al servidor para moderación en lugar de usar APIs de pago como Whisper
  Future<void> processAndUploadAudio(String audioPath, {String? transcription}) async {
    // ✅ FIX duplicado: el flujo de audio está partido (createOptimisticAudioBubble
    // crea el optimista, este método lo sube). Sin pasar el MISMO id como localId,
    // el mensaje real de Firestore no reconcilia con el optimista → DOS burbujas.
    // Buscamos el id del optimista por su audioPath y lo pasamos como localId.
    final optIdx = _messages.indexWhere((m) => m.audioUrl == audioPath);
    final localId = optIdx != -1 ? _messages[optIdx].id : null;
    try {
      // Construir metadata con transcripción si está disponible
      final Map<String, dynamic> metadata = {};
      if (transcription != null && transcription.isNotEmpty) {
        metadata['transcription'] = transcription;
        ReleaseLogger.log('📝 Enviando audio con transcripción local', tag: 'Audio');
      }
      if (localId != null) metadata['localId'] = localId;

      if (localId != null) _inFlightSends.add(localId);
      try {
        await _orchestrator.sendMessage(
          chatId: chatId,
          content: '', // Audio messages don't need text content
          type: MessageType.audio,
          mediaPath: audioPath,
          metadata: metadata.isNotEmpty ? metadata : null,
        );
      } finally {
        if (localId != null) _inFlightSends.remove(localId);
      }

      // Remove from pending messages
      _pendingMessages.removeWhere((m) => m.audioUrl == audioPath);
      ReleaseLogger.log('Audio uploaded successfully');
    } catch (e) {
      ReleaseLogger.error('Failed to upload audio: $e');
      // Update optimistic message to error status (y persistir a Hive para que
      // sobreviva la navegación, como imágenes/video).
      final failedIndex = _messages.indexWhere((m) => m.audioUrl == audioPath);
      if (failedIndex != -1) {
        final errored = _messages[failedIndex].copyWith(
          status: MessageStatus.error,
        );
        _messages[failedIndex] = errored;
        await MessageCacheService().updateMessage(chatId, errored);
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Send image with optimistic updates
  Future<void> sendImage({required ImageSource source}) async {
    // Hoisted para que el catch pueda marcar la burbuja como error.
    String? errorTempId;
    String? errorLocalPath;
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1920,
        maxHeight: 1920,
      );

      if (pickedFile == null) return;

      // Create optimistic message
      final tempId = const Uuid().v4();
      errorTempId = tempId;
      errorLocalPath = pickedFile.path;
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'image',
        localPath: pickedFile.path, // ✅ FIX: Usar localPath para imagen local
      );

      // ✅ FIX: Persistir a Hive como el texto (línea ~612). Sin esto, al salir
      // y reentrar al chat durante una subida lenta la burbuja desaparecía
      // (no sobrevivía la navegación) hasta que Firestore confirmaba.
      await MessageCacheService().saveMessage(chatId, optimisticMessage);
      _pendingMessages.add(optimisticMessage);
      _messages.insert(0, optimisticMessage);
      SoundService().playSendSound(); // ✅ sonido corto de envío
      notifyListeners();

      // ✅ OPTIMIZACIÓN: Comprimir imagen antes de subir
      final imageFile = File(pickedFile.path);
      final compressedFile = await MediaCompressionService().compressImage(imageFile);
      final fileToUpload = compressedFile ?? imageFile;

      // Upload in background via orchestrator
      // ✅ FIX: Pasar localId=tempId para que el optimista del servicio y el
      // mensaje real de Firestore compartan el MISMO id. Sin esto, la dedup por
      // localId no matchea y aparecen DOS burbujas (la fallida + la enviada).
      _inFlightSends.add(tempId);
      try {
        await _orchestrator.sendMessage(
          chatId: chatId,
          content: '', // Image messages don't need text content
          type: MessageType.image,
          mediaPath: fileToUpload.path,
          metadata: {'localId': tempId},
        );
      } finally {
        _inFlightSends.remove(tempId);
      }

      // Remove from pending
      _pendingMessages.removeWhere((m) => m.id == tempId);
    } catch (e) {
      ReleaseLogger.error('Failed to send image: $e');
      // ✅ FIX: Preservar la burbuja en estado error con el path local ORIGINAL
      // (no el comprimido, que es temporal) para que la foto siga visible y el
      // retry pueda re-subirla. Antes la burbuja quedaba vacía o desaparecía.
      if (errorTempId != null) {
        _markOptimisticAsError(errorTempId, localPath: errorLocalPath);
      }
      rethrow;
    }
  }

  /// Send video with optimistic updates
  Future<void> sendVideo({String? path, PlatformFile? file}) async {
    String? errorTempId;
    String? errorLocalPath;
    try {
      String? videoPath = path;

      if (videoPath == null && file == null) {
        // Pick video from gallery
        final picker = ImagePicker();
        final pickedFile = await picker.pickVideo(source: ImageSource.gallery);
        if (pickedFile == null) return;
        videoPath = pickedFile.path;
      } else if (file != null) {
        videoPath = file.path;
      }

      if (videoPath == null) return;

      // Create optimistic message
      final tempId = const Uuid().v4();
      errorTempId = tempId;
      errorLocalPath = videoPath;
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'video',
        videoUrl: videoPath, // Local path temporarily
      );

      // ✅ FIX: Persistir a Hive (ver sendImage) para que sobreviva la navegación.
      await MessageCacheService().saveMessage(chatId, optimisticMessage);
      _pendingMessages.add(optimisticMessage);
      _messages.insert(0, optimisticMessage);
      SoundService().playSendSound(); // ✅ sonido corto de envío
      notifyListeners();

      // Upload in background via orchestrator
      // ✅ FIX: localId=tempId para dedup correcta (ver sendImage).
      _inFlightSends.add(tempId);
      try {
        await _orchestrator.sendMessage(
          chatId: chatId,
          content: '', // Video messages don't need text content
          type: MessageType.video,
          mediaPath: videoPath,
          metadata: {'localId': tempId},
        );
      } finally {
        _inFlightSends.remove(tempId);
      }

      // Remove from pending
      _pendingMessages.removeWhere((m) => m.id == tempId);
    } catch (e) {
      ReleaseLogger.error('Failed to send video: $e');
      if (errorTempId != null) {
        _markOptimisticAsError(errorTempId, localPath: errorLocalPath);
      }
      rethrow;
    }
  }

  /// Create optimistic video message for immediate display
  void createOptimisticVideoMessage({
    required String videoPath,
    String? thumbnailPath,
  }) {
    final tempId = const Uuid().v4();
    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      type: 'video',
      videoUrl: videoPath,
      imageUrl: thumbnailPath, // Use image URL for thumbnail preview
    );

    // ✅ FIX: Persistir a Hive (ver sendImage) para que sobreviva la navegación.
    unawaited(MessageCacheService().saveMessage(chatId, optimisticMessage));
    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
    SoundService().playSendSound(); // ✅ sonido corto de envío
    notifyListeners();
  }

  /// Process and upload video in background
  Future<void> processAndUploadVideo({required String videoPath}) async {
    try {
      await _orchestrator.sendMessage(
        chatId: chatId,
        content: '', // Video messages don't need text content
        type: MessageType.video,
        mediaPath: videoPath,
      );

      // Remove from pending
      _pendingMessages.removeWhere((m) => m.videoUrl == videoPath);
      ReleaseLogger.log('Video uploaded successfully');
    } catch (e) {
      ReleaseLogger.error('Failed to upload video: $e');
      // Update optimistic message to error status
      final failedIndex = _messages.indexWhere((m) => m.videoUrl == videoPath);
      if (failedIndex != -1) {
        _messages[failedIndex] = _messages[failedIndex].copyWith(
          status: MessageStatus.error,
        );
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Send a media message (image/video)
  Future<void> sendMediaMessage({
    required String mediaPath,
    required String mediaType,
    String? caption,
    Function(String messageId, double progress)? onProgressUpdate,
  }) async {
    ReleaseLogger.log('Uploading $mediaType message to chat $chatId');

    try {
      final type = mediaType == 'image'
          ? MessageType.image
          : mediaType == 'video'
              ? MessageType.video
              : mediaType == 'audio'
                  ? MessageType.audio
                  : MessageType.text;

      await _orchestrator.sendMessage(
        chatId: chatId,
        content: caption ?? '',
        type: type,
        mediaPath: mediaPath,
        onProgressUpdate: onProgressUpdate,
      );
      ReleaseLogger.log('$mediaType message uploaded successfully to chat $chatId');
    } catch (e) {
      ReleaseLogger.error('Failed to upload $mediaType message to chat $chatId: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Delete a message for everyone
  /// ✅ Usa deleteForEveryone que crea evento de eliminación para sincronizar cache
  /// Restricciones: Solo el sender puede eliminar, dentro de 10 minutos
  Future<bool> deleteMessage(String messageId, Timestamp? timestamp) async {
    ReleaseLogger.log('Deleting message $messageId from chat $chatId');

    try {
      // 1. ✅ Delete using atomic service (creates deletion event)
      final result = await _deleteMessageService.deleteForEveryone(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      if (result.success) {
        // 2. ✅ Marcar como eliminado localmente (no remover, mostrar "Mensaje eliminado")
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            isDeletedForEveryone: true,
            text: null,
            imageUrl: null,
            videoUrl: null,
            audioUrl: null,
          );
          notifyListeners();
        }

        // 3. ✅ Actualizar cache
        await MessageCacheService().saveMessages(chatId, _messages);

        ReleaseLogger.log('Message $messageId deleted successfully');
        return true;
      } else {
        ReleaseLogger.error('Failed to delete message: ${result.message}');
        return false;
      }
    } catch (e) {
      ReleaseLogger.error('Failed to delete message $messageId: $e');
      return false;
    }
  }

  /// Update blocked message (edit)
  /// ✅ Usa nuevo servicio atómico EditMessageService
  Future<void> updateBlockedMessage(String messageId, String newContent) async {
    ReleaseLogger.log('Editing blocked message $messageId in chat $chatId');

    try {
      final result = await _editMessageService.call(
        chatId: chatId,
        messageId: messageId,
        newText: newContent,
        isGroup: isGroup,
      );

      if (result.success) {
        ReleaseLogger.log('Message $messageId edited successfully');
      } else {
        ReleaseLogger.error('Failed to edit message: ${result.message}');
        throw Exception(result.message);
      }
    } catch (e) {
      ReleaseLogger.error('Failed to edit message $messageId: $e');
      rethrow;
    }
  }

  /// Clear chat history
  /// ✅ Usa nuevo servicio atómico ClearChatService
  Future<bool> clearChat() async {
    try {
      // ✅ Usar nuevo servicio atómico
      final result = await _clearChatService.call(chatId: chatId);

      if (!result.success) {
        ReleaseLogger.error('Failed to clear chat: ${result.message}');
        return false;
      }

      // ✅ FIX: Invalidar cache de clearedAt para forzar refresh
      _orchestrator.invalidateClearedAtCache(chatId, currentUserId);

      // ✅ FIX: Cerrar stream actual (con clearedAt antiguo) para recrear con nuevo
      _orchestrator.resetChatStream(chatId);

      // ✅ FIX: Limpiar cache de Hive (persistente)
      await MessageCacheService().clearChat(chatId);

      // ✅ FIX: Limpiar cache local en memoria
      _messages.clear();
      notifyListeners();

      // ✅ FIX: Forzar refresh del stream para recrearlo con nuevo clearedAt
      await refreshMessages();

      ReleaseLogger.log('Chat $chatId cleared successfully');
      return true;
    } catch (e) {
      ReleaseLogger.error('Failed to clear chat: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Set typing indicator
  void setTyping(bool isTyping) {
    _typingService.setTyping(
      chatId,
      isTyping,
      isGroup: isGroup,
    );
  }

  /// Set recording indicator
  void setRecording(bool isRecording) {
    _typingService.setRecording(
      chatId,
      isRecording,
      isGroup: isGroup,
    );
  }

  /// Stop recording indicator
  void stopRecording() {
    _typingService.stopRecording();
  }

  /// Mark chat as read
  /// ✅ Usa nuevo servicio atómico MarkMessagesReadService
  Future<void> markChatAsRead() async {
    try {
      await _markReadService.call(chatId: chatId, isGroup: isGroup);
      ReleaseLogger.log('Chat $chatId marked as read');
    } catch (e) {
      ReleaseLogger.error('Failed to mark chat $chatId as read: $e');
    }
  }

  /// ✅ FIX: Marca mensajes como vistos para actualizar lastOpenedAt (V2 read receipts)
  ///
  /// Esto actualiza lastOpenedAt_{userId} en el chat document, lo cual permite
  /// que el sender vea sus mensajes como "seen" cuando message.timestamp < lastOpenedAt
  ///
  /// Llamar cuando:
  /// - El usuario entra al chat
  /// - El usuario resume la app con el chat abierto
  Future<void> markAsSeenForReceipts() async {
    try {
      await ReadReceiptsService().markMessagesAsSeen(
        chatId: chatId,
        isGroupChat: isGroup,
      );
      ReleaseLogger.log('✅ Chat $chatId: lastOpenedAt actualizado para read receipts');
    } catch (e) {
      ReleaseLogger.error('Failed to mark messages as seen for chat $chatId: $e');
    }
  }

  /// Get current user data
  /// ✅ REFACTORED: Now uses UserRepository instead of direct Firestore access
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    try {
      return await _userRepository.getCurrentUserData();
    } catch (e) {
      ReleaseLogger.error('Failed to get current user data: $e');
      return null;
    }
  }

  /// Load more messages (pagination)
  Future<void> loadMoreMessages() async {
    if (_isLoadingMore || !hasMoreMessages) {
      ReleaseLogger.log('Cannot load more messages');
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    try {
      final lastMessage = _messages.isNotEmpty ? _messages.last : null;
      final moreMessages = await _orchestrator.loadMoreMessages(
        chatId: chatId,
        lastMessage: lastMessage,
      );

      if (moreMessages.isNotEmpty) {
        _messages.addAll(moreMessages);
        notifyListeners();
        ReleaseLogger.log('Loaded ${moreMessages.length} more messages');
      }
    } catch (e) {
      ReleaseLogger.error('Failed to load more messages: $e');
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  /// Refresh messages from cache
  Future<void> refreshMessages() async {
    ReleaseLogger.log('Refreshing messages for chat $chatId');

    try {
      // Force refresh from cache - just re-listen to the stream
      // The stream manager will automatically fetch from cache first
      await _startListeningToMessages();
      ReleaseLogger.log('Refreshed messages from cache');
    } catch (e) {
      ReleaseLogger.error('Failed to refresh messages: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Dispose of controller resources
  @override
  void dispose() {
    ReleaseLogger.log('Disposing ChatController for chat $chatId');

    // Cancel stream subscriptions
    _messagesSubscription?.cancel();
    _isBlockedSubscription?.cancel();
    _isBlockedBySubscription?.cancel();
    _notificationSubscription?.cancel();
    _favoritesSubscription?.cancel();
    _reactionsSubscription?.cancel();
    _chatDocSubscription?.cancel();  // ✅ V2 Read Receipts

    // Clear state
    _messages.clear();
    _pendingMessages.clear();
    _isInitialized = false;

    super.dispose();

    ReleaseLogger.log('ChatController disposed for chat $chatId');
  }
}