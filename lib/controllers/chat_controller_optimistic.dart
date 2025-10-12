import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../services/media_service.dart';
import '../services/media_compression_service.dart';
import '../services/message_cache_service.dart';
import '../services/sound_service.dart';

/// Controller optimista para chat individual
///
/// Implementa:
/// - Optimistic updates: mensajes aparecen instantáneamente
/// - Cache local con Hive
/// - Fetch on-demand (solo cuando llegan notificaciones)
/// - Queue de mensajes offline
/// - Batch update para mensajes vistos
class ChatControllerOptimistic extends ChangeNotifier {
  final String chatId;
  final String contactId;
  final String contactName;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final NotificationService _notificationService;
  final TypingIndicatorService _typingService;
  final MediaService _mediaService;
  final MessageCacheService _cacheService;
  final SoundService _soundService;

  // Lista de mensajes en memoria (optimistic + cache + firestore)
  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  // Queue de mensajes pendientes
  final List<ChatMessage> _pendingMessages = [];

  // Control de carga
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  bool _hasLoadedInitialMessages = false;
  bool get hasLoadedInitialMessages => _hasLoadedInitialMessages;

  // Estado del contacto
  String _contactPhotoURL = '';
  String _contactIsOnline = 'false';

  // Subscripción a notificaciones
  StreamSubscription? _notificationSubscription;

  // Subscripción a mensajes en tiempo real
  StreamSubscription? _messagesSubscription;

  // Timestamp del último mensaje cargado (para evitar duplicados)
  Timestamp? _lastMessageTimestamp;

  // Bandera para indicar si el listener ya se inicializó (para evitar duplicados)
  bool _listenerInitialized = false;

  // Timeout para marcar mensaje como error
  static const Duration _sendTimeout = Duration(seconds: 20);

  // ID único del controller para debugging
  late final String _controllerId;

  ChatControllerOptimistic({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    NotificationService? notificationService,
    TypingIndicatorService? typingService,
    MediaService? mediaService,
    MessageCacheService? cacheService,
    SoundService? soundService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _notificationService = notificationService ?? NotificationService(),
        _typingService = typingService ?? TypingIndicatorService(),
        _mediaService = mediaService ?? MediaService(),
        _cacheService = cacheService ?? MessageCacheService(),
        _soundService = soundService ?? SoundService() {
    _controllerId = DateTime.now().millisecondsSinceEpoch.toString().substring(8);
    print('🏗️ [Controller-$_controllerId] Creado para chat: $chatId');
  }

  String get currentUserId => _auth.currentUser?.uid ?? '';
  String get contactPhotoURL => _contactPhotoURL;
  String get contactIsOnline => _contactIsOnline;

  /// Inicializar el controller
  Future<void> initialize() async {
    print('🔄 [Controller-$_controllerId] Inicializando...');
    await _loadContactInfo();
    await _loadCachedMessages();
    await _loadFirestoreMessages();
    await _batchMarkAsRead();
    _setupNotificationListener();
    _setupMessagesListener(); // ✅ NUEVO: Escuchar mensajes en tiempo real
    print('✅ [Controller-$_controllerId] Inicialización completa');
  }

  /// Cargar información del contacto
  Future<void> _loadContactInfo() async {
    try {
      final userDoc = await _firestore.collection('users').doc(contactId).get();
      final userData = userDoc.data();
      if (userData != null) {
        _contactPhotoURL = userData['photoURL'] ?? '';
        _contactIsOnline = userData['isOnline']?.toString() ?? 'false';
      }
    } catch (e) {
      print('❌ [ChatController] Error cargando info del contacto: $e');
    }
  }

  /// Cargar mensajes del cache (instantáneo)
  Future<void> _loadCachedMessages() async {
    try {
      print('📦 [Controller-$_controllerId] Cargando cache... (_messages tiene ${_messages.length} mensajes)');
      final cachedMessages = await _cacheService.getMessages(chatId);
      if (cachedMessages.isNotEmpty) {
        int addedCount = 0;
        int skippedCount = 0;
        // Merge con mensajes existentes (evitar duplicados)
        for (final message in cachedMessages) {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index == -1) {
            _messages.add(message);
            addedCount++;
          } else {
            skippedCount++;
          }
        }
        _sortMessages();
        notifyListeners();
        print('📥 [Controller-$_controllerId] Cache: ${cachedMessages.length} en DB, $addedCount añadidos, $skippedCount duplicados. Total: ${_messages.length}');
      } else {
        print('📥 [Controller-$_controllerId] Cache vacío');
      }
    } catch (e) {
      print('❌ [Controller-$_controllerId] Error cargando cache: $e');
    }
  }

  /// Cargar mensajes de Firestore (solo la primera vez)
  Future<void> _loadFirestoreMessages() async {
    if (_hasLoadedInitialMessages) return;

    _isLoading = true;
    notifyListeners();

    try {
      // Obtener el timestamp de cuándo se limpió el chat (si existe)
      Timestamp? clearedAt;
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (chatDoc.exists) {
        final chatData = chatDoc.data();
        clearedAt = chatData?['clearedAt_$currentUserId'] as Timestamp?;
        if (clearedAt != null) {
          print('🧹 Chat limpiado en: ${clearedAt.toDate()}');
        }
      }

      final snapshot = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(50)
          .get();

      final firestoreMessages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc))
          .where((message) {
            // Filtrar mensajes anteriores al clearedAt
            if (clearedAt != null && message.timestamp != null) {
              return message.timestamp!.compareTo(clearedAt) > 0;
            }
            return true;
          })
          .toList();

      // Merge con mensajes del cache (evitar duplicados)
      int newCount = 0;
      int updatedCount = 0;
      int skippedCount = 0;
      for (final message in firestoreMessages) {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index == -1) {
          _messages.add(message);
          newCount++;
        } else {
          // ✅ OPTIMIZACIÓN: Si es mensaje propio ya en cache, solo actualizar status
          if (message.senderId == currentUserId) {
            final currentMessage = _messages[index];
            final updatedWithStatus = currentMessage.copyWith(
              status: message.status,
              timestamp: message.timestamp ?? currentMessage.timestamp,
            );
            _messages[index] = updatedWithStatus;
            skippedCount++;
          } else {
            // Para mensajes del contacto, actualizar completamente
            _messages[index] = message;
            updatedCount++;
          }
        }
      }

