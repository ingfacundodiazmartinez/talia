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
import '../services/user_profile_cache_service.dart';
import '../services/read_receipts_service.dart';
import '../services/delivery_receipts_service.dart';
import '../services/audio_processing_service.dart';
import '../services/offline_queue_service.dart';
import '../services/network_status_service.dart';

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
  final UserProfileCacheService _userProfileCache;
  final ReadReceiptsService _readReceiptsService;
  final DeliveryReceiptsService _deliveryReceiptsService;

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

  // Paginación
  bool _isLoadingMore = false;
  bool get isLoadingMore => _isLoadingMore;

  bool _hasMoreMessages = true;
  bool get hasMoreMessages => _hasMoreMessages;

  static const int _messagesPerPage = 50;
  DocumentSnapshot? _lastDocument;

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

  // Timestamp de cuándo se limpió el chat (para filtrar mensajes anteriores)
  Timestamp? _clearedAtTimestamp;

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
    UserProfileCacheService? userProfileCache,
    ReadReceiptsService? readReceiptsService,
    DeliveryReceiptsService? deliveryReceiptsService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _notificationService = notificationService ?? NotificationService(),
        _typingService = typingService ?? TypingIndicatorService(),
        _mediaService = mediaService ?? MediaService(),
        _cacheService = cacheService ?? MessageCacheService(),
        _soundService = soundService ?? SoundService(),
        _userProfileCache = userProfileCache ?? UserProfileCacheService(),
        _readReceiptsService = readReceiptsService ?? ReadReceiptsService(),
        _deliveryReceiptsService = deliveryReceiptsService ?? DeliveryReceiptsService() {
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
        _clearedAtTimestamp = clearedAt; // Guardar para el listener
        if (clearedAt != null) {
          print('🧹 Chat limpiado en: ${clearedAt.toDate()}');
        }
      }

      final snapshot = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(_messagesPerPage)
          .get();

      // Guardar el último documento para paginación
      if (snapshot.docs.isNotEmpty) {
        _lastDocument = snapshot.docs.last;
        _hasMoreMessages = snapshot.docs.length == _messagesPerPage;
      } else {
        _hasMoreMessages = false;
      }

      final firestoreMessages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
          .where((message) {
            // Filtrar mensajes anteriores al clearedAt
            if (clearedAt != null && message.timestamp != null) {
              if (message.timestamp!.compareTo(clearedAt) <= 0) {
                return false;
              }
            }

            // ✅ SEGURIDAD: Filtrar mensajes del contacto sin moderación aprobada/bloqueada
            if (message.senderId != currentUserId) {
              if (message.moderationStatus != ModerationStatus.approved &&
                  message.moderationStatus != ModerationStatus.blocked) {
                print('🔒 [Seguridad] Ignorando mensaje pendiente en carga inicial: ${message.id}');
                return false;
              }
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
          // ✅ OPTIMIZACIÓN: Si es mensaje propio ya en cache, solo actualizar campos necesarios
          if (message.senderId == currentUserId) {
            // Usar el mensaje de Firestore pero preservar datos locales como localPath si existen
            final currentMessage = _messages[index];
            _messages[index] = ChatMessage(
              id: message.id,
              senderId: message.senderId,
              text: message.text,
              imageUrl: message.imageUrl,
              videoUrl: message.videoUrl,
              audioUrl: message.audioUrl,
              timestamp: message.timestamp,
              isRead: message.isRead,
              replyTo: message.replyTo,
              reactions: message.reactions,
              type: message.type,
              callType: message.callType,
              callId: message.callId,
              status: message.status,
              moderationStatus: message.moderationStatus,
              moderationReason: message.moderationReason,
              moderationSeverity: message.moderationSeverity,
              originalText: message.originalText,
              waveformData: message.waveformData,
              // Preservar localPath del cache si existe y el mensaje está siendo enviado
              localPath: currentMessage.status == MessageStatus.sending ? currentMessage.localPath : null,
              // IMPORTANTE: Copiar campos de forwarding desde Firestore
              isForwarded: message.isForwarded,
              originalSenderId: message.originalSenderId,
              originalChatId: message.originalChatId,
              originalContactName: message.originalContactName,
            );
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

  /// Cargar más mensajes antiguos (paginación)
  Future<void> loadMoreMessages() async {
    // Evitar cargas duplicadas
    if (_isLoadingMore || !_hasMoreMessages || _lastDocument == null) {
      print('📄 [Pagination] No se pueden cargar más: isLoading=$_isLoadingMore, hasMore=$_hasMoreMessages, lastDoc=${_lastDocument != null}');
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    try {
      print('📄 [Pagination] Cargando más mensajes antiguos...');

      final snapshot = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .startAfterDocument(_lastDocument!)
          .limit(_messagesPerPage)
          .get();

      if (snapshot.docs.isEmpty) {
        _hasMoreMessages = false;
        print('📄 [Pagination] No hay más mensajes');
        return;
      }

      // Actualizar el último documento
      _lastDocument = snapshot.docs.last;
      _hasMoreMessages = snapshot.docs.length == _messagesPerPage;

      final newMessages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
          .where((message) {
            // Filtrar mensajes anteriores al clearedAt
            if (_clearedAtTimestamp != null && message.timestamp != null) {
              if (message.timestamp!.compareTo(_clearedAtTimestamp!) <= 0) {
                return false;
              }
            }

            // ✅ SEGURIDAD: Filtrar mensajes del contacto sin moderación aprobada/bloqueada
            if (message.senderId != currentUserId) {
              if (message.moderationStatus != ModerationStatus.approved &&
                  message.moderationStatus != ModerationStatus.blocked) {
                print('🔒 [Seguridad] Ignorando mensaje pendiente en paginación: ${message.id}');
                return false;
              }
            }

            return true;
          })
          .toList();

      // Agregar solo mensajes nuevos (evitar duplicados)
      int addedCount = 0;
      for (final message in newMessages) {
        final exists = _messages.any((m) => m.id == message.id);
        if (!exists) {
          _messages.add(message);
          addedCount++;
        }
      }

      _sortMessages();

      // Guardar en cache
      await _cacheService.saveMessages(chatId, _messages);

      print('📄 [Pagination] Cargados $addedCount mensajes adicionales (${snapshot.docs.length} totales). Total mensajes: ${_messages.length}');
    } catch (e) {
      print('❌ [Pagination] Error cargando más mensajes: $e');
    } finally {
      _isLoadingMore = false;
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
          // Procesar tanto mensajes nuevos (added) como actualizados (modified para moderación)
          if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
            final newMessage = ChatMessage.fromFirestore(change.doc, currentUserId: currentUserId);

            // ✅ SEGURIDAD: Si el mensaje NO es propio, verificar moderationStatus
            // Solo mostrar mensajes APPROVED o BLOCKED (nunca PENDING o null)
            if (newMessage.senderId != currentUserId) {
              if (newMessage.moderationStatus != ModerationStatus.approved &&
                  newMessage.moderationStatus != ModerationStatus.blocked) {
                print('🔒 [Seguridad] Ignorando mensaje pendiente de moderación: ${newMessage.id} (status: ${newMessage.moderationStatus})');
                continue; // No agregar a la lista hasta que esté aprobado o bloqueado
              }
            }

            // ✅ CASO ESPECIAL: Mensajes bloqueados propios (deben reemplazar el optimista)
            if (newMessage.senderId == currentUserId &&
                newMessage.moderationStatus == ModerationStatus.blocked) {
              print('🚫 [Realtime] Mensaje bloqueado propio recibido: ${newMessage.id}');

              // Buscar el mensaje optimista en _pendingMessages para reemplazarlo
              final pendingIndex = _pendingMessages.indexWhere((m) =>
                m.senderId == currentUserId &&
                m.status == MessageStatus.sending
              );

              if (pendingIndex != -1) {
                final optimisticId = _pendingMessages[pendingIndex].id;
                print('🔄 Reemplazando mensaje optimista $optimisticId con bloqueado ${newMessage.id}');

                // Reemplazar en la lista de mensajes
                final messageIndex = _messages.indexWhere((m) => m.id == optimisticId);
                if (messageIndex != -1) {
                  _messages[messageIndex] = newMessage;
                  _pendingMessages.removeAt(pendingIndex);
                  _cacheService.deleteMessage(chatId, optimisticId);
                  _cacheService.saveMessage(chatId, newMessage);
                  notifyListeners();
                  print('✅ Mensaje optimista reemplazado por mensaje bloqueado');
                }
              }
              continue;
            }

            // ✅ OPTIMIZACIÓN: Ignorar mensajes propios nuevos del listener (ya están en cache)
            // Solo procesar mensajes del contacto
            // PERO: Permitir actualizaciones (modified) de mensajes propios para read receipts
            if (newMessage.senderId == currentUserId && change.type == DocumentChangeType.added) {
              print('⏭️ [Realtime] Ignorando mensaje propio nuevo del listener (ya en cache): ${newMessage.id}');
              continue;
            }

            // IMPORTANTE: Verificar si el mensaje ya existe (por ID)
            final existingIndex = _messages.indexWhere((m) => m.id == newMessage.id);

            if (existingIndex != -1) {
              // El mensaje ya existe - actualizar (moderación o read receipts)
              if (change.type == DocumentChangeType.modified) {
                print('🔄 [Realtime] Actualizando mensaje existente: ${newMessage.id} (moderación o read receipt)');
                _messages[existingIndex] = newMessage;
                _cacheService.saveMessages(chatId, _messages);
                notifyListeners();
              }
              continue; // No agregar duplicados
            }

            // El mensaje no existe - agregarlo
            // ✅ Filtrar mensajes anteriores al clearedAt
            if (_clearedAtTimestamp != null && newMessage.timestamp != null) {
              if (newMessage.timestamp!.compareTo(_clearedAtTimestamp!) <= 0) {
                print('🧹 [Realtime] Ignorando mensaje anterior a limpieza: ${newMessage.id}');
                continue;
              }
            }

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

              // Marcar mensajes como entregados primero
              _deliveryReceiptsService.markMessagesAsDelivered(chatId: chatId);

              // Luego marcar como leídos
              _readReceiptsService.markMessagesAsSeen(chatId: chatId);

              notifyListeners();
            } else {
              print('🚫 [Realtime] Ignorando duplicado del contacto: ${newMessage.id}');
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
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
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
      // Verificar moderación a nivel de CHAT
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      bool moderationEnabled = chatDoc.data()?['moderationEnabled'] ?? false;

      // Verificar moderación a nivel de CONTACTO (del receptor)
      if (!moderationEnabled) {
        // Buscar contacto usando el array ordenado (más eficiente y correcto)
        final sortedUsers = [currentUserId, contactId]..sort();
        final contactsQuery = await _firestore
            .collection('contacts')
            .where('users', isEqualTo: sortedUsers)
            .limit(1)
            .get();

        if (contactsQuery.docs.isNotEmpty) {
          final contactDoc = contactsQuery.docs.first;
          final moderationSettings = contactDoc.data()['moderationSettings'] as Map<String, dynamic>?;

          if (moderationSettings != null) {
            // Verificar si el EMISOR (usuario actual) tiene moderación activada para este contacto
            final senderSettings = moderationSettings[currentUserId] as Map<String, dynamic>?;
            if (senderSettings != null && senderSettings['enabled'] == true) {
              moderationEnabled = true;
              print('🔒 Usuario emisor tiene moderación activa');
            }
          }
        }
      }

      if (moderationEnabled) {
        print('🔒 Moderación activa, verificando mensaje en background...');

        final functions = FirebaseFunctions.instance;
        final result = await functions.httpsCallable('checkMessageBeforeSending').call({
          'chatId': chatId,
          'text': text,
          'type': 'text',
          'localId': tempId, // ✅ Pasar el ID temporal para vincular con el mensaje bloqueado
        });

        final approved = result.data['approved'] as bool;

        if (!approved) {
          final reason = result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
          print('🚫 Mensaje bloqueado: $reason');

          // ✅ NO eliminar el mensaje optimista - será reemplazado por el listener
          // cuando reciba el mensaje bloqueado de Firestore con el mismo localId
          print('⏳ Esperando mensaje bloqueado del listener...');

          // NO lanzar excepción - el flujo continúa y el mensaje será reemplazado
          return;
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
      // Solo imprimir error si no es problema de conexión
      final errorString = e.toString().toLowerCase();
      if (!errorString.contains('offline') && !errorString.contains('connection')) {
        print('⚠️ Error en moderación background (continuando): $e');
      }
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

      // ✅ SEGURIDAD: La Cloud Function enviará la notificación SOLO si el mensaje es aprobado
      // No enviar notificación desde cliente para evitar leak de contenido ofensivo

      print('✅ [ChatController] Mensaje enviado: $text');
    } catch (e) {
      print('❌ [ChatController] Error enviando mensaje: $e');

      // Si no hay conexión, encolar el mensaje
      if (!NetworkStatusService().isConnected) {
        print('📴 Sin conexión - encolando mensaje para envío posterior');

        await OfflineQueueService().enqueueOperation(
          type: OfflineQueueService.OP_SEND_MESSAGE,
          data: {
            'chatId': chatId,
            'message': {
              'senderId': currentUserId,
              'text': text,
              'timestamp': DateTime.now().millisecondsSinceEpoch, // Usar timestamp real para Hive
              'isRead': false,
              if (replyTo != null) 'replyTo': replyTo,
            },
            'tempId': tempId, // Para actualizar el mensaje optimista cuando se envíe
          },
          priority: 2, // Alta prioridad para mensajes
        );

        // Marcar como pending (en cola para envío)
        final pendingMessage = optimisticMessage.copyWith(
          status: MessageStatus.sending, // Mostrar como "enviando"
        );
        _updateMessage(tempId, pendingMessage);
        await _cacheService.updateMessageStatus(chatId, tempId, MessageStatus.sending);
      } else {
        // Error de red u otro, marcar como error
        final errorMessage = optimisticMessage.copyWith(
          status: MessageStatus.error,
          retryCount: (optimisticMessage.retryCount ?? 0) + 1,
        );
        _updateMessage(tempId, errorMessage);
        await _cacheService.updateMessageStatus(chatId, tempId, MessageStatus.error);
      }
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

      // Marcar mensajes como entregados primero
      await _deliveryReceiptsService.markMessagesAsDelivered(chatId: chatId);

      // Luego marcar como leídos (con read receipts)
      await _readReceiptsService.markMessagesAsSeen(chatId: chatId);

      print('✅ [ChatController] Mensajes marcados como entregados y leídos (batch + delivery + read receipts)');
    } catch (e) {
      print('❌ [ChatController] Error en batch update: $e');
    }
  }

  /// Actualizar documento del chat
  /// ⚠️ SEGURIDAD: NO actualizar lastMessage ni unreadCount desde cliente (solo Cloud Function después de moderar)
  Future<void> _updateChatDocument(String lastMessage) async {
    print('📊 [ChatController] Actualizando chat $chatId (sin lastMessage ni unreadCount - lo hará Cloud Function)');
    await _firestore.collection('chats').doc(chatId).set({
      'participants': [currentUserId, contactId],
      'deletedBy': [],
      // ❌ NO actualizar lastMessage ni unreadCount - Cloud Function lo hace después de moderar
    }, SetOptions(merge: true));
  }

  /// ⚠️ FUNCIÓN ELIMINADA POR SEGURIDAD
  /// Las notificaciones ahora solo se envían desde Cloud Functions DESPUÉS de moderar
  /// Esto previene que el receptor vea contenido ofensivo antes de que sea bloqueado
  /// Ver: functions/index.js -> moderateMessage (línea 3949)

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
      // ✅ SEGURIDAD: La Cloud Function enviará la notificación
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

  // Variable para trackear el video optimista actual
  String? _currentOptimisticVideoId;

  /// Crear mensaje optimista de video INMEDIATAMENTE con thumbnail
  void createOptimisticVideoMessage({
    required String videoPath,
    String? thumbnailPath,
  }) {
    if (currentUserId.isEmpty) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    print('⚡ [$timestamp] Creando burbuja optimista para video: $videoPath (thumbnail: ${thumbnailPath != null ? "✅" : "❌"})');

    // Crear mensaje optimista con path local y thumbnail
    final tempId = const Uuid().v4();
    _currentOptimisticVideoId = tempId; // Guardar para actualizar después

    final optimisticMessage = ChatMessage.optimistic(
      id: tempId,
      senderId: currentUserId,
      type: 'video',
      localPath: videoPath, // Path del video original
      imageUrl: thumbnailPath, // Thumbnail para mostrar mientras carga
    );

    _messages.insert(0, optimisticMessage);
    _pendingMessages.add(optimisticMessage);
    notifyListeners(); // ⚡ Muestra la burbuja INMEDIATAMENTE

    final timestampAfter = DateTime.now().millisecondsSinceEpoch;
    print('✅ [$timestampAfter] Burbuja optimista creada con ID: $tempId (demora: ${timestampAfter - timestamp}ms)');
  }

  /// Procesar y subir video (comprimir, validar, subir)
  Future<void> processAndUploadVideo({
    required String videoPath,
    Function(String)? onShowMessage,
    VoidCallback? onHideMessage,
  }) async {
    if (currentUserId.isEmpty) return;
    if (_currentOptimisticVideoId == null) {
      print('❌ No hay mensaje optimista para actualizar');
      return;
    }

    final tempId = _currentOptimisticVideoId!;

    try {
      final timestampStart = DateTime.now().millisecondsSinceEpoch;
      print('🎥 [$timestampStart] Procesando video: $videoPath');
      final File videoFile = File(videoPath);

      // 1. Comprimir y validar video (con indicador de progreso)
      final MediaCompressionService compressionService = MediaCompressionService();

      // Notificar que se está comprimiendo
      onShowMessage?.call('Comprimiendo video...');

      final File? validatedVideo = await compressionService.validateVideo(
        videoFile,
        onProgress: (progress) {
          print('🗜️ Progreso de compresión: ${progress.toStringAsFixed(0)}%');
        },
      );

      // Ocultar mensaje de compresión
      onHideMessage?.call();

      if (validatedVideo == null) {
        print('❌ No se pudo comprimir el video bajo 10 MB');
        onShowMessage?.call('El video es muy grande y no se pudo comprimir bajo el límite de 10 MB. Intenta con un video más corto.');

        // Buscar el mensaje optimista
        final optimisticMsg = _messages.firstWhere(
          (m) => m.id == tempId,
          orElse: () => _messages.first,
        );

        // Marcar mensaje como error
        final errorMessage = optimisticMsg.copyWith(status: MessageStatus.error);
        _updateMessage(tempId, errorMessage);
        _pendingMessages.removeWhere((m) => m.id == tempId);
        _currentOptimisticVideoId = null; // Limpiar

        throw Exception('El video no se pudo comprimir bajo el límite de 10 MB');
      }

      // 2. Subir video
      final videoUrl = await _mediaService.uploadVideoFile(
        videoFile: validatedVideo,
        chatId: chatId,
        userId: currentUserId,
      );

      if (videoUrl == null) throw Exception('Error subiendo video');

      // 3. Enviar a Firestore
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

      // 4. Buscar y actualizar mensaje optimista
      final optimisticMsg = _messages.firstWhere(
        (m) => m.id == tempId,
        orElse: () => _messages.first,
      );

      final sentMessage = optimisticMsg.copyWith(
        id: docRef.id,
        videoUrl: videoUrl,
        status: MessageStatus.sent,
        localPath: null, // Limpiar localPath ya que tenemos URL
      );

      _updateMessage(tempId, sentMessage);
      _pendingMessages.removeWhere((m) => m.id == tempId);
      _currentOptimisticVideoId = null; // Limpiar

      await _updateChatDocument('🎥 Video');
      // ✅ SEGURIDAD: La Cloud Function enviará la notificación
      print('✅ [ChatController] Video enviado');
    } catch (e) {
      print('❌ [ChatController] Error enviando video: $e');

      // Ocultar mensaje de compresión si aún está visible
      onHideMessage?.call();

      // Mostrar error al usuario si no es el error de compresión (ya mostrado arriba)
      if (!e.toString().contains('no se pudo comprimir')) {
        onShowMessage?.call('Error enviando video: ${e.toString()}');
      }

      // Buscar el mensaje pendiente por tempId
      final pendingMsg = _messages.firstWhere(
        (m) => m.id == tempId,
        orElse: () => _messages.firstWhere(
          (m) => m.senderId == currentUserId && m.type == 'video',
          orElse: () => _messages.first,
        ),
      );
      final errorMessage = pendingMsg.copyWith(status: MessageStatus.error);
      _updateMessage(pendingMsg.id, errorMessage);
      _currentOptimisticVideoId = null; // Limpiar
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

      // 2. Procesar waveform ANTES de crear el mensaje optimista
      print('🎵 Procesando waveform del audio...');
      final AudioProcessingService audioProcessing = AudioProcessingService();
      final waveformData = await audioProcessing.extractWaveform(validatedAudio);
      print('✅ Waveform procesado: ${waveformData.length} puntos');

      // 3. Crear mensaje optimista CON localPath y waveform
      final tempId = const Uuid().v4();
      final optimisticMessage = ChatMessage.optimistic(
        id: tempId,
        senderId: currentUserId,
        type: 'audio',
        localPath: validatedAudio.path, // Path local para reproducir inmediatamente
        waveformData: waveformData, // Waveform real procesado
      );

      _messages.insert(0, optimisticMessage);
      _pendingMessages.add(optimisticMessage);
      notifyListeners();

      // 4. Subir audio
      final audioUrl = await _mediaService.uploadAudioFile(
        audioFile: validatedAudio,
        chatId: chatId,
        userId: currentUserId,
      );

      if (audioUrl == null) throw Exception('Error subiendo audio');

      // 5. Enviar a Firestore CON waveformData
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
            'waveformData': waveformData, // Incluir waveform en Firestore
          })
          .timeout(_sendTimeout);

      // 6. Actualizar mensaje
      final sentMessage = optimisticMessage.copyWith(
        id: docRef.id,
        audioUrl: audioUrl,
        status: MessageStatus.sent,
        localPath: null, // Limpiar localPath ya que tenemos URL
        waveformData: waveformData, // Mantener waveform
      );

      _updateMessage(tempId, sentMessage);
      _pendingMessages.removeWhere((m) => m.id == tempId);

      await _updateChatDocument('🎤 Audio');
      // ✅ SEGURIDAD: La Cloud Function enviará la notificación
      print('✅ [ChatController] Audio enviado con waveform');
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

  /// Actualizar mensaje bloqueado con nuevo texto (para editar y re-moderar)
  Future<void> updateBlockedMessage(String messageId, String newText) async {
    if (currentUserId.isEmpty) return;

    try {
      print('🔄 Actualizando mensaje bloqueado ${messageId.substring(0, 8)}... con nuevo texto');

      // ✅ NO actualizar optimísticamente - evita race condition donde el receptor ve el texto ofensivo
      // La Cloud Function actualizará el mensaje después de moderarlo

      // ✅ Llamar a checkMessageBeforeSending - la Cloud Function actualiza el mensaje
      print('🔒 Re-verificando mensaje con moderación...');

      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('checkMessageBeforeSending').call({
        'chatId': chatId,
        'text': newText,
        'type': 'text',
        'messageId': messageId, // Pasar messageId para actualizar en lugar de crear
      });

      final approved = result.data['approved'] as bool;

      if (!approved) {
        final reason = result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
        print('🚫 Mensaje re-bloqueado: $reason');
        // ✅ La Cloud Function ya actualizó el mensaje - no hacemos nada más
        return;
      }

      // ✅ Mensaje aprobado - la Cloud Function ya lo actualizó
      print('✅ Mensaje actualizado y aprobado por Cloud Function');
    } catch (e) {
      print('❌ Error actualizando mensaje bloqueado: $e');
      rethrow;
    }
  }

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
      final now = Timestamp.now();
      await _firestore.collection('chats').doc(chatId).set({
        'clearedAt_$currentUserId': now,
      }, SetOptions(merge: true));

      // Guardar el timestamp de limpieza para filtrar en el listener
      _clearedAtTimestamp = now;

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
