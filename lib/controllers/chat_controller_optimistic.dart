import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:talia/services/network_status_service.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../services/sound_service.dart';
import '../services/user_profile_cache_service.dart';
import '../services/block_service.dart';
import '../services/chat/message_sending_service.dart';
import '../services/chat/message_pagination_service.dart';
import '../services/chat/message_actions_service.dart';
import '../services/chat/chat_state_service.dart';

/// Controller optimista para chat individual (REFACTORIZADO)
///
/// Implementa:
/// - Optimistic updates: mensajes aparecen instantáneamente
/// - Cache local con Hive
/// - Fetch on-demand (solo cuando llegan notificaciones)
/// - Queue de mensajes offline
/// - Listener en tiempo real para mensajes nuevos
///
/// NUEVA ARQUITECTURA:
/// - Usa servicios especializados para cada responsabilidad
/// - Solo coordina entre servicios
/// - Mantiene lógica del listener de mensajes en tiempo real
class ChatControllerOptimistic extends ChangeNotifier {
  final String chatId;
  final String contactId;
  final String contactName;

  // Core dependencies
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  // Services especializados (NUEVO)
  final MessageSendingService _sendingService;
  final MessagePaginationService _paginationService;
  final MessageActionsService _actionsService;
  final ChatStateService _stateService;

  // Services compartidos
  final NotificationService _notificationService;
  final TypingIndicatorService _typingService;
  final SoundService _soundService;
  final UserProfileCacheService _userProfileCache;
  final BlockService _blockService;

  // Subscripciones
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _messagesSubscription;

  // Estado de carga
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  bool _hasLoadedInitialMessages = false;
  bool get hasLoadedInitialMessages => _hasLoadedInitialMessages;

  bool _isLoadingMore = false;
  bool get isLoadingMore => _isLoadingMore;

  // Estado del contacto
  String _contactPhotoURL = '';
  bool _contactIsOnline = false;

  // Estado de bloqueo
  bool _isBlocked = false;
  bool _isBlockedBy = false;

  bool get isBlocked => _isBlocked;
  bool get isBlockedBy => _isBlockedBy;

  // Listener initialization flag
  bool _listenerInitialized = false;

  // ID único del controller
  late final String _controllerId;

  // Variables para video optimista
  String? _currentOptimisticVideoId;

