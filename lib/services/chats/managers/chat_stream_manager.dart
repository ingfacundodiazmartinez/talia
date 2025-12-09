import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../repositories/chat_repository.dart';
import '../repositories/message_repository.dart';
import 'chat_cache_manager.dart';
import '../../../models/chat_message.dart';
import '../../../utils/release_logger.dart';
import '../chat_orchestrator.dart';
import '../../unread_messages_service.dart';
import '../../message_cache_service.dart';
import '../../../notification_service.dart';
import '../../contact_alias_service.dart';
import '../../notification_deduplication_service.dart';
import '../../app_state_service.dart';
import '../../local_unread_count_service.dart';

/// Manager para coordinación de streams de chats
///
/// Responsabilidades:
/// - Coordinar streams de Firestore con cache
/// - Gestionar background updates
/// - Optimizar queries y reducir rebuilds
/// - NO mezcla responsabilidades de cache y streams
class ChatStreamManager {
  final ChatRepository _chatRepository;
  final MessageRepository _messageRepository;
  final ChatCacheManager _cacheManager;
  final UnreadMessagesService _unreadService;
  final NotificationDeduplicationService _deduplicationService = NotificationDeduplicationService();

  // Background stream management
  bool _isBackgroundStreamActive = false;
  final Map<String, StreamSubscription> _messageStreamSubscriptions = {};
  final Map<String, bool> _chatIsGroupMap = {}; // Mapea chatId -> isGroup
  StreamSubscription? _chatListSubscription;

  // ✅ GLOBAL MESSAGE LISTENER: Detecta mensajes en TODOS los chats para notificaciones instantáneas
  Set<String> _processedMessageIds = {}; // Evitar procesar el mismo mensaje múltiples veces
  final Set<String> _processingMessageIds = {}; // ✅ FIX #12: Lock para evitar race conditions

  // ✅ OPTIMIZACIÓN: Límites de memoria para caches
  static const int _maxProcessedMessageIds = 1000;
  static const int _maxCacheEntries = 100;

  // Stream controllers
  final Map<String, StreamController<List<ChatMessage>>> _messageControllers = {};
  final StreamController<List<Chat>> _chatListController =
      StreamController<List<Chat>>.broadcast();

  // Cache change notification controllers (for cache-first architecture)
  final Map<String, StreamController<void>> _cacheChangeControllers = {};

  // Performance tracking
  int _activeStreamCount = 0;
  DateTime? _lastRefresh;

  // Performance optimization: rate limiting
  final Map<String, DateTime> _lastUpdateTimes = {};
  static const Duration _rateLimitDuration = Duration(milliseconds: 500);

  // Track previous readBy[] state to detect read receipt changes
  final Map<String, Map<String, List<String>>> _previousReadByState = {};

  // ✅ FIX DUPLICATES: Track last emitted message IDs to prevent duplicate emissions
  final Map<String, Set<String>> _lastEmittedMessageIds = {};

  // ✅ FIX: Cache para clearedAt timestamps (evita queries redundantes)
  final Map<String, Timestamp?> _clearedAtCache = {};

  // ✅ NUEVO: Cache de SharedPreferences para evitar delays de I/O (2-5 segundos)
  SharedPreferences? _prefsCache;

  // ✅ FIX #1: MemoryCache para currentChatId (evita race condition de I/O)
  // Esta variable en memoria elimina completamente el I/O bloqueante en path crítico
  String? _cachedCurrentChatId;

  // ✅ FIX #9: Stream Detector health check for iOS
  Timer? _heartbeatTimer;
  static const MethodChannel _streamDetectorChannel = MethodChannel('com.talia.chat/stream_detector');

  ChatStreamManager({
    required ChatRepository chatRepository,
    required MessageRepository messageRepository,
    required ChatCacheManager cacheManager,
    UnreadMessagesService? unreadService,
  }) : _chatRepository = chatRepository,
       _messageRepository = messageRepository,
       _cacheManager = cacheManager,
       _unreadService = unreadService ?? UnreadMessagesService() {
    // ✅ OPTIMIZACIÓN: Pre-cargar cache de SharedPreferences en background
    // Esto evita delay de 2-5 segundos en la primera llamada
    SharedPreferences.getInstance().then((prefs) {
      _prefsCache = prefs;
      ReleaseLogger.log('✅ [ChatStreamManager] SharedPreferences cache pre-cargado');
    }).catchError((error) {
      ReleaseLogger.error('⚠️ [ChatStreamManager] Error pre-cargando SharedPreferences: $error');
    });
  }

