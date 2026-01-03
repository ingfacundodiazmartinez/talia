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
import '../services/chats/repositories/chat_repository.dart';
import '../services/chats/services/chat_messaging_service.dart';  // For MessageType enum
// ✅ Nuevos servicios atómicos
import '../services/chats/chat_services.dart';
import '../services/typing_indicator_service.dart';
import '../services/block_service.dart';
import '../services/audio_processing_service.dart';
import '../services/message_cache_service.dart';
import '../services/favorite_service.dart';  // ✅ NEW: For favorite tracking
import '../services/media_compression_service.dart';
import '../services/reaction_service.dart';  // ✅ NEW: For reactions
import '../services/read_receipts_service.dart';  // ✅ FIX: For V2 read receipts
import '../notification_service.dart';
import '../utils/release_logger.dart';
import 'package:uuid/uuid.dart';

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
  late final ChatRepository _chatRepository;
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

  // State
  List<ChatMessage> _messages = [];
  final List<ChatMessage> _pendingMessages = [];
  bool _isInitialized = false;
  bool _isLoading = true;  // ✅ FIX: Start as true, set to false when first messages arrive
  bool _hasLoadedInitialMessages = false;
  bool _isLoadingMore = false;

  // Contact state
  String _contactPhotoURL = '';
  bool _contactIsOnline = false;

  // Block state
  bool _isBlocked = false;
  bool _isBlockedBy = false;

  // ✅ NEW: Favorite tracking
  Set<String> _favoriteIds = {};

  // Current user
  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  // Public getters
  List<ChatMessage> get messages => [..._messages];
  List<ChatMessage> get pendingMessages => [..._pendingMessages];
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
    ChatRepository? chatRepository,
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
    _chatRepository = chatRepository ?? ChatRepository(
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

    _isInitialized = true;
    _hasLoadedInitialMessages = true;

    // ✅ FIX: Delay markChatAsRead() para que se ejecute DESPUÉS de que los mensajes
    // se rendericen en el UI. Esto evita que el mensaje aparezca como "leído"
    // antes de que la burbuja sea visible en pantalla.
    Future.delayed(const Duration(milliseconds: 1500), () async {
      try {
        await markChatAsRead();
      } catch (e) {
        if (e.toString().contains('permission-denied')) {
          ReleaseLogger.warning('Sin permisos para marcar chat como leído (¿usuario no es participante?)', tag: 'ChatController');
        } else {
          ReleaseLogger.error('Error en markChatAsRead: $e', tag: 'ChatController');
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

  /// Setup block status listeners
  void _setupBlockListeners() {
    _isBlockedSubscription = _blockService.isBlockedStream(contactId).listen((isBlocked) {
      _isBlocked = isBlocked;
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

  /// Start listening to messages stream (CACHE-FIRST)
  Future<void> _startListeningToMessages() async {
    // Cancel existing subscription if any
    await _messagesSubscription?.cancel();

    // Create new subscription to CACHE-FIRST stream via orchestrator
    _messagesSubscription = _orchestrator.getMessagesStream(chatId).listen(
      (messages) {
        ReleaseLogger.log('Received ${messages.length} messages from cache for chat $chatId');
        _messages = messages;
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

  /// Get messages stream for UI (CACHE-FIRST)
  Stream<List<ChatMessage>> get messagesStream {
    // Return cache-first stream via orchestrator
    return _orchestrator.getMessagesStream(chatId);
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE SENDING - Optimistic updates
  // ═══════════════════════════════════════════════════════════════

  /// Send text message with optimistic update (SIMPLIFIED FLOW)
  ///
  /// Flow:
  /// 1. Create message
  /// 2. Save to cache IMMEDIATELY
  /// 3. Add to UI state
  /// 4. Send to backend/moderation
  /// 5. If blocked: UPDATE the same message (not create new)
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

    // 2. ✅ Guardar en Hive inmediatamente (se actualizará cuando llegue el mensaje real)
    await MessageCacheService().saveMessage(chatId, optimisticMessage);
    final textPreview = text.length > 10 ? text.substring(0, 10) : text;
    ReleaseLogger.log('💾 [DEBUG] Mensaje optimista guardado en Hive: ID=${tempId.substring(0, 8)}..., text=$textPreview...');

    // 3. Add to UI state
    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
    notifyListeners();

    try {
      // 4. Send to backend via orchestrator (includes moderation check)
      await _orchestrator.sendMessage(
        chatId: chatId,
        content: text,
        type: MessageType.text,
        replyTo: replyTo,  // ✅ FIX: Pasar replyTo completo para preservar text, senderName, etc.
        metadata: {'localId': tempId},  // ✅ FIX: Pasar tempId para correlación
      );

      // 5. Success - remove from pending
      _pendingMessages.removeWhere((m) => m.id == tempId);
      ReleaseLogger.log('Text message sent successfully to chat $chatId');
    } on ModerationBlockedException catch (e) {
      // 6. Moderation blocked - UPDATE the same message (not create new)
      final failedIndex = _messages.indexWhere((m) => m.id == tempId);
      if (failedIndex != -1) {
        final updatedMessage = optimisticMessage.copyWith(
          text: null, // Clear text for blocked display
          status: MessageStatus.sent,
          moderationStatus: ModerationStatus.blocked,
          moderationReason: e.reason,
          originalText: text, // Preserve for editing
        );

        // Update in UI state
        _messages[failedIndex] = updatedMessage;
        _pendingMessages.removeWhere((m) => m.id == tempId);

        // Update in persistent cache
        await MessageCacheService().updateMessage(chatId, updatedMessage);

        notifyListeners();
        ReleaseLogger.log('Message blocked by moderation in chat $chatId: ${e.reason}');
        // NO rethrow - show as blocked bubble in UI
      }
    } catch (e) {
      // 7. Other errors (network, etc) - mark as error
      final failedIndex = _messages.indexWhere((m) => m.id == tempId);
      if (failedIndex != -1) {
        final errorMessage = optimisticMessage.copyWith(
          status: MessageStatus.error,
        );

        _messages[failedIndex] = errorMessage;
        await MessageCacheService().updateMessage(chatId, errorMessage);

        notifyListeners();
        ReleaseLogger.error('Failed to send text message to chat $chatId: $e');
        rethrow;
      } else {
        ReleaseLogger.error('Failed to send text message to chat $chatId: $e');
        rethrow;
      }
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

    // 2. Update to "sending" state
    final sendingMessage = failedMessage.copyWith(
      status: MessageStatus.sending,
      localTimestamp: DateTime.now(), // Reset timestamp for new timeout
    );

    _messages[messageIndex] = sendingMessage;
    await MessageCacheService().updateMessage(chatId, sendingMessage);
    notifyListeners();

    ReleaseLogger.log('🔄 Retrying message ${messageId.substring(0, 8)}...');

    try {
      // 3. Send to backend via orchestrator
      if (failedMessage.text != null && failedMessage.text!.isNotEmpty) {
        await _orchestrator.sendMessage(
          chatId: chatId,
          content: failedMessage.text!,
          type: MessageType.text,
          replyTo: failedMessage.replyTo,
          metadata: {'localId': messageId}, // Use same ID for correlation
        );

        // Success - message will be updated via stream with real ID
        ReleaseLogger.log('✅ Message retry successful for ${messageId.substring(0, 8)}...');
      }
      // TODO: Handle retry for media messages (image, video, audio)
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

    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
    notifyListeners();
  }

  /// Process and upload audio in background
  Future<void> processAndUploadAudio(String audioPath, {bool isAiGenerated = false}) async {
    try {
      await _orchestrator.sendMessage(
        chatId: chatId,
        content: '', // Audio messages don't need text content
        type: MessageType.audio,
        mediaPath: audioPath,
        metadata: isAiGenerated ? {'isAiGenerated': true} : null,
      );

      // Remove from pending messages
      _pendingMessages.removeWhere((m) => m.audioUrl == audioPath);
      ReleaseLogger.log('Audio uploaded successfully');
    } catch (e) {
      ReleaseLogger.error('Failed to upload audio: $e');
      // Update optimistic message to error status
      final failedIndex = _messages.indexWhere((m) => m.audioUrl == audioPath);
      if (failedIndex != -1) {
        _messages[failedIndex] = _messages[failedIndex].copyWith(
          status: MessageStatus.error,
        );
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Send image with optimistic updates
  Future<void> sendImage({required ImageSource source}) async {
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
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'image',
        localPath: pickedFile.path, // ✅ FIX: Usar localPath para imagen local
      );

      _pendingMessages.add(optimisticMessage);
      _messages.insert(0, optimisticMessage);
      notifyListeners();

      // ✅ OPTIMIZACIÓN: Comprimir imagen antes de subir
      final imageFile = File(pickedFile.path);
      final compressedFile = await MediaCompressionService().compressImage(imageFile);
      final fileToUpload = compressedFile ?? imageFile;

      // Upload in background via orchestrator
      await _orchestrator.sendMessage(
        chatId: chatId,
        content: '', // Image messages don't need text content
        type: MessageType.image,
        mediaPath: fileToUpload.path,
      );

      // Remove from pending
      _pendingMessages.removeWhere((m) => m.id == tempId);
    } catch (e) {
      ReleaseLogger.error('Failed to send image: $e');
      rethrow;
    }
  }

  /// Send video with optimistic updates
  Future<void> sendVideo({String? path, PlatformFile? file}) async {
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
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'video',
        videoUrl: videoPath, // Local path temporarily
      );

      _pendingMessages.add(optimisticMessage);
      _messages.insert(0, optimisticMessage);
      notifyListeners();

      // Upload in background via orchestrator
      await _orchestrator.sendMessage(
        chatId: chatId,
        content: '', // Video messages don't need text content
        type: MessageType.video,
        mediaPath: videoPath,
      );

      // Remove from pending
      _pendingMessages.removeWhere((m) => m.id == tempId);
    } catch (e) {
      ReleaseLogger.error('Failed to send video: $e');
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

    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
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

  /// Delete a message (optimistic delete)
  /// ✅ Usa nuevo servicio atómico DeleteMessageService
  Future<bool> deleteMessage(String messageId, Timestamp? timestamp) async {
    ReleaseLogger.log('Deleting message $messageId from chat $chatId');

    // 1. ✅ Optimistic: Remove from UI immediately
    _messages.removeWhere((m) => m.id == messageId);
    _pendingMessages.removeWhere((m) => m.id == messageId);
    notifyListeners();

    // 2. ✅ Remove from local cache
    await MessageCacheService().deleteMessage(chatId, messageId);

    try {
      // 3. ✅ Delete using new atomic service
      final result = await _deleteMessageService.deleteForMe(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      if (result.success) {
        ReleaseLogger.log('Message $messageId deleted successfully');
      } else {
        ReleaseLogger.error('Failed to delete message: ${result.message}');
      }
      return result.success;
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
    _favoritesSubscription?.cancel();  // ✅ NEW
    _reactionsSubscription?.cancel();  // ✅ NEW: Cancel reactions stream

    // Clear state
    _messages.clear();
    _pendingMessages.clear();
    _isInitialized = false;

    super.dispose();

    ReleaseLogger.log('ChatController disposed for chat $chatId');
  }
}