  ChatControllerOptimistic({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    MessageSendingService? sendingService,
    MessagePaginationService? paginationService,
    MessageActionsService? actionsService,
    ChatStateService? stateService,
    NotificationService? notificationService,
    TypingIndicatorService? typingService,
    SoundService? soundService,
    UserProfileCacheService? userProfileCache,
    BlockService? blockService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _sendingService = sendingService ?? MessageSendingService(),
       _paginationService = paginationService ?? MessagePaginationService(),
       _actionsService = actionsService ?? MessageActionsService(),
       _stateService = stateService ?? ChatStateService(),
       _notificationService = notificationService ?? NotificationService(),
       _typingService = typingService ?? TypingIndicatorService(),
       _soundService = soundService ?? SoundService(),
       _userProfileCache = userProfileCache ?? UserProfileCacheService(),
       _blockService = blockService ?? BlockService() {
    _controllerId = DateTime.now().millisecondsSinceEpoch.toString().substring(
      8,
    );
    print('🏗️ [Controller-$_controllerId] Creado para chat: $chatId');
  }

  String get currentUserId => _auth.currentUser?.uid ?? '';
  String get contactPhotoURL => _contactPhotoURL;
  bool get contactIsOnline => _contactIsOnline;

  // Exponer mensajes del state service
  List<ChatMessage> get messages => _stateService.messages;
  bool get hasMoreMessages => _paginationService.hasMoreMessages;

  /// Inicializar el controller
  Future<void> initialize() async {
    print('🔄 [Controller-$_controllerId] Inicializando...');
    await _loadContactInfo();
    await _loadCachedMessages();
    await _loadFirestoreMessages();
    _setupNotificationListener();
    _setupMessagesListener();
    setupBlockListeners();
    print('✅ [Controller-$_controllerId] Inicialización completa');
  }

  /// Configurar listeners para estado de bloqueo
  void setupBlockListeners() {
    _blockService.isBlockedStream(contactId).listen((isBlocked) {
      _isBlocked = isBlocked;
      notifyListeners();
    });

    _blockService.isBlockedByStream(contactId).listen((isBlockedBy) {
      _isBlockedBy = isBlockedBy;
      notifyListeners();
    });
  }

  /// Marcar el chat como leído
  Future<void> markChatAsRead() async {
    await _actionsService.markMessagesAsRead(
      chatId: chatId,
      currentUserId: currentUserId,
    );
  }

  /// Marcar un solo mensaje como leído inmediatamente (sin verificar configuración)
  Future<void> _markSingleMessageAsRead(String messageId) async {
    try {
      final messageRef = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();
      if (!messageDoc.exists) return;

      final data = messageDoc.data() as Map<String, dynamic>;
      final readBy = List<String>.from(data['readBy'] ?? []);

      if (!readBy.contains(currentUserId)) {
        readBy.add(currentUserId);
        await messageRef.update({
          'isRead': true,
          'readBy': readBy,
          'readAt_$currentUserId': FieldValue.serverTimestamp(),
        });
        print('✅ [AutoRead] Mensaje $messageId marcado como leído');
      }
    } catch (e) {
      print('❌ [AutoRead] Error marcando mensaje como leído: $e');
    }
  }

  /// Cargar información del contacto
  Future<void> _loadContactInfo() async {
    try {
      final userDoc = await _firestore.collection('users').doc(contactId).get();
      final userData = userDoc.data();
      if (userData != null) {
        _contactPhotoURL = userData['photoURL'] ?? '';
        _contactIsOnline = userData['isOnline'] ?? false;
      }
    } catch (e) {
      print('❌ Error cargando info del contacto: $e');
    }
  }

  /// Cargar mensajes del cache
  Future<void> _loadCachedMessages() async {
    final cachedMessages = await _paginationService.loadMessagesFromCache(
      chatId: chatId,
    );

    if (cachedMessages.isNotEmpty) {
      _stateService.replaceAllMessages(cachedMessages);
      notifyListeners();
    }
  }

  /// Cargar mensajes iniciales de Firestore
  Future<void> _loadFirestoreMessages() async {
    if (_hasLoadedInitialMessages) return;

    _isLoading = true;
    notifyListeners();

    try {
      final firestoreMessages = await _paginationService.loadInitialMessages(
        chatId: chatId,
        currentUserId: currentUserId,
      );

      await _stateService.addMessages(
        chatId: chatId,
        newMessages: firestoreMessages,
        currentUserId: currentUserId,
      );

      _hasLoadedInitialMessages = true;
      print('📥 Cargados ${firestoreMessages.length} mensajes de Firestore');
    } catch (e) {
      print('❌ Error cargando mensajes: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cargar más mensajes antiguos (paginación)
  Future<void> loadMoreMessages() async {
    if (_isLoadingMore || !hasMoreMessages) {
      print('📄 No se pueden cargar más mensajes');
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    try {
      final moreMessages = await _paginationService.loadMoreMessages(
        chatId: chatId,
        currentUserId: currentUserId,
      );

      await _stateService.addMessages(
        chatId: chatId,
        newMessages: moreMessages,
        currentUserId: currentUserId,
      );

      print('📄 Cargados ${moreMessages.length} mensajes adicionales');
    } catch (e) {
      print('❌ Error cargando más mensajes: $e');
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  /// Configurar listener en tiempo real para nuevos mensajes
  void _setupMessagesListener() {
    var query = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(100);

    _messagesSubscription = query.snapshots().listen(
      (snapshot) {
        if (!_listenerInitialized) {
          _listenerInitialized = true;
          print('👂 [Realtime] Listener inicializado');
          return;
        }

        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added ||
              change.type == DocumentChangeType.modified) {
            final newMessage = ChatMessage.fromFirestore(
              change.doc,
              currentUserId: currentUserId,
            );

            _handleRealtimeMessage(newMessage, change.type);
          }
        }
      },
      onError: (error) {
        if (error.toString().contains('permission-denied')) {
          print('💬 [Realtime] Chat vacío, esperando primer mensaje...');
        } else {
          print('❌ [Realtime] Error: $error');
        }
      },
    );

    print('👂 [Realtime] Listener configurado');
  }

  /// Manejar mensaje del listener en tiempo real
  void _handleRealtimeMessage(
    ChatMessage newMessage,
    DocumentChangeType changeType,
  ) {
    // Marcar inmediatamente como leído si es un mensaje nuevo del contacto
    if (changeType == DocumentChangeType.added &&
        newMessage.senderId != currentUserId &&
        !newMessage.isRead) {
      print('👁️ [AutoRead] Marcando mensaje ${newMessage.id} como leído inmediatamente');
      _markSingleMessageAsRead(newMessage.id);
    }

    // Filtrar mensajes del contacto sin moderación
    if (newMessage.senderId != currentUserId) {
      if (newMessage.moderationStatus != ModerationStatus.approved &&
          newMessage.moderationStatus != ModerationStatus.blocked) {
        print('🔒 Ignorando mensaje pendiente: ${newMessage.id}');
        return;
      }
    }

    // Caso especial: Mensaje bloqueado propio
    if (newMessage.senderId == currentUserId &&
        newMessage.moderationStatus == ModerationStatus.blocked) {
      _handleBlockedOwnMessage(newMessage);
      return;
    }

    // Ignorar mensajes propios nuevos (ya en cache)
    if (newMessage.senderId == currentUserId &&
        changeType == DocumentChangeType.added) {
      print('⏭️ Ignorando mensaje propio nuevo: ${newMessage.id}');
      return;
    }

    // Actualizar mensaje existente
    if (_stateService.messageExists(newMessage.id)) {
      if (changeType == DocumentChangeType.modified) {
        print('🔄 Actualizando mensaje: ${newMessage.id}');
        _stateService.updateMessage(
          chatId: chatId,
          oldId: newMessage.id,
          newMessage: newMessage,
        );
        notifyListeners();
      }
      return;
    }

    // Filtrar por clearedAt
    final clearedAt = _paginationService.clearedAtTimestamp;
    if (clearedAt != null && newMessage.timestamp != null) {
      if (newMessage.timestamp!.compareTo(clearedAt) <= 0) {
        print('🧹 Ignorando mensaje anterior a limpieza');
        return;
      }
    }

    // Verificar duplicados
    if (_stateService.isDuplicateMessage(
      senderId: newMessage.senderId,
      timestamp: newMessage.timestamp,
      text: newMessage.text,
      imageUrl: newMessage.imageUrl,
    )) {
      print('🚫 Ignorando duplicado: ${newMessage.id}');
      return;
    }

    // Agregar nuevo mensaje
    print('✅ Nuevo mensaje del contacto: ${newMessage.id}');
    _stateService.addOptimisticMessage(newMessage);
    _stateService.updateLastMessageTimestamp(newMessage.timestamp);

    // Reproducir sonido y marcar como leído
    _soundService.playReceiveSound();
    _actionsService.markMessagesAsRead(
      chatId: chatId,
      currentUserId: currentUserId,
    );

    notifyListeners();
  }

  /// Manejar mensaje bloqueado propio
  void _handleBlockedOwnMessage(ChatMessage blockedMessage) {
    print('🚫 Mensaje bloqueado propio recibido: ${blockedMessage.id}');

    // Buscar mensaje optimista pendiente
    final pendingMsg = _stateService.pendingMessages.firstWhere(
      (m) => m.senderId == currentUserId && m.status == MessageStatus.sending,
      orElse: () => blockedMessage,
    );

    if (pendingMsg.id != blockedMessage.id) {
      _stateService.updateMessage(
        chatId: chatId,
        oldId: pendingMsg.id,
        newMessage: blockedMessage,
      );
      _stateService.removePendingMessage(pendingMsg.id);
      notifyListeners();
      print('✅ Mensaje optimista reemplazado por bloqueado');
    }
  }

  /// Configurar listener para notificaciones
  void _setupNotificationListener() {
    _notificationSubscription = _notificationService.chatNotificationTapStream
        .listen((data) {
          final notifChatId = data['chatId'] as String?;
          if (notifChatId == chatId) {
            loadMoreMessages();
          }
        });
  }

  /// Enviar mensaje de texto
  Future<void> sendTextMessage({
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    if (text.trim().isEmpty || currentUserId.isEmpty) return;

    // 1. Crear mensaje optimista
    final tempId = const Uuid().v4();
    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      text: text,
      replyTo: replyTo,
      type: 'text',
    );

    _stateService.addOptimisticMessage(optimisticMessage);
    notifyListeners();
    _sendingService.playSendSound();

    // 2. Enviar a Firestore
    try {
      final docId = await _sendingService.sendTextMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        text: text,
        contactId: contactId,
        replyTo: replyTo,
      );

      // 3. Actualizar mensaje optimista
      final sentMessage = optimisticMessage.copyWith(
        id: docId,
        status: MessageStatus.sent,
      );

      await _stateService.updateMessage(
        chatId: chatId,
        oldId: tempId,
        newMessage: sentMessage,
      );
      _stateService.removePendingMessage(tempId);
      notifyListeners();

      print('✅ Mensaje enviado: $text');
    } catch (e) {
      print('❌ Error enviando mensaje: $e');
      _handleSendError(tempId, optimisticMessage, e);
    }
  }

  /// Manejar error de envío
  void _handleSendError(
    String tempId,
    ChatMessage optimisticMessage,
    Object error,
  ) {
    if (!NetworkStatusService().isConnected) {
      _sendingService.enqueueOfflineMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        text: optimisticMessage.text ?? '',
        tempId: tempId,
        replyTo: optimisticMessage.replyTo,
      );

      final pendingMessage = optimisticMessage.copyWith(
        status: MessageStatus.sending,
      );
      _stateService.updateMessage(
        chatId: chatId,
        oldId: tempId,
        newMessage: pendingMessage,
      );
    } else {
      final errorMessage = optimisticMessage.copyWith(
        status: MessageStatus.error,
        retryCount: (optimisticMessage.retryCount ?? 0) + 1,
      );
      _stateService.updateMessage(
        chatId: chatId,
        oldId: tempId,
        newMessage: errorMessage,
      );
    }
    notifyListeners();
  }

  /// Enviar imagen
  Future<void> sendImage({required ImageSource source}) async {
    if (currentUserId.isEmpty) return;

    try {
      final docId = await _sendingService.sendImageMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        source: source,
      );
      print('✅ Imagen enviada: $docId');
    } catch (e) {
      print('❌ Error enviando imagen: $e');
      rethrow;
    }
  }

  /// Crear mensaje optimista de video
  void createOptimisticVideoMessage({
    required String videoPath,
    String? thumbnailPath,
  }) {
    if (currentUserId.isEmpty) return;

    final tempId = const Uuid().v4();
    _currentOptimisticVideoId = tempId;

    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      type: 'video',
      localPath: videoPath,
      imageUrl: thumbnailPath,
    );

    _stateService.addOptimisticMessage(optimisticMessage);
    notifyListeners();
    print('✅ Burbuja optimista de video creada: $tempId');
  }

  /// Procesar y subir video
  Future<void> processAndUploadVideo({
    required String videoPath,
    Function(String)? onShowMessage,
    VoidCallback? onHideMessage,
  }) async {
    if (currentUserId.isEmpty || _currentOptimisticVideoId == null) return;

    final tempId = _currentOptimisticVideoId!;

    try {
      onShowMessage?.call('Comprimiendo video...');

      final docId = await _sendingService.sendVideoMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        videoPath: videoPath,
      );

      onHideMessage?.call();

      final optimisticMsg = _stateService.getMessageById(tempId);
      if (optimisticMsg != null) {
        final sentMessage = optimisticMsg.copyWith(
          id: docId,
          status: MessageStatus.sent,
          localPath: null,
        );

        await _stateService.updateMessage(
          chatId: chatId,
          oldId: tempId,
          newMessage: sentMessage,
        );
        _stateService.removePendingMessage(tempId);
        _currentOptimisticVideoId = null;
        notifyListeners();
      }

      print('✅ Video enviado');
    } catch (e) {
      onHideMessage?.call();
      print('❌ Error enviando video: $e');

      final optimisticMsg = _stateService.getMessageById(tempId);
      if (optimisticMsg != null) {
        final errorMessage = optimisticMsg.copyWith(
          status: MessageStatus.error,
        );
        await _stateService.updateMessage(
          chatId: chatId,
          oldId: tempId,
          newMessage: errorMessage,
        );
      }
      _currentOptimisticVideoId = null;
      notifyListeners();
      rethrow;
    }
  }

  /// Enviar audio
  Future<void> sendAudio(String audioPath) async {
    if (currentUserId.isEmpty) return;

    try {
      await _sendingService.sendAudioMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        audioPath: audioPath,
      );
      print('✅ Audio enviado');
    } catch (e) {
      print('❌ Error enviando audio: $e');
      rethrow;
    }
  }

