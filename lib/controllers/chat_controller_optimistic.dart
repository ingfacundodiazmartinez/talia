import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:talia/services/network_status_service.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../utils/release_logger.dart';
import '../services/sound_service.dart';
import '../services/block_service.dart';
import '../services/chat/message_sending_service.dart';
import '../services/chat/message_pagination_service.dart';
import '../services/chat/message_actions_service.dart';
import '../services/chat/chat_state_service.dart';
import '../services/audio_processing_service.dart';

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
       _blockService = blockService ?? BlockService() {
    _controllerId = DateTime.now().millisecondsSinceEpoch.toString().substring(
      8,
    );
    ReleaseLogger.log('Controller-$_controllerId creado para chat: $chatId', tag: 'ChatController');
  }

  String get currentUserId => _auth.currentUser?.uid ?? '';
  String get contactPhotoURL => _contactPhotoURL;
  bool get contactIsOnline => _contactIsOnline;

  // Exponer mensajes del state service
  List<ChatMessage> get messages => _stateService.messages;
  bool get hasMoreMessages => _paginationService.hasMoreMessages;

  /// Inicializar el controller
  Future<void> initialize() async {
    ReleaseLogger.log('🔄[Controller-$_controllerId] Inicializando...');
    await _loadContactInfo();
    await _loadCachedMessages();
    await _loadFirestoreMessages();
    _setupNotificationListener();
    _setupMessagesListener();
    setupBlockListeners();
    ReleaseLogger.log('✅[Controller-$_controllerId] Inicialización completa');
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
      ReleaseLogger.error('❌Error cargando info del contacto: $e');
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
      ReleaseLogger.log('📥Cargados ${firestoreMessages.length} mensajes de Firestore');
    } catch (e) {
      ReleaseLogger.error('❌Error cargando mensajes: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cargar más mensajes antiguos (paginación)
  Future<void> loadMoreMessages() async {
    if (_isLoadingMore || !hasMoreMessages) {
      ReleaseLogger.log('📄No se pueden cargar más mensajes');
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

      ReleaseLogger.log('📄Cargados ${moreMessages.length} mensajes adicionales');
    } catch (e) {
      ReleaseLogger.error('❌Error cargando más mensajes: $e');
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
          ReleaseLogger.log('👂[Realtime] Listener inicializado');
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
          } else if (change.type == DocumentChangeType.removed) {
            // ✅ FIXED: Handle message deletion sync
            final messageId = change.doc.id;
            _handleMessageDeleted(messageId);
          }
        }
      },
      onError: (error) {
        if (error.toString().contains('permission-denied')) {
          ReleaseLogger.log('💬[Realtime] Chat vacío, esperando primer mensaje...');
        } else {
          ReleaseLogger.error('❌[Realtime] Error: $error');
        }
      },
    );

    ReleaseLogger.log('👂[Realtime] Listener configurado');
  }

  /// Manejar mensaje del listener en tiempo real
  void _handleRealtimeMessage(
    ChatMessage newMessage,
    DocumentChangeType changeType,
  ) {
    // Filtrar mensajes del contacto sin moderación
    if (newMessage.senderId != currentUserId) {
      if (newMessage.moderationStatus != ModerationStatus.approved &&
          newMessage.moderationStatus != ModerationStatus.blocked) {
        ReleaseLogger.log('🔒Ignorando mensaje pendiente: ${newMessage.id}');
        return;
      }
    }

    // Caso especial: Mensaje bloqueado propio
    if (newMessage.senderId == currentUserId &&
        newMessage.moderationStatus == ModerationStatus.blocked) {
      _handleBlockedOwnMessage(newMessage);
      return;
    }

    // Actualizar mensaje existente
    if (_stateService.messageExists(newMessage.id)) {
      if (changeType == DocumentChangeType.modified) {
        ReleaseLogger.log('🔄Actualizando mensaje: ${newMessage.id}');
        _stateService.updateMessage(
          chatId: chatId,
          oldId: newMessage.id,
          newMessage: newMessage,
        );
        notifyListeners();
      }
      return;
    }

    // Si es mensaje propio nuevo, usar addMessages para que maneje la lógica de reemplazo de pendientes
    if (newMessage.senderId == currentUserId &&
        changeType == DocumentChangeType.added) {
      ReleaseLogger.log('📩Procesando mensaje propio desde Firestore: ${newMessage.id}');
      _stateService.addMessages(
        chatId: chatId,
        newMessages: [newMessage],
        currentUserId: currentUserId,
      );
      notifyListeners();
      return;
    }

    // Filtrar por clearedAt
    final clearedAt = _paginationService.clearedAtTimestamp;
    if (clearedAt != null && newMessage.timestamp != null) {
      if (newMessage.timestamp!.compareTo(clearedAt) <= 0) {
        ReleaseLogger.log('🧹Ignorando mensaje anterior a limpieza');
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
      ReleaseLogger.log('🚫Ignorando duplicado: ${newMessage.id}');
      return;
    }

    // Agregar nuevo mensaje
    ReleaseLogger.log('✅Nuevo mensaje del contacto: ${newMessage.id}');
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
    ReleaseLogger.log('🚫Mensaje bloqueado propio recibido: ${blockedMessage.id}');

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
      ReleaseLogger.log('✅Mensaje optimista reemplazado por bloqueado');
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

    // 2. Enviar a Firestore con localId
    try {
      final docId = await _sendingService.sendTextMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        text: text,
        contactId: contactId,
        replyTo: replyTo,
        localId: tempId, // ✅ Enviar tempId como localId
      );
      ReleaseLogger.log('✅Mensaje enviado');

      // 3. Actualizar mensaje optimista
      final sentMessage = optimisticMessage.copyWith(
        id: docId,
        status: MessageStatus.sent,
      );
      ReleaseLogger.log('✅Mensaje optimista actualizado');

      await _stateService.updateMessage(
        chatId: chatId,
        oldId: tempId,
        newMessage: sentMessage,
      );

      ReleaseLogger.log('✅Mensaje optimista reemplazado por enviado');
      _stateService.removePendingMessage(tempId);
      ReleaseLogger.log('✅Mensaje optimista removido de pendientes');
      notifyListeners();
      ReleaseLogger.log('✅UI notificada de actualización de mensaje');

      ReleaseLogger.log('✅Mensaje enviado: $text');
    } catch (e) {
      ReleaseLogger.error('❌Error enviando mensaje 1: $e');
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
      ReleaseLogger.log('✅Imagen enviada: $docId');
    } catch (e) {
      ReleaseLogger.error('❌Error enviando imagen: $e');
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
    ReleaseLogger.log('✅Burbuja optimista de video creada: $tempId');
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

      ReleaseLogger.log('✅Video enviado');
    } catch (e) {
      onHideMessage?.call();
      ReleaseLogger.error('❌Error enviando video: $e');

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

  /// ID del mensaje de audio optimista actual
  String? _currentOptimisticAudioId;

  /// Crear burbuja optimista de audio inmediatamente
  Future<void> createOptimisticAudioBubble(String audioPath) async {
    if (currentUserId.isEmpty) return;

    final tempId = const Uuid().v4();
    _currentOptimisticAudioId = tempId;

    // Procesar waveform inmediatamente
    ReleaseLogger.log('🎵Procesando waveform del audio...');
    final AudioProcessingService audioProcessing = AudioProcessingService();
    final File audioFile = File(audioPath);
    final waveformData = await audioProcessing.extractWaveform(audioFile);
    ReleaseLogger.log('✅Waveform procesado: ${waveformData.length} puntos');

    // Crear mensaje optimista con waveform real
    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      audioUrl: audioPath, // Path local temporal
      localPath: audioPath,
      type: 'audio',
      waveformData: waveformData, // ✅ Waveform real procesado
    );

    _stateService.addOptimisticMessage(optimisticMessage);
    notifyListeners();
    ReleaseLogger.log('✅Burbuja optimista de audio creada con waveform: $tempId');
  }

  /// Procesar y subir audio
  Future<void> processAndUploadAudio(String audioPath, {bool isAiGenerated = false}) async {
    if (currentUserId.isEmpty || _currentOptimisticAudioId == null) return;

    final tempId = _currentOptimisticAudioId!;

    try {
      // El waveform ya fue procesado, ahora solo subimos
      final docId = await _sendingService.sendAudioMessage(
        chatId: chatId,
        currentUserId: currentUserId,
        audioPath: audioPath,
        isAiGenerated: isAiGenerated,
      );

      // Actualizar mensaje optimista a sent
      final optimisticMsg = _stateService.pendingMessages.firstWhere(
        (m) => m.id == tempId,
        orElse: () => throw Exception('Mensaje optimista no encontrado'),
      );

      final sentMessage = optimisticMsg.copyWith(
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

      ReleaseLogger.log('✅Audio subido y mensaje actualizado: $docId');
      _currentOptimisticAudioId = null;
    } catch (e) {
      ReleaseLogger.error('❌Error subiendo audio: $e');

      // Marcar mensaje como error
      final optimisticMsg = _stateService.pendingMessages.firstWhere(
        (m) => m.id == tempId,
        orElse: () => throw Exception('Mensaje optimista no encontrado'),
      );

      final errorMessage = optimisticMsg.copyWith(
        status: MessageStatus.error,
      );

      await _stateService.updateMessage(
        chatId: chatId,
        oldId: tempId,
        newMessage: errorMessage,
      );
      notifyListeners();

      _currentOptimisticAudioId = null;
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

  /// Handle message deletion from real-time listener
  /// This is called when another user deletes a message from Firestore
  void _handleMessageDeleted(String messageId) {
    try {
      ReleaseLogger.log('🗑️ [Sync] Mensaje eliminado remotamente: $messageId', tag: 'ChatController');

      // Remove from local state and cache (handled internally by _stateService)
      _stateService.removeMessage(messageId);

      // Notify UI to update
      notifyListeners();

      ReleaseLogger.log('✅ [Sync] Mensaje eliminado de UI y cache local', tag: 'ChatController');
    } catch (e) {
      ReleaseLogger.error('❌ [Sync] Error eliminando mensaje $messageId: $e', tag: 'ChatController');
    }
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

  /// Obtener datos del usuario actual para manejo de errores
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return null;

      final userDoc = await _firestore.collection('users').doc(currentUserId).get();
      if (userDoc.exists) {
        return userDoc.data();
      }
      return null;
    } catch (e) {
      // ReleaseLogger.error('Error obteniendo datos del usuario: $e', tag: 'ChatController');
      return null;
    }
  }


  @override
  void dispose() {
    // ReleaseLogger.log('Disposing ChatController-$_controllerId', tag: 'ChatController');
    stopTyping();
    _notificationSubscription?.cancel();
    _messagesSubscription?.cancel();
    super.dispose();
  }
}