      print('📊 [ChatController] Merge completado: $newCount nuevos, $updatedCount actualizados, $skippedCount propios (solo status)');

      _sortMessages();
      _hasLoadedInitialMessages = true;

      // Guardar timestamp del último mensaje para el listener
      if (_messages.isNotEmpty && _messages.first.timestamp != null) {
        _lastMessageTimestamp = _messages.first.timestamp;
      }

      // Guardar en cache
      await _cacheService.saveMessages(chatId, _messages);

      print('📥 [ChatController] Cargados ${firestoreMessages.length} mensajes de Firestore');
    } catch (e) {
      print('❌ [ChatController] Error cargando mensajes: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// ✅ NUEVO: Configurar listener en tiempo real para nuevos mensajes
  void _setupMessagesListener() {
    // Escuchar TODOS los mensajes (sin filtro de timestamp)
    // El listener se encarga de detectar duplicados por ID
    var query = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(100); // Limitar a últimos 100 mensajes para performance

    _messagesSubscription = query.snapshots().listen(
      (snapshot) {
        // Ignorar el primer snapshot (contiene mensajes ya cargados)
        if (!_listenerInitialized) {
          _listenerInitialized = true;
          print('👂 [Realtime] Listener inicializado, ignorando mensajes existentes');
          return;
        }

        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final newMessage = ChatMessage.fromFirestore(change.doc);

            // ✅ OPTIMIZACIÓN: Ignorar mensajes propios del listener (ya están en cache)
            // Solo procesar mensajes del contacto
            if (newMessage.senderId == currentUserId) {
              print('⏭️ [Realtime] Ignorando mensaje propio del listener (ya en cache): ${newMessage.id}');
              continue;
            }

            // IMPORTANTE: Verificar que no exista ya (por ID)
            final existingIndex = _messages.indexWhere((m) => m.id == newMessage.id);

            if (existingIndex == -1) {
              // Es del CONTACTO: verificar que no sea duplicado antes de agregar
              final isDuplicate = newMessage.timestamp != null &&
                _messages.any((m) =>
                  m.senderId == newMessage.senderId &&
                  m.timestamp != null &&
                  (m.timestamp!.seconds == newMessage.timestamp!.seconds) &&
                  (m.text == newMessage.text || m.imageUrl == newMessage.imageUrl)
                );

              if (!isDuplicate) {
                print('✅ [Realtime] Nuevo mensaje del contacto: ${newMessage.id}');
                _messages.insert(0, newMessage);
                _lastMessageTimestamp = newMessage.timestamp;
                _cacheService.saveMessages(chatId, _messages);

                // Reproducir sonido de recepción
                _soundService.playReceiveSound();

                notifyListeners();
              } else {
                print('🚫 [Realtime] Ignorando duplicado del contacto: ${newMessage.id}');
              }
            } else {
              // El mensaje ya existe por ID - no hacer nada
              print('🚫 [Realtime] Mensaje ya existe (por ID): ${newMessage.id}');
            }
          } else if (change.type == DocumentChangeType.modified) {
            final updatedMessage = ChatMessage.fromFirestore(change.doc);
            final index = _messages.indexWhere((m) => m.id == updatedMessage.id);

            if (index != -1) {
              // Si es mensaje propio, solo actualizar el status (no todo el mensaje)
              if (updatedMessage.senderId == currentUserId) {
                print('🔄 [Realtime] Actualizando status de mensaje propio: ${updatedMessage.id}');
                final currentMessage = _messages[index];
                final updatedWithStatus = currentMessage.copyWith(
                  status: updatedMessage.status,
                  timestamp: updatedMessage.timestamp ?? currentMessage.timestamp,
                );
                _messages[index] = updatedWithStatus;
                _cacheService.saveMessage(chatId, updatedWithStatus);
              } else {
                // Para mensajes del contacto, actualizar completamente
                print('🔄 [Realtime] Mensaje del contacto actualizado: ${updatedMessage.id}');
                _messages[index] = updatedMessage;
                _cacheService.saveMessage(chatId, updatedMessage);
              }
              notifyListeners();
            }
          }
        }
      },
      onError: (error) {
        print('❌ [Realtime] Error en listener de mensajes: $error');
      },
    );

    print('👂 [Realtime] Listener de mensajes configurado');
  }

  /// Configurar listener para notificaciones de mensajes nuevos
  void _setupNotificationListener() {
    // Escuchar cuando llega una notificación de mensaje para este chat
    _notificationSubscription = _notificationService.chatNotificationTapStream.listen((data) {
      final notifChatId = data['chatId'] as String?;
      if (notifChatId == chatId) {
        _fetchNewMessages();
      }
    });
  }

  /// Fetch de mensajes nuevos cuando llega notificación
  Future<void> _fetchNewMessages() async {
    try {
      // Obtener el timestamp del mensaje más reciente
      DateTime? lastTimestamp;
      if (_messages.isNotEmpty) {
        lastTimestamp = _messages.first.effectiveTimestamp;
      }

      Query query = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(10);

      if (lastTimestamp != null) {
        query = query.where('timestamp', isGreaterThan: Timestamp.fromDate(lastTimestamp));
      }

      final snapshot = await query.get();
      final newMessages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc))
          .toList();

      if (newMessages.isNotEmpty) {
        int addedCount = 0;
        for (final message in newMessages) {
          // ✅ OPTIMIZACIÓN: Ignorar mensajes propios (ya están en cache)
          if (message.senderId == currentUserId) {
            print('⏭️ [Fetch] Ignorando mensaje propio: ${message.id}');
            continue;
          }

          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index == -1) {
            _messages.insert(0, message);
            addedCount++;
          }
        }

        if (addedCount > 0) {
          _sortMessages();
          await _cacheService.saveMessages(chatId, _messages);
          notifyListeners();
          print('📥 [ChatController] Fetched $addedCount nuevos mensajes del contacto');
        }
      }
    } catch (e) {
      print('❌ [ChatController] Error fetching mensajes nuevos: $e');
    }
  }

  /// Enviar mensaje de texto (OPTIMISTIC)
  Future<void> sendTextMessage({
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    if (text.trim().isEmpty || currentUserId.isEmpty) return;

    // 1. Crear mensaje optimista con ID temporal PRIMERO (UX inmediata)
    final tempId = const Uuid().v4();
    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      text: text,
      replyTo: replyTo,
      type: 'text',
    );

    // 2. Agregar a la lista inmediatamente (UI se actualiza)
    _messages.insert(0, optimisticMessage);
    _pendingMessages.add(optimisticMessage);
    _sortMessages();
    notifyListeners();

    // 2.5. Reproducir sonido de envío
    _soundService.playSendSound();

    // 3. 🔒 MODERACIÓN EN PARALELO: Verificar si el mensaje cumple con las normas
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      final moderationEnabled = chatDoc.data()?['moderationEnabled'] ?? false;

      if (moderationEnabled) {
        print('🔒 Chat con moderación activa, verificando mensaje en background...');

        final functions = FirebaseFunctions.instance;
        final result = await functions.httpsCallable('checkMessageBeforeSending').call({
          'chatId': chatId,
          'text': text,
          'type': 'text',
        });

        final approved = result.data['approved'] as bool;

        if (!approved) {
          final reason = result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
          print('🚫 Mensaje bloqueado: $reason');

          // Eliminar mensaje optimista
          _messages.removeWhere((m) => m.id == tempId);
          _pendingMessages.removeWhere((m) => m.id == tempId);
          await _cacheService.deleteMessage(chatId, tempId);
          notifyListeners();

          // Lanzar excepción para que el error sea manejado por el UI
          throw Exception(reason);
        }

        print('✅ Mensaje aprobado por moderación');
      }
    } catch (e) {
      // Si es error de moderación, propagarlo (mensaje ya fue eliminado arriba)
      if (e.toString().contains('moderacion') ||
          e.toString().toLowerCase().contains('inapropiado') ||
          e.toString().toLowerCase().contains('bullying') ||
          e.toString().toLowerCase().contains('violencia') ||
          e.toString().toLowerCase().contains('lenguaje') ||
          e.toString().toLowerCase().contains('acoso')) {
        rethrow;
      }
      // Error de red o similar, continuar con el envío
      print('⚠️ Error en moderación background (continuando): $e');
    }

    // 3. Guardar en cache
    await _cacheService.saveMessage(chatId, optimisticMessage);

    // 4. Intentar enviar a Firestore
    try {
      final messageData = {
        'senderId': currentUserId,
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      };

      if (replyTo != null) {
        messageData['replyTo'] = replyTo;
      }

      // Enviar con timeout
      final docRef = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(messageData)
          .timeout(_sendTimeout);

      // 5. Mensaje enviado exitosamente
      final sentMessage = optimisticMessage.copyWith(
        id: docRef.id,
        status: MessageStatus.sent,
      );

      _updateMessage(tempId, sentMessage);
      _pendingMessages.removeWhere((m) => m.id == tempId);

      // Actualizar documento del chat
      await _updateChatDocument(text);

      // Enviar notificación
      await _sendNotification(text);

      print('✅ [ChatController] Mensaje enviado: $text');
    } catch (e) {
      print('❌ [ChatController] Error enviando mensaje: $e');

      // Marcar como error
      final errorMessage = optimisticMessage.copyWith(
        status: MessageStatus.error,
        retryCount: (optimisticMessage.retryCount ?? 0) + 1,
      );

      _updateMessage(tempId, errorMessage);
      await _cacheService.updateMessageStatus(chatId, tempId, MessageStatus.error);
    }
  }

  /// Reintentar envío de mensaje con error
  Future<void> retryMessage(String messageId) async {
    final message = _messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw Exception('Mensaje no encontrado'),
    );

    if (message.status != MessageStatus.error) return;

    // Marcar como enviando nuevamente
    final retryingMessage = message.copyWith(
      status: MessageStatus.sending,
      retryCount: (message.retryCount ?? 0) + 1,
    );

    _updateMessage(messageId, retryingMessage);
    notifyListeners();

    // Reintentar envío
    if (message.text != null) {
      await sendTextMessage(
        text: message.text!,
        replyTo: message.replyTo,
      );
    }

    // Eliminar mensaje viejo con error
    _messages.removeWhere((m) => m.id == messageId);
    await _cacheService.deleteMessage(chatId, messageId);
  }

  /// Actualizar mensaje en la lista
  void _updateMessage(String oldId, ChatMessage newMessage) async {
    final index = _messages.indexWhere((m) => m.id == oldId);
    if (index != -1) {
      _messages[index] = newMessage;
      _sortMessages();

      // Si el ID cambió (de temporal a real), eliminar el mensaje viejo del cache
      if (oldId != newMessage.id) {
        print('🔄 [Controller-$_controllerId] Actualizando mensaje: $oldId -> ${newMessage.id}');
        await _cacheService.deleteMessage(chatId, oldId);
      }

      await _cacheService.saveMessage(chatId, newMessage);
      notifyListeners();
    }
  }

  /// Ordenar mensajes (más reciente primero)
  void _sortMessages() {
    _messages.sort((a, b) {
      final aTime = a.effectiveTimestamp;
      final bTime = b.effectiveTimestamp;
      return bTime.compareTo(aTime);
    });
  }

  /// Batch update: Marcar todos los mensajes como leídos
  Future<void> _batchMarkAsRead() async {
    try {
      if (currentUserId.isEmpty) return;

      final batch = _firestore.batch();

      // Marcar contador de no leídos en 0
      final chatRef = _firestore.collection('chats').doc(chatId);
      batch.update(chatRef, {'unreadCount_$currentUserId': 0});

      // Commit batch
      await batch.commit();

      print('✅ [ChatController] Mensajes marcados como leídos (batch)');
    } catch (e) {
      print('❌ [ChatController] Error en batch update: $e');
    }
  }

  /// Actualizar documento del chat
  Future<void> _updateChatDocument(String lastMessage) async {
    print('📊 [ChatController] Incrementando unreadCount_$contactId para chat: $chatId');
    await _firestore.collection('chats').doc(chatId).set({
      'participants': [currentUserId, contactId],
      'lastMessage': lastMessage,
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastMessageSender': currentUserId,
      'deletedBy': [],
      // Incrementar contador de no leídos del destinatario
      'unreadCount_$contactId': FieldValue.increment(1),
    }, SetOptions(merge: true));
  }

  /// Enviar notificación al contacto
  Future<void> _sendNotification(String messageText) async {
    try {
      final currentUserDoc =
          await _firestore.collection('users').doc(currentUserId).get();
      final userData = currentUserDoc.data();
      final senderName = userData?['name'] ?? 'Usuario';
      final senderPhotoUrl = userData?['photoURL'];

      await _notificationService.sendChatMessageNotification(
        recipientId: contactId,
        senderId: currentUserId,
        senderName: senderName,
        senderPhotoUrl: senderPhotoUrl,
        messageText: messageText,
        chatId: chatId,
        isGroup: false,
      );

      print('✅ [ChatController] Notificación creada en Firestore');
    } catch (e) {
      print('⚠️ [ChatController] Error enviando notificación: $e');
    }
  }

  /// Stream del estado online del contacto
  Stream<DocumentSnapshot> watchContactStatus() {
    return _firestore.collection('users').doc(contactId).snapshots();
  }

  /// Enviar imagen (OPTIMISTIC)
  Future<void> sendImage({required ImageSource source}) async {
    if (currentUserId.isEmpty) return;

    try {
      // 1. Seleccionar imagen
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1920,
        maxHeight: 1920,
      );

      if (image == null) return; // Usuario canceló

      print('📷 Imagen seleccionada: ${image.path}');

      // 2. Comprimir imagen
      final MediaCompressionService compressionService = MediaCompressionService();
      final File originalFile = File(image.path);

      print('⏳ Comprimiendo imagen...');
      final File? compressedFile = await compressionService.compressImage(originalFile);

      if (compressedFile == null) {
        print('❌ No se pudo comprimir la imagen (muy grande o error)');
        throw Exception('La imagen es muy grande o no se pudo comprimir');
      }

      final sizeMB = await compressionService.getFileSizeMB(compressedFile);
      print('✅ Imagen comprimida: ${sizeMB.toStringAsFixed(2)} MB');

      // 3. Crear mensaje optimista CON localPath
      final tempId = const Uuid().v4();
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'image',
        localPath: compressedFile.path, // Path local para preview
      );

      _messages.insert(0, optimisticMessage);
      _pendingMessages.add(optimisticMessage);
      notifyListeners();

      // 3.5. Reproducir sonido de envío
      _soundService.playSendSound();

      // 4. Subir imagen comprimida
      final imageUrl = await _mediaService.uploadImageFile(
        imageFile: compressedFile,
        chatId: chatId,
        userId: currentUserId,
      );

      if (imageUrl == null) throw Exception('Error subiendo imagen');

      // 5. Enviar a Firestore
      final docRef = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'imageUrl': imageUrl,
            'type': 'image',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          })
          .timeout(_sendTimeout);

      // 6. Actualizar mensaje
      final sentMessage = optimisticMessage.copyWith(
        id: docRef.id,
        imageUrl: imageUrl,
        status: MessageStatus.sent,
        localPath: null, // Limpiar localPath ya que tenemos URL
      );

      _updateMessage(tempId, sentMessage);
      _pendingMessages.removeWhere((m) => m.id == tempId);

      await _updateChatDocument('📷 Imagen');
      await _sendNotification('📷 Imagen');
      print('✅ [ChatController] Imagen enviada');
    } catch (e) {
      print('❌ [ChatController] Error enviando imagen: $e');
      // Buscar el mensaje pendiente
      final pendingMsg = _pendingMessages.firstWhere(
        (m) => m.senderId == currentUserId && m.type == 'image',
        orElse: () => _messages.first,
      );
      final errorMessage = pendingMsg.copyWith(status: MessageStatus.error);
      _updateMessage(pendingMsg.id, errorMessage);
    }
  }

  /// Enviar video (OPTIMISTIC)
  Future<void> sendVideo() async {
    if (currentUserId.isEmpty) return;

    try {
      // 1. Seleccionar video
      final ImagePicker picker = ImagePicker();
      final XFile? video = await picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );

      if (video == null) return; // Usuario canceló

      print('🎥 Video seleccionado: ${video.path}');

      // 2. Validar tamaño del video
      final MediaCompressionService compressionService = MediaCompressionService();
      final File videoFile = File(video.path);
      final File? validatedVideo = await compressionService.validateVideo(videoFile);

      if (validatedVideo == null) {
        print('❌ Video muy grande (máx 10 MB)');
        throw Exception('El video excede el límite de 10 MB');
      }

      // 3. Crear mensaje optimista CON localPath
      final tempId = const Uuid().v4();
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'video',
        localPath: validatedVideo.path, // Path local para placeholder
      );

      _messages.insert(0, optimisticMessage);
      _pendingMessages.add(optimisticMessage);
      notifyListeners();

      // 4. Subir video
      final videoUrl = await _mediaService.uploadVideoFile(
        videoFile: validatedVideo,
        chatId: chatId,
        userId: currentUserId,
      );

      if (videoUrl == null) throw Exception('Error subiendo video');

      // 5. Enviar a Firestore
      final docRef = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'videoUrl': videoUrl,
            'type': 'video',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          })
          .timeout(_sendTimeout);

      // 6. Actualizar mensaje
      final sentMessage = optimisticMessage.copyWith(
        id: docRef.id,
        videoUrl: videoUrl,
        status: MessageStatus.sent,
        localPath: null, // Limpiar localPath ya que tenemos URL
      );

      _updateMessage(tempId, sentMessage);
      _pendingMessages.removeWhere((m) => m.id == tempId);

      await _updateChatDocument('🎥 Video');
      await _sendNotification('🎥 Video');
      print('✅ [ChatController] Video enviado');
    } catch (e) {
      print('❌ [ChatController] Error enviando video: $e');
      // Buscar el mensaje pendiente
      final pendingMsg = _pendingMessages.firstWhere(
        (m) => m.senderId == currentUserId && m.type == 'video',
        orElse: () => _messages.first,
      );
      final errorMessage = pendingMsg.copyWith(status: MessageStatus.error);
      _updateMessage(pendingMsg.id, errorMessage);
    }
  }

  /// Enviar audio (OPTIMISTIC)
  Future<void> sendAudio(String audioPath) async {
    if (currentUserId.isEmpty) return;

    try {
      print('🎤 Audio seleccionado: $audioPath');

      // 1. Validar tamaño del audio
      final MediaCompressionService compressionService = MediaCompressionService();
      final File audioFile = File(audioPath);
      final File? validatedAudio = await compressionService.validateAudio(audioFile);

      if (validatedAudio == null) {
        print('❌ Audio muy grande (máx 10 MB)');
        throw Exception('El audio excede el límite de 10 MB');
      }

      // 2. Crear mensaje optimista CON localPath
      final tempId = const Uuid().v4();
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'audio',
        localPath: validatedAudio.path, // Path local para placeholder
      );

      _messages.insert(0, optimisticMessage);
      _pendingMessages.add(optimisticMessage);
      notifyListeners();

      // 3. Subir audio
      final audioUrl = await _mediaService.uploadAudioFile(
        audioFile: validatedAudio,
        chatId: chatId,
        userId: currentUserId,
      );

      if (audioUrl == null) throw Exception('Error subiendo audio');

      // 4. Enviar a Firestore
      final docRef = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'audioUrl': audioUrl,
            'type': 'audio',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          })
          .timeout(_sendTimeout);

      // 5. Actualizar mensaje
      final sentMessage = optimisticMessage.copyWith(
        id: docRef.id,
        audioUrl: audioUrl,
        status: MessageStatus.sent,
        localPath: null, // Limpiar localPath ya que tenemos URL
      );

      _updateMessage(tempId, sentMessage);
      _pendingMessages.removeWhere((m) => m.id == tempId);

      await _updateChatDocument('🎤 Audio');
      await _sendNotification('🎤 Audio');
      print('✅ [ChatController] Audio enviado');
    } catch (e) {
      print('❌ [ChatController] Error enviando audio: $e');
      // Buscar el mensaje pendiente
      final pendingMsg = _pendingMessages.firstWhere(
        (m) => m.senderId == currentUserId && m.type == 'audio',
        orElse: () => _messages.first,
      );
      final errorMessage = pendingMsg.copyWith(status: MessageStatus.error);
      _updateMessage(pendingMsg.id, errorMessage);
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

  /// Eliminar mensaje (con límite de 5 minutos)
  Future<bool> deleteMessage(String messageId, Timestamp? timestamp) async {
    if (currentUserId.isEmpty) return false;

    try {
      // Verificar que no hayan pasado más de 5 minutos
      if (timestamp != null) {
        final now = DateTime.now();
        final messageTime = timestamp.toDate();
        final difference = now.difference(messageTime);

        if (difference.inMinutes >= 5) {
          print('⚠️ No se puede eliminar: Han pasado más de 5 minutos');
          return false;
        }
      }

      // Eliminar de la lista local
      _messages.removeWhere((msg) => msg.id == messageId);
      notifyListeners();

      // Eliminar del cache
      await _cacheService.deleteMessage(chatId, messageId);

      // Eliminar de Firestore
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .delete();

      print('✅ Mensaje eliminado exitosamente');
      return true;
    } catch (e) {
      print('❌ Error eliminando mensaje: $e');
      return false;
    }
  }

  /// Limpiar chat (borrar todos los mensajes localmente pero mantener el chatId)
  Future<bool> clearChat() async {
    if (currentUserId.isEmpty) return false;

    try {
      // Marcar timestamp de limpieza en Firestore
      await _firestore.collection('chats').doc(chatId).set({
        'clearedAt_$currentUserId': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Limpiar mensajes locales
      _messages.clear();
      _pendingMessages.clear();

      // Limpiar cache
      await _cacheService.clearChat(chatId);

      notifyListeners();

      print('🧹 Chat limpiado exitosamente');
      return true;
    } catch (e) {
      print('❌ Error limpiando chat: $e');
      return false;
    }
  }

  @override
  void dispose() {
    print('🗑️ [Controller-$_controllerId] Disposing...');
    stopTyping();
    _notificationSubscription?.cancel();
    _messagesSubscription?.cancel(); // ✅ NUEVO: Cancelar listener de mensajes
    super.dispose();
  }
}