  // ✅ NUEVO: Getter rápido con cache para SharedPreferences
  Future<SharedPreferences> get _prefs async {
    _prefsCache ??= await SharedPreferences.getInstance();
    return _prefsCache!;
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAM MANAGEMENT - MESSAGES
  // ═══════════════════════════════════════════════════════════════

  /// Obtener stream de mensajes para un chat específico
  Stream<List<ChatMessage>> getMessagesStream(String chatId, {bool isGroup = false}) {
    // Si ya existe un controller, reutilizar
    if (_messageControllers.containsKey(chatId)) {
      return _messageControllers[chatId]!.stream;
    }

    // Crear nuevo controller
    final controller = StreamController<List<ChatMessage>>.broadcast();
    _messageControllers[chatId] = controller;

    // Guardar si es grupo para futuros refreshes
    _chatIsGroupMap[chatId] = isGroup;

    // Configurar stream de Firestore
    _setupMessageStream(chatId, controller, isGroup: isGroup);

    _activeStreamCount++;
    return controller.stream;
  }

  /// Watch for cache changes for a specific chat (CACHE-FIRST ARCHITECTURE)
  /// This ONLY notifies when cache is updated, doesn't emit data
  Stream<void> watchCacheChanges(String chatId) {
    if (!_cacheChangeControllers.containsKey(chatId)) {
      _cacheChangeControllers[chatId] = StreamController<void>.broadcast();
      ReleaseLogger.log('Created cache change controller for chat $chatId');
    }
    return _cacheChangeControllers[chatId]!.stream;
  }

  /// Ensure Firestore listener is active for a chat (without returning stream)
  /// This is used by cache-first architecture to start background sync
  void ensureListenerActive(String chatId, {bool isGroup = false}) {
    // If controller already exists, listener is already active
    if (_messageControllers.containsKey(chatId)) {
      ReleaseLogger.log('Firestore listener already active for chat $chatId');
      return;
    }

    // Create controller and start listener
    final controller = StreamController<List<ChatMessage>>.broadcast();
    _messageControllers[chatId] = controller;
    _chatIsGroupMap[chatId] = isGroup;

    _setupMessageStream(chatId, controller, isGroup: isGroup);
    _activeStreamCount++;

    ReleaseLogger.log('Started Firestore listener for chat $chatId (isGroup: $isGroup)');
  }

  /// Configurar stream de mensajes desde Firestore
  Future<void> _setupMessageStream(String chatId, StreamController<List<ChatMessage>> controller, {bool isGroup = false}) async {
    // ✅ FIX: Obtener clearedAt con cache (evita queries redundantes)
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final clearedAt = await _getClearedAtCached(chatId, currentUserId, isGroup);

    final firestoreStream = _messageRepository.watchMessages(
      chatId: chatId,
      isGroup: isGroup,
      limit: 50,
      clearedAt: clearedAt, // ✅ Pasar clearedAt para filtrar
    );

    final subscription = firestoreStream.listen(
      (snapshot) async {
        try {
          // ✅ FIX: Check if this snapshot has readBy[] changes before rate limiting
          final hasReadReceiptChanges = _hasReadByChanges(chatId, snapshot);

          // Rate limiting para evitar rebuilds excesivos (pero siempre procesar cambios de read receipts)
          if (!hasReadReceiptChanges && _shouldRateLimit(chatId)) {
            ReleaseLogger.log('⏭️ [ChatStreamManager] Rate limit aplicado (sin cambios en read receipts) para chat $chatId');
            return;
          }

          if (hasReadReceiptChanges) {
            ReleaseLogger.log('📧 [ChatStreamManager] Cambios en read receipts detectados - procesando inmediatamente');
          }

          _lastUpdateTimes[chatId] = DateTime.now();

          // ✅ FIX: Get current user ID for status calculation
          final currentUserId = FirebaseAuth.instance.currentUser?.uid;

          // Convertir QuerySnapshot a List<ChatMessage>
          // ✅ FIX: Filtrar mensajes pendientes de contactos - NO deben llegar al cache
          final messages = snapshot.docs
              .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
              .where((msg) {
                // Mensajes propios: siempre incluir
                if (msg.senderId == currentUserId) return true;
                // Mensajes de contactos: solo si están aprobados o bloqueados (no pending/null)
                return msg.moderationStatus == ModerationStatus.approved ||
                       msg.moderationStatus == ModerationStatus.blocked;
              })
              .toList();

          // ✅ CRITICAL: Save to Hive cache (persistent) - CACHE-FIRST ARCHITECTURE
          await MessageCacheService().saveMessages(chatId, messages);
          ReleaseLogger.log('Saved ${messages.length} messages to Hive cache for chat $chatId');

          // ✅ FIX: Inicializar processed IDs con mensajes recibidos existentes
          // Solo en la primera carga (cuando no hay IDs previos para este chat)
          final previousIds = _lastEmittedMessageIds[chatId];
          if (previousIds == null || previousIds.isEmpty) {
            // Primera carga: marcar todos los mensajes recibidos como procesados
            for (final msg in messages) {
              if (msg.senderId != currentUserId) {
                _processedNotificationMessageIds.add(msg.id);
              }
            }
            ReleaseLogger.log('📋 [StreamDetector] Inicializados ${messages.where((m) => m.senderId != currentUserId).length} mensajes como procesados para $chatId');
          }

          // ✅ Notify cache change listeners (no data emission, just notification)
          if (_cacheChangeControllers.containsKey(chatId) &&
              !_cacheChangeControllers[chatId]!.isClosed) {
            _cacheChangeControllers[chatId]!.add(null);
            ReleaseLogger.log('Notified cache change for chat $chatId');
          }

          // Actualizar cache in-memory (for quick access)
          _cacheManager.updateCacheForChat(chatId, messages);

          // Combinar con cache optimista
          final finalMessages = _cacheManager.getCachedMessages(chatId);

          // ✅ FIX DUPLICATES: Verificar si los mensajes ya fueron emitidos
          final currentMessageIds = finalMessages.map((m) => m.id).toSet();
          final previousMessageIds = _lastEmittedMessageIds[chatId] ?? <String>{};

          // ✅ NUEVA LÓGICA CENTRALIZADA: Detectar mensajes nuevos y actualizar contadores
          await _handleNewMessagesDetected(chatId, messages, isGroup: isGroup);

          // Solo emitir si hay diferencias (nuevos mensajes o cambios)
          final hasNewMessages = !currentMessageIds.every((id) => previousMessageIds.contains(id));
          final hasRemovedMessages = !previousMessageIds.every((id) => currentMessageIds.contains(id));

          if (!hasNewMessages && !hasRemovedMessages && currentMessageIds.length == previousMessageIds.length) {
            ReleaseLogger.log('⏭️ [ChatStreamManager] Mensajes sin cambios para $chatId - SKIP emission');
          } else {
            // Actualizar tracking de IDs emitidos
            _lastEmittedMessageIds[chatId] = currentMessageIds;

            // Emitir al stream
            if (!controller.isClosed) {
              controller.add(finalMessages);
              ReleaseLogger.log('📤 [ChatStreamManager] Emitidos ${finalMessages.length} mensajes para $chatId');
            }
          }
        } catch (e) {
          ReleaseLogger.error('Error en stream de mensajes para chat $chatId: $e');
          if (!controller.isClosed) {
            controller.addError(e);
          }
        }
      },
      onError: (error) {
        ReleaseLogger.error('Error en Firestore stream para chat $chatId: $error');
        if (!controller.isClosed) {
          controller.addError(error);
        }
      },
    );

    _messageStreamSubscriptions[chatId] = subscription;
  }

  /// Verificar si debemos aplicar rate limiting
  bool _shouldRateLimit(String chatId) {
    final lastUpdate = _lastUpdateTimes[chatId];
    if (lastUpdate == null) return false;

    final timeSinceLastUpdate = DateTime.now().difference(lastUpdate);
    return timeSinceLastUpdate < _rateLimitDuration;
  }

  /// Detectar si hay cambios en readBy[] arrays comparado con el snapshot anterior
  bool _hasReadByChanges(String chatId, QuerySnapshot snapshot) {
    try {
      // Construir map del estado actual: messageId -> readBy[]
      final currentState = <String, List<String>>{};
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data != null) {
          final readBy = List<String>.from(data['readBy'] ?? []);
          currentState[doc.id] = readBy;
        }
      }

      // Si no tenemos estado previo, guardar el actual y retornar false (primera vez)
      if (!_previousReadByState.containsKey(chatId)) {
        _previousReadByState[chatId] = currentState;
        return false;
      }

      // Comparar con estado previo
      final previousState = _previousReadByState[chatId]!;
      bool hasChanges = false;

      // Verificar cada mensaje
      for (final messageId in currentState.keys) {
        final currentReadBy = currentState[messageId]!;
        final previousReadBy = previousState[messageId] ?? [];

        // Si las listas son diferentes, hay cambios
        if (currentReadBy.length != previousReadBy.length ||
            !currentReadBy.every((userId) => previousReadBy.contains(userId))) {
          ReleaseLogger.log('📧 [ReadByChange] Mensaje $messageId: ${previousReadBy.length} -> ${currentReadBy.length} usuarios');
          hasChanges = true;
        }
      }

      // Actualizar estado previo
      _previousReadByState[chatId] = currentState;

      return hasChanges;
    } catch (e) {
      ReleaseLogger.error('❌ Error detectando cambios en readBy[]: $e');
      // En caso de error, asumir que hay cambios para no bloquear actualizaciones
      return true;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAM MANAGEMENT - CHAT LIST
  // ═══════════════════════════════════════════════════════════════

  /// Obtener stream de lista de chats del usuario
  Stream<List<Chat>> getChatListStream() {
    if (_chatListSubscription == null) {
      _setupChatListStream();
    }
    return _chatListController.stream;
  }

  /// Configurar stream de lista de chats
  void _setupChatListStream() {
    final firestoreStream = _chatRepository.getUserChatsStream();

    _chatListSubscription = firestoreStream.listen(
      (snapshot) async {
        try {
          // Convertir QuerySnapshot a List<Chat> (usando modelo simple)
          final chats = snapshot.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return Chat(
              id: doc.id,
              type: data['type'] ?? 'individual',
              name: data['name'] ?? '',
              participants: List<String>.from(data['participants'] ?? []),
              lastActivity: (data['lastActivity'] as Timestamp?)?.toDate() ?? DateTime.now(),
              unreadCount: data['unreadCount'] ?? 0,
            );
          }).toList();

          // Emitir al stream
          if (!_chatListController.isClosed) {
            _chatListController.add(chats);
          }
        } catch (e) {
          ReleaseLogger.error('Error en stream de lista de chats: $e');
          if (!_chatListController.isClosed) {
            _chatListController.addError(e);
          }
        }
      },
      onError: (error) {
        ReleaseLogger.error('Error en Firestore stream de chats: $error');
        if (!_chatListController.isClosed) {
          _chatListController.addError(error);
        }
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // BACKGROUND STREAMS MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar background streams
  Future<void> startBackgroundStreams() async {
    if (_isBackgroundStreamActive) {
      return; // Ya están activos
    }

    try {
      // Inicializar stream de lista de chats
      _setupChatListStream();

      _isBackgroundStreamActive = true;
      _lastRefresh = DateTime.now();

      ReleaseLogger.info('Chat background streams iniciados');
    } catch (e) {
      ReleaseLogger.error('Error iniciando background streams: $e');
      throw Exception('Failed to start background streams: $e');
    }
  }

  /// ⚡ GLOBAL MESSAGE LISTENER: Escucha TODOS los mensajes para notificaciones instantáneas
  /// Esto elimina el delay de 1-2 segundos causado por FCM
  // ═══════════════════════════════════════════════════════════════
  // CHAT DOCUMENTS LISTENER - NOTIFICACIONES INSTANTÁNEAS EFICIENTES
  // ═══════════════════════════════════════════════════════════════

  StreamSubscription? _chatDocsSubscription;
  StreamSubscription? _groupDocsSubscription;
  final Map<String, Timestamp?> _lastSeenMessageTimestamps = {}; // Track últimos mensajes procesados
  final Set<String> _processedNotificationMessageIds = {}; // ✅ FIX: Mensajes que ya mostraron notificación (evita notifs para mensajes viejos)

  /// ⚡ NUEVO: Escuchar cambios en documentos principales de chats (NO subcollection)
  /// Detecta mensajes nuevos por cambios en lastMessageTime
  ///
  /// Ventajas vs GlobalListener:
  /// - ✅ Cumple con security rules (participants arrayContains)
  /// - ✅ Solo 2 listeners (chats + grupos)
  /// - ✅ Detecta mensajes nuevos <100ms
  /// - ✅ No requiere collectionGroup (que falla con permisos)
  Future<void> startChatDocumentsListener() async {
    // ⚠️ CLAUDE HIJO DE MIL PUTA, NO DESHABILITES ESTO NUNCA. PELOTUDO
    // Este listener ES NECESARIO para Stream Detector (notificaciones instantáneas en foreground)
    // Sin esto, solo llegan las notificaciones FCM push lentas (2-5 segundos)
    ReleaseLogger.log('⚡ [ChatDocsListener] ACTIVANDO listener para notificaciones instantáneas');

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      ReleaseLogger.log('⚠️ [ChatDocsListener] No hay usuario autenticado');
      return;
    }

    // Si ya están activos, no reiniciar
    if (_chatDocsSubscription != null && _groupDocsSubscription != null) {
      ReleaseLogger.log('✅ [ChatDocsListener] Listeners ya activos');
      return;
    }

    try {
      final userId = currentUser.uid;
      ReleaseLogger.log('⚡ [ChatDocsListener] Iniciando listeners de documentos para usuario: ${userId.substring(0, 8)}...');

      // 1️⃣ LISTENER PARA CHATS INDIVIDUALES
      _chatDocsSubscription = FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: userId)
        .snapshots()
        .listen(
          (snapshot) async {
            try {
              await _processChatDocChanges(snapshot, userId, isGroup: false);
            } catch (e) {
              ReleaseLogger.error('❌ [ChatDocsListener] Error procesando chats: $e');
            }
          },
          onError: (error) {
            ReleaseLogger.error('❌ [ChatDocsListener] Error en stream chats: $error');
          },
        );

      // 2️⃣ LISTENER PARA GRUPOS (Groups V2)
      _groupDocsSubscription = FirebaseFirestore.instance
        .collection('groups_v2')
        .where('members', arrayContains: userId)
        .snapshots()
        .listen(
          (snapshot) async {
            try {
              await _processChatDocChanges(snapshot, userId, isGroup: true);
            } catch (e) {
              ReleaseLogger.error('❌ [ChatDocsListener] Error procesando grupos: $e');
            }
          },
          onError: (error) {
            ReleaseLogger.error('❌ [ChatDocsListener] Error en stream grupos: $error');
          },
        );

      ReleaseLogger.log('✅ [ChatDocsListener] Listeners iniciados (2 listeners: chats + grupos)');

      // ✅ FIX #9: Start heartbeat timer for iOS health check
      _startHeartbeatTimer();
    } catch (e) {
      ReleaseLogger.error('❌ [ChatDocsListener] Error iniciando listeners: $e');
    }
  }

