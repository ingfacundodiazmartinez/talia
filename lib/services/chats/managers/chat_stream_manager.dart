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
import '../../read_receipts_service.dart';
import '../../local_unread_count_service.dart';
import '../../../notification_service.dart';
import '../../contact_photo_cache_service.dart';
import '../../app_state_service.dart';
import '../../message_status_helper.dart';
import '../chat_preferences_cache.dart';

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
  // ❌ REMOVED: _deduplicationService (DATA-ONLY strategy - FCM handles all)

  // Background stream management
  bool _isBackgroundStreamActive = false;
  final Map<String, StreamSubscription> _messageStreamSubscriptions = {};
  final Map<String, bool> _chatIsGroupMap = {}; // Mapea chatId -> isGroup
  StreamSubscription? _chatListSubscription;

  // ✅ GLOBAL MESSAGE LISTENER: Detecta mensajes en TODOS los chats para notificaciones instantáneas
  Set<String> _processedMessageIds = {}; // Evitar procesar el mismo mensaje múltiples veces

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

  // ✅ V2: Cache para timestamps de read receipts del recipient
  final Map<String, ({DateTime? lastOpenedAt, DateTime? lastReceivedAt})> _recipientTimestampsCache = {};

  // ✅ V2: Subscripciones a chat documents para detectar cambios en lastOpenedAt
  final Map<String, StreamSubscription<DocumentSnapshot>> _chatDocSubscriptions = {};

  // ✅ NUEVO: Cache de SharedPreferences para evitar delays de I/O (2-5 segundos)
  SharedPreferences? _prefsCache;

  // ✅ FIX #1: MemoryCache para currentChatId (evita race condition de I/O)
  // Esta variable en memoria elimina completamente el I/O bloqueante en path crítico
  String? _cachedCurrentChatId;


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
    ReleaseLogger.log('🔍 [ensureListenerActive] Llamado para chat $chatId (isGroup: $isGroup)');

    // If controller already exists, listener is already active
    if (_messageControllers.containsKey(chatId)) {
      // ✅ DEBUG: Verificar si el stream subscription existe
      final hasSubscription = _messageStreamSubscriptions.containsKey(chatId);
      ReleaseLogger.log('⚠️ [ensureListenerActive] Controller YA existe para $chatId - hasSubscription: $hasSubscription');

      // ✅ FIX: Si el controller existe pero NO tiene subscription, recrear el listener
      if (!hasSubscription) {
        ReleaseLogger.log('🔄 [ensureListenerActive] Recreando listener porque subscription no existe');
        final controller = _messageControllers[chatId]!;
        _setupMessageStream(chatId, controller, isGroup: isGroup);
      }
      return;
    }

    // Create controller and start listener
    ReleaseLogger.log('🆕 [ensureListenerActive] Creando NUEVO controller para $chatId');
    final controller = StreamController<List<ChatMessage>>.broadcast();
    _messageControllers[chatId] = controller;
    _chatIsGroupMap[chatId] = isGroup;

    _setupMessageStream(chatId, controller, isGroup: isGroup);
    _activeStreamCount++;

    ReleaseLogger.log('✅ [ensureListenerActive] Listener iniciado para chat $chatId (isGroup: $isGroup)');
  }

  /// Configurar stream de mensajes desde Firestore
  Future<void> _setupMessageStream(String chatId, StreamController<List<ChatMessage>> controller, {bool isGroup = false}) async {
    ReleaseLogger.log('⚙️ [_setupMessageStream] Configurando stream para chat $chatId (isGroup: $isGroup)');

    // ✅ FIX: Obtener clearedAt con cache (evita queries redundantes)
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    ReleaseLogger.log('⚙️ [_setupMessageStream] currentUserId: ${currentUserId?.substring(0, 8)}...');
    final clearedAt = await _getClearedAtCached(chatId, currentUserId, isGroup);

    final firestoreStream = _messageRepository.watchMessages(
      chatId: chatId,
      isGroup: isGroup,
      limit: 50,
      clearedAt: clearedAt, // ✅ Pasar clearedAt para filtrar
    );

    ReleaseLogger.log('⚙️ [_setupMessageStream] Stream de Firestore creado, configurando subscription...');

    final subscription = firestoreStream.listen(
      (snapshot) async {
        try {
          ReleaseLogger.log('🔥 [MessageStream] Snapshot recibido para chat $chatId con ${snapshot.docs.length} docs');

          // ✅ FIX: Siempre actualizar lastUpdateTimes al inicio
          _lastUpdateTimes[chatId] = DateTime.now();

          // ✅ FIX: Get current user ID for status calculation
          final currentUserId = FirebaseAuth.instance.currentUser?.uid;

          // Convertir QuerySnapshot a List<ChatMessage>
          // ✅ FIX: Filtrar mensajes pendientes de contactos - NO deben llegar al cache
          var messages = snapshot.docs
              .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
              .where((msg) {
                // Mensajes propios: siempre incluir
                if (msg.senderId == currentUserId) return true;
                // Mensajes de contactos: solo si están aprobados o bloqueados (no pending/null)
                return msg.moderationStatus == ModerationStatus.approved ||
                       msg.moderationStatus == ModerationStatus.blocked;
              })
              .toList();

          // ✅ V2 ARCHITECTURE: Recalcular status de mensajes propios usando timestamps del chat doc
          // Solo para chats 1-1 (grupos mantienen lógica de readBy[])
          if (!isGroup && currentUserId != null) {
            final recipientTimestamps = await _getRecipientTimestamps(chatId, currentUserId);

            if (recipientTimestamps.lastOpenedAt != null || recipientTimestamps.lastReceivedAt != null) {
              messages = messages.map((msg) {
                // Solo recalcular status de mensajes propios
                if (msg.senderId != currentUserId) return msg;

                final newStatus = MessageStatusHelper.calculateStatusV2(
                  messageTimestamp: msg.timestamp?.toDate(),
                  senderId: msg.senderId,
                  recipientLastOpenedAt: recipientTimestamps.lastOpenedAt,
                  recipientLastReceivedAt: recipientTimestamps.lastReceivedAt,
                );

                // Solo crear copia si el status cambió
                if (newStatus != msg.status) {
                  return msg.copyWith(status: newStatus);
                }
                return msg;
              }).toList();
            }
          }

          // ✅ CRITICAL: Save to Hive cache (persistent) - CACHE-FIRST ARCHITECTURE
          await MessageCacheService().saveMessages(chatId, messages);
          ReleaseLogger.log('Saved ${messages.length} messages to Hive cache for chat $chatId');

          // ✅ V2 ARCHITECTURE: Confirmar recepción de mensajes para eliminación por CF
          // Solo para chats 1-1 (grupos usan TTL de 7 días)
          if (!isGroup && messages.isNotEmpty) {
            // Obtener el timestamp más reciente de los mensajes recibidos
            final latestTimestamp = messages
                .where((m) => m.timestamp != null)
                .map((m) => m.timestamp!.toDate())
                .fold<DateTime?>(null, (prev, curr) =>
                    prev == null || curr.isAfter(prev) ? curr : prev);

            if (latestTimestamp != null) {
              await ReadReceiptsService().confirmMessagesReceived(
                chatId: chatId,
                latestMessageTimestamp: latestTimestamp,
                isGroupChat: false,
              );
            }
          }

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

          // ✅ FIX TTL: Usar merge en lugar de replace para preservar mensajes
          // cuando Firestore TTL los elimina, siguen visibles en el dispositivo
          _cacheManager.mergeCacheForChat(chatId, messages);

          // Combinar con cache optimista
          final finalMessages = _cacheManager.getCachedMessages(chatId);

          // Track IDs emitidos para _handleNewMessagesDetected
          final currentMessageIds = finalMessages.map((m) => m.id).toSet();

          // ✅ NUEVA LÓGICA CENTRALIZADA: Detectar mensajes nuevos y actualizar contadores
          await _handleNewMessagesDetected(chatId, messages, isGroup: isGroup);

          // ✅ FIX: Siempre emitir mensajes de Firestore
          // La deduplicación por ID causaba que cambios de contenido (moderationStatus, etc.) no se emitieran
          // Flutter maneja eficientemente los rebuilds con su propio diffing
          _lastEmittedMessageIds[chatId] = currentMessageIds;

          if (!controller.isClosed) {
            controller.add(finalMessages);
            ReleaseLogger.log('📤 [ChatStreamManager] Emitidos ${finalMessages.length} mensajes para $chatId');
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
    ReleaseLogger.log('✅ [_setupMessageStream] Subscription guardada para chat $chatId');

    // ✅ V2: Escuchar cambios en el chat document para detectar actualizaciones de lastOpenedAt
    // Esto permite actualizar el status de mensajes cuando el recipient abre el chat
    if (!isGroup) {
      _setupChatDocListener(chatId, controller);
    }
  }

  /// ✅ V2: Configurar listener para el chat document
  /// Detecta cambios en lastOpenedAt_{recipient} y re-emite mensajes con status actualizado
  void _setupChatDocListener(String chatId, StreamController<List<ChatMessage>> controller) {
    // Cancelar subscription anterior si existe
    _chatDocSubscriptions[chatId]?.cancel();

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    final chatDocStream = FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .snapshots();

    final subscription = chatDocStream.listen(
      (snapshot) async {
        if (!snapshot.exists) {
          ReleaseLogger.log('📧 [V2-DEBUG] Chat doc no existe para $chatId');
          return;
        }
        if (controller.isClosed) {
          ReleaseLogger.log('📧 [V2-DEBUG] Controller cerrado para $chatId');
          return;
        }

        final data = snapshot.data()!;
        final participants = List<String>.from(data['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) {
          ReleaseLogger.log('📧 [V2-DEBUG] otherUserId vacío para $chatId');
          return;
        }

        // Obtener nuevos timestamps del recipient
        final newLastOpenedAt = (data['lastOpenedAt_$otherUserId'] as Timestamp?)?.toDate();
        final newLastReceivedAt = (data['lastReceivedAt_$otherUserId'] as Timestamp?)?.toDate();

        // Comparar con cache - Re-emitir cuando cambia lastOpenedAt O lastReceivedAt
        final cached = _recipientTimestampsCache[chatId];
        final lastOpenedAtChanged = cached == null || cached.lastOpenedAt != newLastOpenedAt;
        final lastReceivedAtChanged = cached == null || cached.lastReceivedAt != newLastReceivedAt;

        // Log SIEMPRE que recibimos un snapshot
        final truncChatId = chatId.length > 12 ? chatId.substring(0, 12) : chatId;
        ReleaseLogger.log('📧 [V2-DEBUG] Snapshot recibido $truncChatId: lastOpenedAt=$newLastOpenedAt cached=${cached?.lastOpenedAt} changed=$lastOpenedAtChanged');

        // Siempre actualizar cache
        _recipientTimestampsCache[chatId] = (
          lastOpenedAt: newLastOpenedAt,
          lastReceivedAt: newLastReceivedAt,
        );

        // ✅ FIX: Re-emitir si lastOpenedAt O lastReceivedAt cambió
        // lastReceivedAt: pending → delivered
        // lastOpenedAt: delivered → read
        final shouldReemit = (lastOpenedAtChanged && newLastOpenedAt != null) ||
                            (lastReceivedAtChanged && newLastReceivedAt != null);

        if (shouldReemit) {
          ReleaseLogger.log('📧 [V2] lastOpenedAt cambió para chat $chatId - recalculando status');
          ReleaseLogger.log('📧 [V2] newLastOpenedAt=$newLastOpenedAt newLastReceivedAt=$newLastReceivedAt');

          // Re-emitir mensajes del cache con status actualizado
          // ✅ Usar _cacheManager para mantener consistencia con el stream normal
          final cachedMessages = _cacheManager.getCachedMessages(chatId);
          ReleaseLogger.log('📧 [V2] cachedMessages count=${cachedMessages.length}, controllerClosed=${controller.isClosed}');

          if (cachedMessages.isNotEmpty && !controller.isClosed) {
            // Recalcular status de mensajes propios
            int statusChangedCount = 0;
            final updatedMessages = cachedMessages.map((msg) {
              if (msg.senderId != currentUserId) return msg;

              final newStatus = MessageStatusHelper.calculateStatusV2(
                messageTimestamp: msg.timestamp?.toDate(),
                senderId: msg.senderId,
                recipientLastOpenedAt: newLastOpenedAt,
                recipientLastReceivedAt: newLastReceivedAt,
              );

              if (newStatus != msg.status) {
                final truncId = msg.id.length > 8 ? msg.id.substring(0, 8) : msg.id;
                ReleaseLogger.log('📧 [V2] ✅ Mensaje $truncId: ${msg.status} → $newStatus (ts=${msg.timestamp?.toDate()})');
                statusChangedCount++;
                return msg.copyWith(status: newStatus);
              }
              return msg;
            }).toList();

            if (statusChangedCount == 0) {
              // Debug: mostrar por qué no hubo cambios con MÁXIMO detalle
              final myMsgs = cachedMessages.where((m) => m.senderId == currentUserId).toList();
              ReleaseLogger.log('📧 [V2] ⚠️ No hubo cambios de status. Mis mensajes: ${myMsgs.length}');
              ReleaseLogger.log('📧 [V2] lastOpenedAt ms: ${newLastOpenedAt?.millisecondsSinceEpoch} isUtc=${newLastOpenedAt?.isUtc}');
              for (final msg in myMsgs.take(3)) {
                final truncId = msg.id.length > 8 ? msg.id.substring(0, 8) : msg.id;
                final ts = msg.timestamp?.toDate();
                final tsMs = ts?.millisecondsSinceEpoch;
                final openedMs = newLastOpenedAt?.millisecondsSinceEpoch;
                final isBefore = ts != null && newLastOpenedAt != null ? ts.isBefore(newLastOpenedAt) : null;
                // Comparación manual para debug
                final manualIsBefore = (tsMs != null && openedMs != null) ? tsMs < openedMs : null;
                ReleaseLogger.log('📧 [V2]   - $truncId: status=${msg.status}, ts=$ts (ms=$tsMs, utc=${ts?.isUtc}), isBefore=$isBefore, manualIsBefore=$manualIsBefore');
              }
            } else {
              ReleaseLogger.log('📧 [V2] ✅ Actualizados $statusChangedCount mensajes a seen/delivered');

              // ✅ FIX: Actualizar el cache con los status recalculados
              // Sin esto, la UI que usa cache-first no ve los cambios
              _cacheManager.updateCacheForChat(chatId, updatedMessages);
              ReleaseLogger.log('📧 [V2] ✅ Cache actualizado con nuevos status');
            }

            controller.add(updatedMessages);
          }
        }
      },
      onError: (error) {
        ReleaseLogger.error('❌ [V2] Error en chat doc listener: $error');
      },
    );

    _chatDocSubscriptions[chatId] = subscription;
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

      // ❌ REMOVED: Heartbeat timer ya no es necesario
      // DATA-ONLY strategy: StreamDetector NO muestra notificaciones
      // Por lo tanto, NO debemos decirle a iOS que estamos "healthy"
      // (si lo hacemos, iOS suprime FCM pensando que StreamDetector mostrará la notificación)
      // _startHeartbeatTimer();
    } catch (e) {
      ReleaseLogger.error('❌ [ChatDocsListener] Error iniciando listeners: $e');
    }
  }

  // ❌ DEPRECATED: Heartbeat methods ya no se usan (DATA-ONLY strategy)
  // Stream Detector no muestra notificaciones, FCM es el único punto de entrada
  // void _startHeartbeatTimer() { ... }
  // Future<void> _sendHeartbeat() async { ... }

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
      final lastMessageId = chatData['lastMessageId'] as String?;

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

      // ✅ Verificar si ya procesamos este mensaje (evita duplicados)
      if (_processedNotificationMessageIds.contains(lastMessageId)) {
        ReleaseLogger.log('⏭️ [ChatDocsListener] Mensaje $lastMessageId ya procesado - SKIP');
        return;
      }

      // Marcar como procesado ANTES de mostrar notificación
      _processedNotificationMessageIds.add(lastMessageId);

      // ✅ SIEMPRE incrementar contador LOCAL (Cloud Functions NO incrementan)
      await LocalUnreadCountService().incrementUnreadCount(chatId);
      await _unreadService.updateBadgeCount();
      ReleaseLogger.log('📊 [ChatDocsListener] Unread count incrementado para $chatId');

      // ═══════════════════════════════════════════════════════════════
      // ⚡ STREAM DETECTOR: Mostrar notificación instantánea (<100ms)
      // SOLO EN FOREGROUND - En background, FCM/NSE manejan la notificación
      // ═══════════════════════════════════════════════════════════════

      final isInForeground = AppStateService().isInForeground;

      if (!isInForeground) {
        ReleaseLogger.log(
          '📱 [ChatDocsListener] App en BACKGROUND - unread incrementado, FCM maneja notificación',
        );
        return;
      }

      // ✅ FIX: Solo mostrar notificaciones para mensajes POSTERIORES a cuando la app volvió a foreground
      // Esto evita mostrar notificaciones de mensajes que llegaron en background (FCM ya los mostró)
      final prefs = await _prefs; // Usa cache para evitar delay de I/O
      final resumedAt = prefs.getInt('app_resumed_foreground_at');
      final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;

      if (resumedAt != null && lastMessageTime != null) {
        final resumedDateTime = DateTime.fromMillisecondsSinceEpoch(resumedAt);
        final messageDateTime = lastMessageTime.toDate();

        // Si el mensaje es ANTERIOR a cuando volvimos a foreground, fue recibido en background
        // FCM/iOS ya mostró esa notificación, no duplicar
        if (messageDateTime.isBefore(resumedDateTime)) {
          ReleaseLogger.log(
            '⏭️ [StreamDetector] Mensaje anterior a foreground resume (${messageDateTime.toIso8601String()} < ${resumedDateTime.toIso8601String()}) - SKIP',
          );
          return;
        }
      }

      ReleaseLogger.log(
        '🔍 [StreamDetector] Procesando lastMessageId = $lastMessageId',
      );
      final lastMessage = chatData['lastMessage'] as String? ?? '';
      final lastMessageType = chatData['lastMessageType'] as String?;

      // ✅ FIX: Filtrar mensajes de llamada
      // - answered_call: NO mostrar notificación (la llamada se concretó, no es necesario)
      // - missed_call: Solo mostrar al RECEPTOR (senderId es el caller)
      if (lastMessageType == 'answered_call') {
        ReleaseLogger.log(
          '⏭️ [StreamDetector] Llamada contestada - NO mostrar notificación',
        );
        return;
      }

      if (lastMessageType == 'missed_call') {
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        if (senderId == currentUserId) {
          // Soy el caller, no necesito notificación de que mi llamada no fue contestada
          ReleaseLogger.log(
            '⏭️ [StreamDetector] Llamada perdida pero soy el caller - NO mostrar notificación',
          );
          return;
        }
        // Soy el receptor, sí mostrar notificación de llamada perdida
        ReleaseLogger.log(
          '📞 [StreamDetector] Llamada perdida y soy el receptor - SÍ mostrar notificación',
        );
      }

      // Determinar el preview del mensaje
      String messagePreview;
      if (lastMessageType == 'image') {
        messagePreview = '📷 Imagen';
      } else if (lastMessageType == 'video') {
        messagePreview = '🎥 Video';
      } else if (lastMessageType == 'audio') {
        messagePreview = '🎤 Audio';
      } else {
        messagePreview = lastMessage.isNotEmpty ? lastMessage : 'Mensaje nuevo';
      }

      ReleaseLogger.log(
        '⚡ [ChatDocsListener] Mostrando notificación instantánea para mensaje $lastMessageId',
      );

      // Crear ChatMessage virtual con datos del documento
      final virtualMessage = ChatMessage(
        id: lastMessageId,
        senderId: senderId,
        text: messagePreview,
        type: lastMessageType,
      );

      // Mostrar notificación instantánea
      await _showInstantNotification(
        chatId: chatId,
        message: virtualMessage,
        isGroup: isGroup,
      );

    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [ChatDocsListener] Error en _fetchAndShowLatestMessage: $e');
      ReleaseLogger.error('Stack trace: $stackTrace');
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

      // ❌ DEPRECATED: Heartbeat timer ya no se usa
      // _heartbeatTimer?.cancel();
      // _heartbeatTimer = null;

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
    _recipientTimestampsCache.remove(chatId); // ✅ V2: Cleanup recipient timestamps
    _chatDocSubscriptions[chatId]?.cancel(); // ✅ V2: Cleanup chat doc listener
    _chatDocSubscriptions.remove(chatId);
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
        ReleaseLogger.log('📱 [ChatStreamManager] Chat activo detectado: $chatId');

        // ✅ SIMPLIFICADO: Reseteamos el rate limit y actualizamos el contador
        _lastUpdateTimes.remove(chatId);

        // Poner contador en 0 automáticamente
        await _updateUnreadCountInFirestore(chatId, currentUserId, 0, isGroup: isGroup);
        await _unreadService.updateBadgeCount();

        // ✅ FIX CRÍTICO: Marcar mensajes como leídos cuando el chat está activo
        // Esto es necesario porque el ChatController puede no estar procesando
        // correctamente los mensajes en tiempo real (filtros de moderación, etc.)
        ReleaseLogger.log('📖 [ChatStreamManager] Marcando mensajes como leídos para chat activo $chatId');
        await ReadReceiptsService().markMessagesAsSeen(
          chatId: chatId,
          isGroupChat: isGroup,
        );

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

      // ✅ NOTA: El incremento del unread count se hace en _fetchAndShowLatestMessage
      // (ChatDocsListener) para evitar duplicados. Este listener de mensajes
      // solo se usa para tracking interno.
      ReleaseLogger.log('📊 [ChatStreamManager] Detectados $newUnreadMessages mensajes nuevos (increment en ChatDocsListener)');

      // ⚡ NOTIFICACIÓN INSTANTÁNEA: Mostrar notificación local para el mensaje más reciente
      // Esto evita el delay de 2-5 segundos de las Cloud Functions
      // El listener de Firestore detecta mensajes en <100ms
      // ✅ FIX #18: Removed excessive DEBUG logs

      // ═══════════════════════════════════════════════════════════════
      // ⚠️ NOTIFICACIONES: Manejadas por ChatDocsListener (_fetchAndShowLatestMessage)
      // Este método solo actualiza cache/UI, NO muestra notificaciones
      // Esto evita duplicados entre los dos sistemas de detección
      // ═══════════════════════════════════════════════════════════════

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

  /// Obtener clearedAt timestamp desde Hive (ChatPreferencesCache)
  /// ✅ FIX: Usar cache local en lugar de Firestore para consistencia con ClearChatService
  Future<Timestamp?> _getClearedAtCached(String chatId, String? userId, bool isGroup) async {
    if (userId == null) return null;

    final cacheKey = '${chatId}_$userId';

    // Si ya está en memory cache, retornar inmediatamente
    if (_clearedAtCache.containsKey(cacheKey)) {
      return _clearedAtCache[cacheKey];
    }

    // Obtener de Hive (ChatPreferencesCache) - donde ClearChatService guarda
    try {
      final clearedAtDateTime = ChatPreferencesCache().getClearedAt(chatId);

      if (clearedAtDateTime != null) {
        final clearedAtTimestamp = Timestamp.fromDate(clearedAtDateTime);
        _clearedAtCache[cacheKey] = clearedAtTimestamp;
        ReleaseLogger.log('📥 [Cache] clearedAt para $chatId obtenido de Hive: $clearedAtDateTime');
        return clearedAtTimestamp;
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo clearedAt de Hive: $e');
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

  /// ✅ V2: Obtener timestamps del recipient para calcular status de mensajes
  /// Retorna (lastOpenedAt, lastReceivedAt) del otro participante del chat
  Future<({DateTime? lastOpenedAt, DateTime? lastReceivedAt})> _getRecipientTimestamps(
    String chatId,
    String? currentUserId,
  ) async {
    if (currentUserId == null) return (lastOpenedAt: null, lastReceivedAt: null);

    final cacheKey = chatId;

    // Si ya está en cache, retornar inmediatamente
    if (_recipientTimestampsCache.containsKey(cacheKey)) {
      return _recipientTimestampsCache[cacheKey]!;
    }

    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .get();

      if (chatDoc.exists) {
        final data = chatDoc.data()!;

        // Obtener el otro participante
        final participants = List<String>.from(data['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) {
          _recipientTimestampsCache[cacheKey] = (lastOpenedAt: null, lastReceivedAt: null);
          return (lastOpenedAt: null, lastReceivedAt: null);
        }

        // Obtener timestamps del recipient
        final lastOpenedAt = (data['lastOpenedAt_$otherUserId'] as Timestamp?)?.toDate();
        final lastReceivedAt = (data['lastReceivedAt_$otherUserId'] as Timestamp?)?.toDate();

        final result = (lastOpenedAt: lastOpenedAt, lastReceivedAt: lastReceivedAt);
        _recipientTimestampsCache[cacheKey] = result;
        ReleaseLogger.log('📥 [V2 Cache] Timestamps del recipient cacheados para $cacheKey');
        return result;
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo timestamps del recipient: $e');
    }

    _recipientTimestampsCache[cacheKey] = (lastOpenedAt: null, lastReceivedAt: null);
    return (lastOpenedAt: null, lastReceivedAt: null);
  }

  /// ✅ V2: Invalidar cache de timestamps cuando cambian
  void invalidateRecipientTimestampsCache(String chatId) {
    _recipientTimestampsCache.remove(chatId);
    ReleaseLogger.log('🗑️ [V2 Cache] Timestamps del recipient para $chatId invalidados');
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

  // ═══════════════════════════════════════════════════════════════
  // INSTANT NOTIFICATIONS - StreamDetector
  // ═══════════════════════════════════════════════════════════════

  /// ⚡ Mostrar notificación instantánea usando NotificationService
  ///
  /// Este método es llamado cuando se detecta un nuevo mensaje vía Firestore listener.
  /// La ventaja sobre FCM es que tiene ~100ms de latencia vs 2-5 segundos de FCM.
  Future<void> _showInstantNotification({
    required String chatId,
    required ChatMessage message,
    required bool isGroup,
  }) async {
    try {
      // ✅ CHECK MUTED: No mostrar notificación si el chat está silenciado
      if (ChatPreferencesCache().isMuted(chatId)) {
        ReleaseLogger.log(
          '🔇 [StreamDetector] Chat $chatId silenciado - SKIP notificación',
          tag: 'ChatStreamManager',
        );
        return;
      }

      final cacheService = ContactPhotoCacheService();

      // 1. Obtener nombre del remitente (alias > nombre cacheado > query Firestore)
      String senderName = cacheService.getDisplayName(message.senderId, 'Usuario');
      String? senderPhotoUrl = cacheService.getPhotoUrl(message.senderId);

      // Si no hay datos en cache, hacer query rápido a Firestore
      if (senderName == 'Usuario' || senderPhotoUrl == null) {
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(message.senderId)
              .get();

          if (userDoc.exists) {
            final userData = userDoc.data();
            if (senderName == 'Usuario') {
              senderName = userData?['name'] ?? userData?['displayName'] ?? 'Usuario';
            }
            senderPhotoUrl ??= userData?['photoURL'] as String?;
          }
        } catch (e) {
          ReleaseLogger.error('⚠️ [StreamDetector] Error fetching user data: $e');
        }
      }

      // 2. Aplicar alias si existe
      final alias = cacheService.getAlias(message.senderId);
      if (alias != null && alias.isNotEmpty) {
        senderName = alias;
      }

      // 3. Obtener nombre del grupo si aplica
      String? groupName;
      if (isGroup) {
        try {
          final groupDoc = await FirebaseFirestore.instance
              .collection('groups_v2')
              .doc(chatId)
              .get();

          if (groupDoc.exists) {
            groupName = groupDoc.data()?['name'] as String? ?? 'Grupo';
          }
        } catch (e) {
          ReleaseLogger.error('⚠️ [StreamDetector] Error fetching group name: $e');
          groupName = 'Grupo';
        }
      }

      // 4. Obtener texto del mensaje
      final messageText = message.preview;

      // 5. Verificar si estamos en foreground
      final isInForeground = AppStateService().isInForeground;

      if (isInForeground) {
        // ✅ FOREGROUND: Mostrar notificación local igual que background
        ReleaseLogger.log(
          '🔔 [StreamDetector] Mostrando notificación local: $senderName - $messageText',
          tag: 'ChatStreamManager',
        );

        await NotificationService().showLocalChatNotification(
          senderId: message.senderId,
          senderName: senderName,
          messageText: messageText,
          chatId: chatId,
          messageId: message.id,
          isGroup: isGroup,
          groupName: groupName,
          senderPhotoUrl: senderPhotoUrl,
        );

        ReleaseLogger.log(
          '✅ [StreamDetector] Notificación local mostrada para mensaje ${message.id.substring(0, 8)}...',
          tag: 'ChatStreamManager',
        );
      } else {
        // ✅ BACKGROUND: No mostrar nada - FCM se encarga
        ReleaseLogger.log(
          '📱 [StreamDetector] App en background - FCM manejará la notificación',
          tag: 'ChatStreamManager',
        );
      }
    } catch (e, stackTrace) {
      ReleaseLogger.error(
        '❌ [StreamDetector] Error mostrando notificación instantánea: $e',
        tag: 'ChatStreamManager',
      );
      ReleaseLogger.error('Stack: $stackTrace');
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
    _recipientTimestampsCache.clear(); // ✅ V2: Cleanup recipient timestamps
    _previousReadByState.clear();
    _processedMessageIds.clear();
    _lastEmittedMessageIds.clear(); // ✅ Cleanup emitted message IDs

    // ✅ V2: Cancelar todas las subscripciones de chat documents
    for (final sub in _chatDocSubscriptions.values) {
      sub.cancel();
    }
    _chatDocSubscriptions.clear();

    _prefsCache = null;
    _cachedCurrentChatId = null;
  }
}