  /// Stream de indicador de escritura
  Stream<bool> watchTypingIndicator() {
    return _typingService.watchOtherUserTyping(chatId, contactId);
  }

  /// Establecer estado de escritura
  void setTyping(bool isTyping) {
    _typingService.setTyping(chatId, isTyping, isGroup: false);
  }

  /// Detener escritura
  void stopTyping() {
    _typingService.stopTyping();
  }

  /// Actualizar mensaje bloqueado
  Future<void> updateBlockedMessage(String messageId, String newText) async {
    if (currentUserId.isEmpty) return;

    await _sendingService.updateBlockedMessage(
      chatId: chatId,
      messageId: messageId,
      newText: newText,
    );
  }

  /// Eliminar mensaje
  Future<bool> deleteMessage(String messageId, Timestamp? timestamp) async {
    final success = await _actionsService.deleteMessage(
      chatId: chatId,
      messageId: messageId,
      currentUserId: currentUserId,
      timestamp: timestamp,
    );

    if (success) {
      _stateService.removeMessage(messageId);
      notifyListeners();
    }

    return success;
  }

  /// Limpiar chat
  Future<bool> clearChat() async {
    final success = await _actionsService.clearChat(
      chatId: chatId,
      currentUserId: currentUserId,
    );

    if (success) {
      _stateService.clear();
      notifyListeners();
    }

    return success;
  }

  /// Stream del estado online del contacto
  Stream<DocumentSnapshot> watchContactStatus() {
    return _firestore.collection('users').doc(contactId).snapshots();
  }

  @override
  void dispose() {
    print('🗑️ [Controller-$_controllerId] Disposing...');
    stopTyping();
    _notificationSubscription?.cancel();
    _messagesSubscription?.cancel();
    super.dispose();
  }
}