  /// ✅ FIX #9: Send periodic heartbeats to iOS to indicate Stream Detector is healthy
  void _startHeartbeatTimer() {
    // Only run on iOS
    if (!Platform.isIOS) return;

    // Cancel existing timer if any
    _heartbeatTimer?.cancel();

    // Send immediate heartbeat
    _sendHeartbeat();

    // Send heartbeat every 15 seconds
    _heartbeatTimer = Timer.periodic(Duration(seconds: 15), (_) {
      _sendHeartbeat();
    });

    ReleaseLogger.log('✅ [StreamDetector] Heartbeat timer started (every 15s)');
  }

  /// ✅ FIX #9: Send heartbeat to iOS
  Future<void> _sendHeartbeat() async {
    try {
      await _streamDetectorChannel.invokeMethod('heartbeat');
    } catch (e) {
      // Silently fail - iOS might not have the channel set up yet
    }
  }

  /// Procesar cambios en documentos de chat/grupo
  Future<void> _processChatDocChanges(QuerySnapshot snapshot, String userId, {required bool isGroup}) async {
    try {
      // Detectar solo modificaciones (cuando llega mensaje nuevo, lastMessageAt cambia)
      final modifiedDocs = snapshot.docChanges
          .where((change) => change.type == DocumentChangeType.modified)
          .map((change) => change.doc)
          .toList();

      if (modifiedDocs.isEmpty) return;

      ReleaseLogger.log('⚡ [ChatDocsListener] Detectados ${modifiedDocs.length} ${isGroup ? "grupos" : "chats"} modificados');

      for (final chatDoc in modifiedDocs) {
        final chatId = chatDoc.id;

        // 🔍 DEBUG: Log para ver qué grupos se detectan
        ReleaseLogger.log('🔍 [ChatDocsListener] Procesando ${isGroup ? "grupo" : "chat"}: ${chatId.substring(0, 8)}...');

        final chatData = chatDoc.data() as Map<String, dynamic>?;
        if (chatData == null) {
          ReleaseLogger.log('⚠️ [ChatDocsListener] chatData es null para $chatId');
          continue;
        }

        final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;
        if (lastMessageTime == null) {
          ReleaseLogger.log('⚠️ [ChatDocsListener] lastMessageTime es null para ${isGroup ? "grupo" : "chat"} $chatId - keys: ${chatData.keys.toList()}');
          continue;
        }

        // FILTRO 1: Solo procesar si lastMessageTime es MÁS RECIENTE (mensaje nuevo)
        // ✅ FIX: Si es la primera vez que vemos este chat, guardar timestamp y SKIP
        // Esto evita notificaciones falsas al archivar/desarchivar/modificar chat
        final previousTimestamp = _lastSeenMessageTimestamps[chatId];

        if (previousTimestamp == null) {
          // Primera vez que vemos este chat - solo guardar timestamp, no notificar
          _lastSeenMessageTimestamps[chatId] = lastMessageTime;
          ReleaseLogger.log('📝 [ChatDocsListener] Primera vez viendo chat $chatId - guardando timestamp inicial');
          continue;
        }

        // Si el timestamp NO cambió, skip
        if (lastMessageTime.seconds == previousTimestamp.seconds &&
            lastMessageTime.nanoseconds == previousTimestamp.nanoseconds) {
          continue; // Sin cambios en lastMessageTime
        }

        // ✅ FIX: Solo procesar si el nuevo timestamp es MAYOR (mensaje más reciente)
        // Esto evita notificaciones si el timestamp cambió pero hacia atrás (edge case)
        final isNewerMessage = lastMessageTime.seconds > previousTimestamp.seconds ||
            (lastMessageTime.seconds == previousTimestamp.seconds &&
             lastMessageTime.nanoseconds > previousTimestamp.nanoseconds);

        if (!isNewerMessage) {
          _lastSeenMessageTimestamps[chatId] = lastMessageTime;
          continue; // Timestamp no es más reciente - skip
        }

        // Actualizar timestamp visto
        _lastSeenMessageTimestamps[chatId] = lastMessageTime;

        // ✅ FILTRO DE EDAD ELIMINADO: Causaba falsos negativos por desfase de relojes (clock skew)
        // El FILTRO 1 (timestamp cambió) ya garantiza que solo procesamos mensajes nuevos
        // No necesitamos filtro de edad adicional

        // ✅ FIX #1: FILTRO 2 - MemoryCache puro (SIN I/O bloqueante)
        // Usa variable en memoria (_cachedCurrentChatId) en lugar de SharedPreferences
        // Esto elimina COMPLETAMENTE el riesgo de race condition (0ms vs potenciales 2-5s)

        if (_cachedCurrentChatId != null && _cachedCurrentChatId == chatId) {
          ReleaseLogger.log('📱 [ChatDocsListener] Usuario está en chat $chatId - SKIP notificación');
          continue;
        }

        // ⚡ Obtener el mensaje más reciente y mostrar notificación
        await _fetchAndShowLatestMessage(chatId, userId, isGroup: isGroup);
      }

      // ✅ FIX: Limpiar caches para prevenir memory leaks en sesiones largas
      _cleanupCachesIfNeeded();
    } catch (e) {
      ReleaseLogger.error('❌ [ChatDocsListener] Error en _processChatDocChanges: $e');
    }
  }

  /// Obtener el mensaje más reciente del chat y mostrar notificación
  /// ✅ SOLUCIÓN SIN RACE CONDITION: Usa campos denormalizados del chat doc (lastMessage, lastMessageSender)
  /// en lugar de hacer query a subcollection messages (que puede retornar vacío por security rules o timing)
  Future<void> _fetchAndShowLatestMessage(String chatId, String userId, {required bool isGroup}) async {
    try {
      ReleaseLogger.log('📥 [ChatDocsListener] Obteniendo datos del chat ${isGroup ? "grupo" : "chat"} $chatId');

      final collection = isGroup ? 'groups_v2' : 'chats';

      // ✅ SOLUCIÓN: Obtener documento del chat (ya tiene lastMessage, lastMessageSender)
      final chatDoc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(chatId)
          .get();

      if (!chatDoc.exists) {
        ReleaseLogger.log('⚠️ [ChatDocsListener] Chat no existe: $chatId');
        return;
      }

      final chatData = chatDoc.data() as Map<String, dynamic>;
      final senderId = chatData['lastMessageSender'] as String?;
      final messageText = chatData['lastMessage'] as String?;
      final lastMessageType = chatData['lastMessageType'] as String?; // ✅ NEW: Tipo del mensaje
      final lastMessageId = chatData['lastMessageId'] as String?; // ✅ NUEVO: ID real del mensaje

      if (senderId == null) {
        ReleaseLogger.log('⚠️ [ChatDocsListener] No hay lastMessageSender en chat $chatId');
        return;
      }

      // FILTRO 4: Solo mensajes de OTROS usuarios
      if (senderId == userId) {
        return;
      }

      // ✅ ANTI-DUPLICADOS MEJORADO: Usar lastMessageId (ID real del mensaje)
      if (lastMessageId == null || lastMessageId.isEmpty) {
        ReleaseLogger.log('⚠️ [ChatDocsListener] No hay lastMessageId en chat $chatId - SKIP');
        return;
      }

      // ✅ FIX #12: Race condition lock - Evitar procesamiento simultáneo del mismo mensaje
      if (_processingMessageIds.contains(lastMessageId)) {
        ReleaseLogger.log('🔒 [ChatDocsListener] Mensaje $lastMessageId ya está siendo procesado - SKIP');
        return;
      }
      _processingMessageIds.add(lastMessageId);

      try {
        // Query: Usuario remitente + alias en paralelo
        final results = await Future.wait([
          FirebaseFirestore.instance.collection('users').doc(senderId).get(),
          ContactAliasService().getDisplayName(
            senderId,
            '', // Placeholder, se reemplaza con el nombre real después
          ),
        ]);

        final senderDoc = results[0] as DocumentSnapshot;
        final realName = senderDoc.data() != null
            ? (senderDoc.data() as Map<String, dynamic>)['name'] as String? ?? senderId
            : senderId;

        // Obtener alias (si existe)
        final senderName = await ContactAliasService().getDisplayName(senderId, realName);
        final groupName = isGroup ? (chatData['name'] as String? ?? 'Grupo') : null;
        final senderPhotoUrl = senderDoc.data() != null
            ? (senderDoc.data() as Map<String, dynamic>)['photoURL'] as String?
            : null;

        // ⚡ MOSTRAR NOTIFICACIÓN INSTANTÁNEA
        // ✅ FIX: Usar lastMessageType para determinar el texto si lastMessage es null
        String displayText;
        if (messageText != null && messageText.isNotEmpty) {
          displayText = messageText;
        } else {
          // Fallback basado en tipo de mensaje
          switch (lastMessageType) {
            case 'image':
              displayText = '📷 Imagen';
              break;
            case 'video':
              displayText = '🎥 Video';
              break;
            case 'audio':
              displayText = '🎤 Audio';
              break;
            default:
              displayText = 'Nuevo mensaje';
          }
        }

        ReleaseLogger.log('⚡ [ChatDocsListener] Mostrando notificación instantánea');
        ReleaseLogger.log('   - Chat: ${isGroup ? "Grupo" : "Individual"} ($chatId)');
        ReleaseLogger.log('   - Remitente: $senderName');
        ReleaseLogger.log('   - Mensaje: $displayText');
        ReleaseLogger.log('   - MessageId: $lastMessageId');

        // ✅ FIX #10: Solo mostrar notificaciones instantáneas si la app está en FOREGROUND
        // Si está en background, dejar que FCM maneje la notificación (evita duplicados)
        if (!AppStateService().isInForeground) {
          ReleaseLogger.log('📱 [ChatDocsListener] App en background - SKIP notificación local (FCM se encargará)');
          return;
        }

        // ✅ FIX iOS DUPLICATES: Verificar si el mensaje ya fue procesado
        // 1. Por el background handler (SharedPreferences) - cuando app estaba killed
        // 2. Por el NSE (App Group UserDefaults) - cuando app estaba en background
        if (Platform.isIOS) {
          final wasProcessedInBackground = await wasMessageProcessedInBackground(lastMessageId);
          final wasProcessedByNSE = await NotificationService().wasMessageProcessedByNSE(lastMessageId);

          if (wasProcessedInBackground || wasProcessedByNSE) {
            ReleaseLogger.log('📱 [ChatDocsListener] messageId=$lastMessageId ya procesado (bg=$wasProcessedInBackground, nse=$wasProcessedByNSE) - SKIP');
            _deduplicationService.tryAcquire(lastMessageId);
            return;
          }
        }

        // ✅ CRITICAL: Verificar si el usuario tiene el chat abierto
        // Si el chat del sender está abierto, NO mostrar notificación
        final prefs = await SharedPreferences.getInstance();
        final currentChatId = prefs.getString('current_chat_id');

        if (currentChatId != null && currentChatId == chatId) {
          ReleaseLogger.log('🚫 [ChatDocsListener] Usuario tiene el chat $chatId abierto - NO mostrar notificación');
          // Marcar como procesado para evitar que se muestre después
          _deduplicationService.tryAcquire(lastMessageId);
          return;
        }

        // ✅ ATOMIC: Try to acquire the right to show this notification
        // El messageId ya está marcado en cache si el usuario tocó la notificación push (onMessageOpenedApp)
        // Only ONE listener (ChatDocsListener OR StreamDetector) will succeed
        if (!_deduplicationService.tryAcquire(lastMessageId)) {
          ReleaseLogger.log('⏭️ [ChatDocsListener] Otro listener ya mostró $lastMessageId - SKIP');
          return;
        }

        await NotificationService().showLocalChatNotification(
          senderId: senderId,
          senderName: senderName,
          messageText: displayText,
          chatId: chatId,
          isGroup: isGroup,
          groupName: groupName,
          senderPhotoUrl: senderPhotoUrl,
        );

        // ✅ Incrementar contador de mensajes no leídos (solo si no está en el chat)
        ReleaseLogger.log('📊 [ChatDocsListener] Llamando incrementUnreadCount para $chatId');
        final incremented = await LocalUnreadCountService().incrementUnreadCount(chatId);
        ReleaseLogger.log('📊 [ChatDocsListener] incrementUnreadCount retornó: $incremented');

        ReleaseLogger.log('✅ [ChatDocsListener] Notificación instantánea mostrada para chat $chatId');
      } finally {
        // ✅ FIX #12: Liberar lock
        _processingMessageIds.remove(lastMessageId);
      }

    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [ChatDocsListener] Error en _fetchAndShowLatestMessage: $e');
      ReleaseLogger.error('Stack trace: $stackTrace');
      // Asegurar que se libere el lock en caso de error fuera del try block (aunque el finally lo cubre)
      // _processingMessageIds.remove(lastMessageId); // Eliminado porque lastMessageId no es visible y finally ya lo maneja
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PER-CHAT LISTENERS - ARQUITECTURA CORRECTA PARA NOTIFICACIONES INSTANTÁNEAS
  // ═══════════════════════════════════════════════════════════════

  /// ⚡ NUEVO: Iniciar listeners individuales para TODOS los chats del usuario
  /// Esto reemplaza GlobalListener (que falla por permisos de Firestore)
  ///
  /// Ventajas:
  /// - Cumple con security rules de Firestore (queries específicos por chat)
  /// - Usa el código existente de notificaciones instantáneas (líneas 756-838)
  /// - Notificaciones <100ms (sin delay de Cloud Functions)
  Future<void> startAllChatListeners() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      ReleaseLogger.log('⚠️ [AllChatListeners] No hay usuario autenticado');
      return;
    }

    try {
      final userId = currentUser.uid;
      ReleaseLogger.log('⚡ [AllChatListeners] Iniciando listeners para todos los chats del usuario ${userId.substring(0, 8)}...');

      // 1️⃣ Obtener todos los chats individuales donde el usuario es participante
      final chatsSnapshot = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: userId)
          .get();

      ReleaseLogger.log('📊 [AllChatListeners] Encontrados ${chatsSnapshot.docs.length} chats individuales');

      for (final chatDoc in chatsSnapshot.docs) {
        final chatId = chatDoc.id;
        ensureListenerActive(chatId, isGroup: false);
      }

      // 2️⃣ Obtener todos los grupos donde el usuario es miembro (Groups V2)
      final groupsSnapshot = await FirebaseFirestore.instance
          .collection('groups_v2')
          .where('members', arrayContains: userId)
          .get();

      ReleaseLogger.log('📊 [AllChatListeners] Encontrados ${groupsSnapshot.docs.length} grupos');

      for (final groupDoc in groupsSnapshot.docs) {
        final groupId = groupDoc.id;
        ensureListenerActive(groupId, isGroup: true);
      }

      ReleaseLogger.log('✅ [AllChatListeners] Listeners iniciados: ${chatsSnapshot.docs.length} chats + ${groupsSnapshot.docs.length} grupos');
      ReleaseLogger.log('✅ [AllChatListeners] Total de listeners activos: $_activeStreamCount');

    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [AllChatListeners] Error iniciando listeners: $e');
      ReleaseLogger.error('Stack trace: $stackTrace');
    }
  }

  /// Detener background streams
  void stopBackgroundStreams() {
    if (!_isBackgroundStreamActive) {
      return; // Ya están detenidos
    }

    try {
      // Detener stream de chats
      _chatListSubscription?.cancel();
      _chatListSubscription = null;

      // ⚡ Detener listeners de documentos de chats/grupos
      _chatDocsSubscription?.cancel();
      _chatDocsSubscription = null;
      _groupDocsSubscription?.cancel();
      _groupDocsSubscription = null;
      _lastSeenMessageTimestamps.clear();
      ReleaseLogger.log('⚡ [ChatDocsListener] Listeners de documentos detenidos');

      // ✅ FIX #9: Stop heartbeat timer
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      ReleaseLogger.log('⚡ [StreamDetector] Heartbeat timer stopped');

      // Detener streams de mensajes
      for (final subscription in _messageStreamSubscriptions.values) {
        subscription.cancel();
      }
      _messageStreamSubscriptions.clear();

      // Cerrar controllers
      for (final controller in _messageControllers.values) {
        controller.close();
      }
      _messageControllers.clear();
      _chatIsGroupMap.clear();

      _isBackgroundStreamActive = false;
      _activeStreamCount = 0;

      ReleaseLogger.info('Chat background streams detenidos');
    } catch (e) {
      ReleaseLogger.error('Error deteniendo background streams: $e');
    }
  }

  /// Forzar refresh de todos los streams activos
  Future<void> forceRefresh() async {
    try {
      // Invalidar cache
      _cacheManager.clearAllCache();

      // Re-setup streams activos
      final activeChatIds = List.from(_messageControllers.keys);

      for (final chatId in activeChatIds) {
        await _refreshChatStream(chatId);
      }

      // Refresh chat list
      if (_chatListSubscription != null) {
        _setupChatListStream();
      }

      _lastRefresh = DateTime.now();
      ReleaseLogger.info('Force refresh completado para ${activeChatIds.length} chats');
    } catch (e) {
      ReleaseLogger.error('Error en force refresh: $e');
      throw Exception('Failed to force refresh streams: $e');
    }
  }

  /// Refresh stream específico de un chat
  Future<void> _refreshChatStream(String chatId) async {
    // Cancelar stream existente
    _messageStreamSubscriptions[chatId]?.cancel();

    // Re-crear stream
    final controller = _messageControllers[chatId];
    final isGroup = _chatIsGroupMap[chatId] ?? false;

    if (controller != null && !controller.isClosed) {
      _setupMessageStream(chatId, controller, isGroup: isGroup);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener número de streams activos
  int getActiveStreamCount() => _activeStreamCount;

  /// Verificar si background streams están activos
  bool get isBackgroundActive => _isBackgroundStreamActive;

  /// Obtener timestamp del último refresh
  DateTime? get lastRefreshTime => _lastRefresh;

  /// Cleanup al cerrar un chat específico
  void closeChatStream(String chatId) {
    _messageStreamSubscriptions[chatId]?.cancel();
    _messageStreamSubscriptions.remove(chatId);

    _messageControllers[chatId]?.close();
    _messageControllers.remove(chatId);

    // Close cache change controller too
    _cacheChangeControllers[chatId]?.close();
    _cacheChangeControllers.remove(chatId);

    _chatIsGroupMap.remove(chatId);
    _lastUpdateTimes.remove(chatId);
    _previousReadByState.remove(chatId); // ✅ Cleanup readBy[] state
    _lastEmittedMessageIds.remove(chatId); // ✅ Cleanup emitted message IDs
    _activeStreamCount = _messageControllers.length;
  }

  // ═══════════════════════════════════════════════════════════════
  // UNREAD COUNT MANAGEMENT - NUEVA LÓGICA CENTRALIZADA
  // ═══════════════════════════════════════════════════════════════

  /// Manejar mensajes nuevos detectados y actualizar contadores
  Future<void> _handleNewMessagesDetected(String chatId, List<ChatMessage> messages, {bool isGroup = false}) async {
    try {
      ReleaseLogger.log('🔍 [DEBUG] _handleNewMessagesDetected INICIADO para chat $chatId con ${messages.length} mensajes totales');

      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        ReleaseLogger.log('⚠️ [DEBUG] currentUser es null - saliendo');
        return;
      }

      final currentUserId = currentUser.uid;
      // ✅ FIX #18: Removed excessive DEBUG logs

      // Filtrar mensajes que NO sean del usuario actual (mensajes recibidos)
      final receivedMessages = messages.where((message) =>
        message.senderId != currentUserId
      ).toList();

      if (receivedMessages.isEmpty) {
        // No hay mensajes nuevos de otros usuarios
        return;
      }

      ReleaseLogger.log('📊 [ChatStreamManager] Detectados ${receivedMessages.length} mensajes recibidos en ${isGroup ? 'grupo' : 'chat'} $chatId');

      // ✅ PASO 1: Verificar si el usuario está viendo este chat actualmente
      final currentChatId = await _getCurrentActiveChatId();

      if (currentChatId != null && currentChatId == chatId) {
        ReleaseLogger.log('📱 [ChatStreamManager] Usuario está en chat $chatId - el ChatController se encarga de marcar como leído');

        // ✅ SIMPLIFICADO: El ChatController maneja los read receipts
        // Aquí solo reseteamos el rate limit y actualizamos el contador
        _lastUpdateTimes.remove(chatId);

        // Poner contador en 0 automáticamente
        await _updateUnreadCountInFirestore(chatId, currentUserId, 0, isGroup: isGroup);
        await _unreadService.updateBadgeCount();
        return; // No necesitamos calcular contador ni mostrar notificación
      }

      // ✅ PASO 2: Contar cuántos de los mensajes recibidos NO están leídos
      int newUnreadMessages = 0;
      for (final receivedMessage in receivedMessages) {
        final readBy = receivedMessage.readBy ?? [];
        final isRead = readBy.contains(currentUserId);

        if (!isRead) {
          newUnreadMessages++;
        }
      }

      ReleaseLogger.log('📊 [ChatStreamManager] Detectados $newUnreadMessages mensajes no leídos nuevos en ${isGroup ? 'grupo' : 'chat'} $chatId');

      // ✅ FIX #3: ELIMINADO incremento de unreadCount del cliente
      // Cloud Functions (chats.js:76-83) ya incrementan correctamente cuando se crea el mensaje
      // Incrementar aquí causaba duplicación (+2 por mensaje en lugar de +1)
      // El cliente SOLO lee unreadCount, NUNCA lo modifica directamente

      // ⚡ NOTIFICACIÓN INSTANTÁNEA: Mostrar notificación local para el mensaje más reciente
      // Esto evita el delay de 2-5 segundos de las Cloud Functions
      // El listener de Firestore detecta mensajes en <100ms
      // ✅ FIX #18: Removed excessive DEBUG logs

      if (receivedMessages.isNotEmpty) {  // ✅ ACTIVADO PARA TODOS (1-1 y grupos)
        final latestMessage = receivedMessages.first; // El más reciente

        // ✅ FIX: Solo mostrar notificación si el mensaje NO fue procesado anteriormente
        // Esto evita mostrar notificaciones para mensajes viejos durante sincronización del cache
        if (_processedNotificationMessageIds.contains(latestMessage.id)) {
          ReleaseLogger.log('⏭️ [StreamDetector] Mensaje ${latestMessage.id.substring(0, 8)}... ya fue procesado - SKIP notificación');
          return;
        }

        // Marcar como procesado ANTES de mostrar notificación
        _processedNotificationMessageIds.add(latestMessage.id);

        try {
          // Obtener información del remitente
          String senderName = latestMessage.senderId;
          String? groupName;
          String? senderPhotoUrl;  // ✅ FIX: Capturar foto del sender

          if (isGroup) {
            // Para grupos, obtener nombre del grupo (Groups V2)
            final groupDoc = await FirebaseFirestore.instance
                .collection('groups_v2')
                .doc(chatId)
                .get();
            groupName = groupDoc.data()?['name'] as String? ?? 'Grupo';

            // Y nombre del miembro que envió (primero nombre real, luego alias)
            final senderDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(latestMessage.senderId)
                .get();
            final realName = senderDoc.data()?['name'] as String? ?? senderName;
            senderPhotoUrl = senderDoc.data()?['photoURL'] as String?;  // ✅ FIX: Capturar foto

            // Obtener alias si existe
            senderName = await ContactAliasService().getDisplayName(latestMessage.senderId, realName);
          } else {
            // Para chats 1-1, obtener nombre real del remitente
            final senderDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(latestMessage.senderId)
                .get();
            final realName = senderDoc.data()?['name'] as String? ?? senderName;
            senderPhotoUrl = senderDoc.data()?['photoURL'] as String?;  // ✅ FIX: Capturar foto

            // Obtener alias si existe (el receptor puede haberle puesto un alias al remitente)
            senderName = await ContactAliasService().getDisplayName(latestMessage.senderId, realName);
          }

          // ✅ FIX iOS DUPLICATES: Verificar si el mensaje ya fue procesado
          // 1. Por el background handler (SharedPreferences) - cuando app estaba killed
          // 2. Por el NSE (App Group UserDefaults) - cuando app estaba en background
          if (Platform.isIOS) {
            final wasProcessedInBackground = await wasMessageProcessedInBackground(latestMessage.id);
            final wasProcessedByNSE = await NotificationService().wasMessageProcessedByNSE(latestMessage.id);

            if (wasProcessedInBackground || wasProcessedByNSE) {
              ReleaseLogger.log('📱 [StreamDetector] messageId=${latestMessage.id.substring(0, 8)}... ya procesado (bg=$wasProcessedInBackground, nse=$wasProcessedByNSE) - SKIP');
              // Marcar como procesado para evitar que otros listeners lo muestren
              _deduplicationService.tryAcquire(latestMessage.id);
              return;
            }
          }

          // ✅ ATOMIC: Try to acquire the right to show this notification
          // Only ONE listener (ChatDocsListener OR StreamDetector) will succeed
          if (!_deduplicationService.tryAcquire(latestMessage.id)) {
            ReleaseLogger.log('⏭️ [StreamDetector] Otro listener ya mostró ${latestMessage.id.substring(0, 8)}... - SKIP');
          } else {
            // Mostrar notificación local instantánea
            // ✅ FIX: Determinar texto de notificación basado en tipo de mensaje
            String notificationText;
            if (latestMessage.text != null && latestMessage.text!.isNotEmpty) {
              notificationText = latestMessage.text!;
            } else {
              switch (latestMessage.type) {
                case 'image':
                  notificationText = '📷 Imagen';
                  break;
                case 'video':
                  notificationText = '🎥 Video';
                  break;
                case 'audio':
                  notificationText = '🎤 Audio';
                  break;
                default:
                  notificationText = 'Nuevo mensaje';
              }
            }

            ReleaseLogger.log('⚡ [StreamDetector] Mostrando notificación instantánea...');
            ReleaseLogger.log('   - senderId=${latestMessage.senderId.substring(0, 8)}..., senderName=$senderName');
            ReleaseLogger.log('   - messageText=$notificationText');
            ReleaseLogger.log('   - chatId=${chatId.substring(0, 8)}..., isGroup=$isGroup');

            await NotificationService().showLocalChatNotification(
              senderId: latestMessage.senderId,
              senderName: senderName,
              messageText: notificationText,
              chatId: chatId,
              isGroup: isGroup,
              groupName: groupName,
              senderPhotoUrl: senderPhotoUrl,  // ✅ FIX: Pasar foto del sender
            );

            // ✅ Incrementar contador de mensajes no leídos (solo si no está en el chat)
            await LocalUnreadCountService().incrementUnreadCount(chatId);

            ReleaseLogger.log('✅ [StreamDetector] Notificación instantánea mostrada para ${latestMessage.id.substring(0, 8)}...');
          }
        } catch (e, stackTrace) {
          ReleaseLogger.error('❌ Error disparando notificación instantánea: $e');
          ReleaseLogger.error('Stack trace: $stackTrace');
        }
      } else {
        ReleaseLogger.log('⚠️ [DEBUG] receivedMessages está vacío - no se mostrará notificación');
      }

      // Actualizar badge global
      await _unreadService.updateBadgeCount();

    } catch (e) {
      ReleaseLogger.error('❌ Error manejando mensajes nuevos en chat $chatId: $e');
    }
  }

  /// Obtener el chat ID que el usuario está viendo actualmente
  Future<String?> _getCurrentActiveChatId() async {
    try {
      final prefs = await _prefs;  // ✅ Cache rápido (0-5ms vs 2-5 segundos)

      // Intentar diferentes claves (como en el Android service)
      String? currentChatId = prefs.getString('flutter.current_chat_id');
      currentChatId ??= prefs.getString('current_chat_id');

      ReleaseLogger.log('📱 [ChatStreamManager] Chat activo detectado: $currentChatId');
      return currentChatId;
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo chat activo: $e');
      return null;
    }
  }

  // ✅ SIMPLIFICADO: El ChatController ahora es el único responsable de marcar mensajes como leídos
  // Esto evita duplicación y respeta correctamente la configuración de privacidad del usuario

  // ✅ FUNCIÓN ELIMINADA: Ya no necesitamos consultar Firestore por cada mensaje
  // El conteo de no leídos ahora se hace directamente sobre el cache usando readBy[]

  /// Actualizar contador de no leídos en Firestore
  Future<void> _updateUnreadCountInFirestore(String chatId, String userId, int unreadCount, {bool isGroup = false}) async {
    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      await FirebaseFirestore.instance
          .collection(collection)
          .doc(chatId)
          .update({
        'unreadCount_$userId': unreadCount,
      });

      ReleaseLogger.log('✅ [ChatStreamManager] Contador actualizado en Firestore: ${isGroup ? 'grupo' : 'chat'} $chatId, user $userId, count $unreadCount');
    } catch (e) {
      ReleaseLogger.error('❌ Error actualizando contador en Firestore: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CLEARED AT CACHE
  // ═══════════════════════════════════════════════════════════════

  /// Obtener clearedAt timestamp con cache (evita queries redundantes)
  Future<Timestamp?> _getClearedAtCached(String chatId, String? userId, bool isGroup) async {
    if (userId == null) return null;

    final cacheKey = '${chatId}_$userId';

    // Si ya está en cache, retornar inmediatamente
    if (_clearedAtCache.containsKey(cacheKey)) {
      ReleaseLogger.log('✅ [Cache] clearedAt para $cacheKey obtenido del cache');
      return _clearedAtCache[cacheKey];
    }

    // Si no está en cache, hacer query y cachear
    try {
      final collection = isGroup ? 'groups_v2' : 'chats';
      final chatDoc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(chatId)
          .get();

      if (chatDoc.exists) {
        final data = chatDoc.data();
        final clearedAt = data?['clearedAt_$userId'] as Timestamp?;
        _clearedAtCache[cacheKey] = clearedAt;
        ReleaseLogger.log('📥 [Cache] clearedAt para $cacheKey cacheado');
        return clearedAt;
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo clearedAt: $e');
    }

    // Cachear null si no existe
    _clearedAtCache[cacheKey] = null;
    return null;
  }

  /// Invalidar cache de clearedAt cuando se limpia el chat
  void invalidateClearedAtCache(String chatId, String userId) {
    final cacheKey = '${chatId}_$userId';
    _clearedAtCache.remove(cacheKey);
    ReleaseLogger.log('🗑️ [Cache] clearedAt para $cacheKey invalidado');
  }

  /// Dispose completo
  // ✅ FIX #1: Método para establecer chat actual (actualiza MemoryCache + SharedPreferences)
  Future<void> setCurrentChat(String chatId) async {
    // ✅ CRÍTICO: Actualizar MemoryCache PRIMERO (inmediato, sin I/O)
    _cachedCurrentChatId = chatId;
    ReleaseLogger.log('📍 [MemoryCache] Chat actual establecido: $chatId');

    // ✅ Persistir en background (no bloquear)
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('current_chat_id', chatId);
      ReleaseLogger.log('💾 [SharedPrefs] Chat actual guardado: $chatId');
    }).catchError((error) {
      ReleaseLogger.error('❌ Error guardando chat actual en SharedPrefs: $error');
    });
  }

  // ✅ FIX #1: Método para limpiar chat actual
  Future<void> clearCurrentChat() async {
    ReleaseLogger.log('🔍 [MemoryCache] Limpiando chat actual: $_cachedCurrentChatId');

    // ✅ CRÍTICO: Limpiar MemoryCache PRIMERO (inmediato, sin I/O)
    _cachedCurrentChatId = null;

    // ✅ Limpiar SharedPreferences en background (no bloquear)
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('current_chat_id');
      ReleaseLogger.log('✅ [SharedPrefs] Chat actual eliminado de SharedPreferences');
    }).catchError((error) {
      ReleaseLogger.error('❌ Error limpiando chat actual: $error');
    });
  }

  // ✅ FIX #4: Método para limpiar todo cuando usuario cierra sesión
  // Previene memory leaks y notificaciones para usuario incorrecto si hay cambio de cuenta
  Future<void> onUserSignOut() async {
    ReleaseLogger.log('🔄 [ChatStreamManager] Usuario cerrando sesión - limpiando listeners y caches');

    // Detener todos los listeners activos
    stopBackgroundStreams();

    // Limpiar todos los caches
    _lastSeenMessageTimestamps.clear();
    _clearedAtCache.clear();
    _prefsCache = null;
    _cachedCurrentChatId = null;

    ReleaseLogger.log('✅ [ChatStreamManager] Limpieza completa de sesión finalizada');
  }

  /// ✅ OPTIMIZACIÓN: Limpiar caches cuando excedan límites de memoria
  /// Previene memory leaks en sesiones largas
  void _cleanupCachesIfNeeded() {
    // Limpiar _processedMessageIds si excede el límite
    if (_processedMessageIds.length > _maxProcessedMessageIds) {
      final toRemove = _processedMessageIds.length - _maxProcessedMessageIds;
      _processedMessageIds = _processedMessageIds.skip(toRemove).toSet();
    }

    // Limpiar _previousReadByState si excede el límite
    if (_previousReadByState.length > _maxCacheEntries) {
      final keysToRemove = _previousReadByState.keys
          .take(_previousReadByState.length - _maxCacheEntries)
          .toList();
      for (final key in keysToRemove) {
        _previousReadByState.remove(key);
      }
    }

    // Limpiar _clearedAtCache si excede el límite
    if (_clearedAtCache.length > _maxCacheEntries) {
      final keysToRemove = _clearedAtCache.keys
          .take(_clearedAtCache.length - _maxCacheEntries)
          .toList();
      for (final key in keysToRemove) {
        _clearedAtCache.remove(key);
      }
    }

    // Limpiar _lastUpdateTimes si excede el límite
    if (_lastUpdateTimes.length > _maxCacheEntries) {
      final keysToRemove = _lastUpdateTimes.keys
          .take(_lastUpdateTimes.length - _maxCacheEntries)
          .toList();
      for (final key in keysToRemove) {
        _lastUpdateTimes.remove(key);
      }
    }

    // ✅ Limpiar _lastEmittedMessageIds si excede el límite
    if (_lastEmittedMessageIds.length > _maxCacheEntries) {
      final keysToRemove = _lastEmittedMessageIds.keys
          .take(_lastEmittedMessageIds.length - _maxCacheEntries)
          .toList();
      for (final key in keysToRemove) {
        _lastEmittedMessageIds.remove(key);
      }
    }
  }

  void dispose() {
    stopBackgroundStreams();
    _chatListController.close();

    // Close all cache change controllers
    for (final controller in _cacheChangeControllers.values) {
      controller.close();
    }
    _cacheChangeControllers.clear();

    _chatIsGroupMap.clear();
    _lastUpdateTimes.clear();
    _clearedAtCache.clear();
    _previousReadByState.clear();
    _processedMessageIds.clear();
    _lastEmittedMessageIds.clear(); // ✅ Cleanup emitted message IDs
    _prefsCache = null;
    _cachedCurrentChatId = null;
  }
}