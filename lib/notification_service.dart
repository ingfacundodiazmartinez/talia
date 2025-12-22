import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' as scheduler;
import 'firebase_options.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:image/image.dart' as img;
import 'constants/notification_types.dart';
import 'services/notification_filter.dart';
import 'services/callkit_service.dart';
import 'services/voip_service.dart';
import 'services/app_state_service.dart';
import 'services/location_service.dart';
import 'services/notification_tracking_service.dart';
import 'services/notification_preferences_service.dart';
import 'services/story_service_refactored.dart'; // ✅ FIX #11: Para refresh de stories (también exporta StoryStatus)
import 'services/stories/story_orchestrator.dart'; // ✅ FIX #10: Para actualización inmediata de cache
import 'services/chats/chat_services.dart'; // ✅ Para verificar mute de chats/grupos
import 'utils/release_logger.dart';
// ❌ REMOVED (DATA-ONLY): notification_deduplication_service, local_unread_count_service
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:permission_handler/permission_handler.dart';
// V2 Call System imports
import 'calls_v2/controllers/call_controller.dart' as calls_v2;
import 'calls_v2/screens/agora_call_screen.dart';
import 'calls_v2/services/call_state_cache_service.dart';

// ═══════════════════════════════════════════════════════════════
// 🔥 BACKGROUND MESSAGE HANDLER (CRITICAL FCM FIX)
// ═══════════════════════════════════════════════════════════════
//
// MUST BE AT TOP LEVEL: Esta función debe estar fuera de cualquier clase
// para que Flutter pueda accederla desde main.dart
//
// REGISTRADO EN: main.dart después de Firebase.initializeApp()
// PROBLEMA RESUELTO: Los handlers FCM no se ejecutaban porque estaban mal registrados
//
// ✅ FIXED: Cache global para deduplicación (accesible desde background handler)
final Set<String> _globalProcessedCallIds = {};

// ❌ REMOVED: SharedPreferences deduplication (DATA-ONLY uses in-memory Set)
// Con DATA-ONLY strategy:
// - Background handler muestra notificación directamente
// - Foreground usa _processedMessageIds en NotificationService
// - No hay necesidad de cross-process dedup

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // ═══════════════════════════════════════════════════════════════
  // DATA-ONLY STRATEGY: Background handler simplificado
  // ═══════════════════════════════════════════════════════════════

  final messageType = message.data['type'];
  final messageId = message.data['messageId'];

  ReleaseLogger.log(
    '🔥 [Background] type=$messageType, messageId=$messageId',
    tag: 'NotificationService',
  );

  // 1. Inicializar Firebase
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
  } catch (e) {
    ReleaseLogger.error('Error init Firebase: $e', tag: 'NotificationService');
  }

  // 2. Filtro: Usuario viendo este chat
  final chatId = message.data['chatId'] ?? '';
  final groupId = message.data['groupId'];
  final targetId = (messageType == 'group_message' || groupId != null)
      ? (groupId ?? chatId)
      : chatId;

  try {
    final prefs = await SharedPreferences.getInstance();
    final currentChatId = prefs.getString('current_chat_id');
    if (currentChatId != null && currentChatId == targetId) {
      ReleaseLogger.log('🚫 [Background] Usuario viendo chat - SKIP', tag: 'NotificationService');
      return;
    }
  } catch (_) {}

  // 3. LLAMADAS: Mostrar CallKit
  if (messageType == 'incoming_call' ||
      messageType == 'video_call' ||
      messageType == 'audio_call' ||
      messageType == 'group_video_call' ||
      messageType == 'group_audio_call' ||
      messageType == 'emergency_call') {

    final callId = message.data['callId'] ?? message.messageId ?? '';

    // Deduplicación
    if (_globalProcessedCallIds.contains(callId)) return;
    _globalProcessedCallIds.add(callId);

    // Verificar timestamp (llamadas > 30s son obsoletas)
    final sentTime = message.sentTime;
    if (sentTime != null && DateTime.now().difference(sentTime).inSeconds > 30) return;

    // Marcar como VoIP handled
    VoIPService().markCallAsVoIPHandled(callId);

    try {
      final isVideo = message.data['isVideo'] == 'true' || message.data['isVideo'] == true;
      final isAudioType = messageType == 'audio_call' || messageType == 'group_audio_call';

      await CallKitService().showIncomingCall(
        callId: callId,
        callerName: message.data['callerName'] ?? 'Usuario',
        callerId: message.data['callerId'] ?? message.data['senderId'] ?? '',
        callerPhotoUrl: message.data['callerPhotoURL'] ?? message.data['senderPhotoUrl'],
        callType: (isAudioType || !isVideo) ? 'audio' : 'video',
        isEmergency: message.data['isEmergency'] == 'true',
        extraData: message.data,
      );
      ReleaseLogger.log('✅ [Background] CallKit mostrado', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ [Background] Error CallKit: $e', tag: 'NotificationService');
    }
    return;
  }

  // 4. CALL CANCELLED: Cerrar CallKit cuando el caller cancela antes de que el receiver conteste
  // ✅ SEGURO: Solo cierra UI de CallKit, NO hace navegación ni pop de stacks
  if (messageType == 'call_cancelled') {
    final callId = message.data['callId'] ?? '';

    // Validar callId antes de proceder
    if (callId.isEmpty) {
      ReleaseLogger.log('⚠️ [Background] call_cancelled sin callId - ignorando', tag: 'NotificationService');
      return;
    }

    ReleaseLogger.log('📵 [Background] Llamada cancelada por caller: $callId', tag: 'NotificationService');

    try {
      // ✅ SOLO cerrar CallKit UI - esto es seguro y no afecta navegación
      // endCall cierra la llamada específica
      // endAllCalls es fallback por si el ID no coincide exactamente
      await FlutterCallkitIncoming.endCall(callId);
      await FlutterCallkitIncoming.endAllCalls();
      ReleaseLogger.log('✅ [Background] CallKit cerrado para llamada cancelada $callId', tag: 'NotificationService');
    } catch (e) {
      // ✅ Error silencioso - no crashear si falla el cierre de CallKit
      // Puede fallar si ya estaba cerrado o el ID no existe
      ReleaseLogger.error('⚠️ [Background] Error cerrando CallKit (no crítico): $e', tag: 'NotificationService');
    }

    // ❌ REMOVED: VoIPService().unmarkVoIPCall(callId)
    // Los singletons NO comparten estado entre background isolate y main isolate
    // El cleanup de VoIP se hará cuando el main isolate detecte el cambio en Firestore
    return;
  }

  // 5. LOCATION REQUEST: Actualizar ubicación silenciosamente
  if (messageType == 'location_request') {
    try {
      await LocationService().updateLocationNow();
      ReleaseLogger.log('✅ [Background] Ubicación actualizada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ [Background] Error ubicación: $e', tag: 'NotificationService');
    }
    return;
  }

  // 5. MENSAJES DE CHAT:
  // - Android: El servicio nativo (MyFirebaseMessagingService) muestra la notificación con MessagingStyle
  // - iOS: Flutter muestra la notificación (con deduplicación)
  if (messageType == 'chat_message' || messageType == 'group_message') {
    if (Platform.isAndroid) {
      // ✅ Android: No hacer nada aquí - el servicio nativo maneja la notificación
      // MyFirebaseMessagingService.kt ya tiene el MessagingStyle correcto
      ReleaseLogger.log('📱 [Background] Android: Servicio nativo manejará la notificación', tag: 'NotificationService');
    } else if (Platform.isIOS) {
      // ═══════════════════════════════════════════════════════════════
      // 🍎 iOS: NSE STRATEGY - NSE maneja deduplicación
      // Cloud Functions envía alert + mutable-content para invocar NSE
      // NSE verifica si StreamDetector ya mostró y suprime si es necesario
      // Si NSE no se invoca, iOS muestra la notificación automáticamente
      // ═══════════════════════════════════════════════════════════════
      ReleaseLogger.log(
        '🍎 [Background iOS] Push recibido - NSE debería haberlo procesado',
        tag: 'NotificationService',
      );
    }
  }

  ReleaseLogger.log(
    '🔥 [BackgroundHandler] FINALIZADO',
    tag: 'NotificationService',
  );
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final NotificationFilter _filter = NotificationFilter();
  final CallKitService _callKit = CallKitService();

  // ✅ MethodChannel para Communication Notifications en iOS
  static const _notificationChannel = MethodChannel(
    'com.talia.chat/notifications',
  );

  // ❌ NSE REMOVED: Con DATA-ONLY strategy, ya no usamos NSE
  // Las notificaciones se manejan directamente en Dart (flutter_local_notifications)

  String? _fcmToken;
  bool _isInitialized = false;
  GlobalKey<NavigatorState>? _navigatorKey;

  // Trackear el chat actual para suprimir notificaciones solo cuando estás dentro de él
  String? _currentChatId;

  // ✅ FIX: Timestamp de cuando la app volvió a foreground (para filtrar notificaciones viejas)
  DateTime? _lastResumedTime;

  // ✅ FIX: Pending navigation for calls accepted from background
  String? _pendingCallNavigation;
  Timer? _navigationTimeoutTimer;
  StreamSubscription<bool>? _appStateSubscription;

  // ✅ V2 NAVIGATION: Callback para navegar a call screen (Android CallKit path)
  Function(String callId, {bool isIncoming})? onNavigateToCall;

  // ✅ FIXED: Deduplicación para evitar notificaciones duplicadas
  final Set<String> _processedCallIds = {};
  final Set<String> _processedMessageIds = {};
  final Set<String> _processedNotificationIds = {};

  // ✅ Listener de Firestore para notificaciones en foreground
  StreamSubscription? _notificationsStreamSubscription;
  DateTime? _notificationsListenerStartTime;

  // Stream para notificar videollamadas entrantes
  final _incomingCallController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingCallStream =>
      _incomingCallController.stream;

  // Stream para notificar cuando se toca una notificación de chat
  final _chatNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get chatNotificationTapStream =>
      _chatNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de emergencia
  final _emergencyNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get emergencyNotificationTapStream =>
      _emergencyNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de solicitud de contacto
  final _contactRequestNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get contactRequestNotificationTapStream =>
      _contactRequestNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de aprobación de historia
  final _storyApprovalNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get storyApprovalNotificationTapStream =>
      _storyApprovalNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de aprobación de grupo
  final _groupApprovalNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get groupApprovalNotificationTapStream =>
      _groupApprovalNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de historia (aprobada/rechazada/reply)
  final _storyNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get storyNotificationTapStream =>
      _storyNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de contacto aprobado
  final _contactApprovedNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get contactApprovedNotificationTapStream =>
      _contactApprovedNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de alerta (actividad/bullying)
  final _alertNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get alertNotificationTapStream =>
      _alertNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de reporte listo
  final _reportNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get reportNotificationTapStream =>
      _reportNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de membresía de grupo aprobada
  final _groupMembershipApprovedNotificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get groupMembershipApprovedNotificationTapStream =>
      _groupMembershipApprovedNotificationTapController.stream;

  // Método público para emitir llamadas entrantes al stream
  void emitIncomingCall(Map<String, dynamic> callData) {
    _incomingCallController.add(callData);
  }

  /// ✅ Getter para el chat actualmente abierto (usado para evitar navegación duplicada)
  String? get currentChatId => _currentChatId;

  // Establecer el chat actual (para suprimir notificaciones solo de ese chat)
  // 🔒 CRITICAL FIX: Cambiar de void async a Future<void> para prevenir race conditions
  // PROBLEMA: SharedPreferences.setString() toma 50-200ms, pero el caller no esperaba
  // RESULTADO: FCM background handler verificaba antes de que SharedPreferences se actualizara
  Future<void> setCurrentChat(String chatId) async {
    _currentChatId = chatId;
    ReleaseLogger.log(
      '📍 Chat actual establecido: $chatId',
      tag: 'NotificationService',
    );

    // ✅ Persistir para background handler - SÍNCRONO para prevenir race condition
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentTime = DateTime.now().millisecondsSinceEpoch;

      await prefs.setString('current_chat_id', chatId);
      // 🔒 TIMESTAMP FILTER: Guardar cuándo el usuario empezó a ver este chat
      // Esto permite filtrar notificaciones de mensajes que llegaron mientras veía el chat
      await prefs.setInt('chat_last_viewed_$chatId', currentTime);
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error guardando chat actual: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Limpiar el chat actual (cuando sales del chat)
  // 🔒 CRITICAL FIX: Usar fire-and-forget para que funcione en dispose()
  // No usar await - el widget puede ser dispuesto antes de que termine
  void clearCurrentChat() {
    ReleaseLogger.log(
      '🔍 [CLEAR] Limpiando chat actual: $_currentChatId',
      tag: 'NotificationService',
    );

    // ✅ INMEDIATO: Limpiar memoria cache PRIMERO (sin I/O)
    _currentChatId = null;

    // ✅ BACKGROUND: Limpiar SharedPreferences en background (fire-and-forget)
    // Usar .then() en lugar de await para que no bloquee dispose()
    SharedPreferences.getInstance().then((prefs) {
      final oldValue = prefs.getString('current_chat_id');
      ReleaseLogger.log(
        '🔍 [CLEAR] Valor ANTES de borrar: $oldValue',
        tag: 'NotificationService',
      );

      prefs.remove('current_chat_id').then((_) {
        ReleaseLogger.log(
          '✅ [CLEAR] Chat actual eliminado exitosamente de SharedPreferences',
          tag: 'NotificationService',
        );
      });
    }).catchError((error) {
      ReleaseLogger.error(
        '❌ Error limpiando chat actual: $error',
        tag: 'NotificationService',
      );
    });
  }

  /// ✅ FIX: Notificar cuando la app vuelve a foreground
  /// Usado para filtrar notificaciones que llegaron durante background
  /// y evitar mostrarlas de nuevo como foreground
  void notifyAppResumed() {
    _lastResumedTime = DateTime.now();
    ReleaseLogger.log(
      '📱 [AppLifecycle] App resumed at $_lastResumedTime',
      tag: 'NotificationService',
    );

    // ✅ Cachear preferencias de notificación para que Android native las lea
    // Esto asegura que las preferencias estén sincronizadas después de background
    NotificationPreferencesService().getPreferences().then((_) {
      ReleaseLogger.log(
        '✅ [AppLifecycle] Preferencias de notificación sincronizadas',
        tag: 'NotificationService',
      );
    }).catchError((e) {
      ReleaseLogger.error(
        '❌ [AppLifecycle] Error sincronizando preferencias: $e',
        tag: 'NotificationService',
      );
    });
  }

  // ❌ NSE FUNCTIONS REMOVED: Con DATA-ONLY strategy, ya no usamos NSE
  // Las notificaciones se manejan directamente en Dart via flutter_local_notifications
  // Ver firebaseMessagingBackgroundHandler() para el flujo unificado

  // Helper para upsert de datos de usuario
  /// Actualizar datos del usuario en Firestore
  /// ✅ FIX: Solo actualiza si el documento ya existe (no crear documento prematuro)
  /// Esto evita interferir con el flujo de ProfileCompletionScreen
  Future<void> _upsertUserData(Map<String, dynamic> data) async {
    final userId = _auth.currentUser?.uid;
    if (userId != null) {
      // Verificar si el usuario existe antes de actualizar
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) {
        // Usuario nuevo - no guardar FCM token aún, esperar a ProfileCompletionScreen
        ReleaseLogger.log(
          '📱 Usuario nuevo, FCM token se guardará después de completar perfil',
          tag: 'NotificationService',
        );
        return;
      }

      // Usuario existente - actualizar datos
      await _firestore.collection('users').doc(userId).update(data);
    }
  }

  /// Inicializar token FCM después del login exitoso
  /// Debe llamarse desde el flujo de autenticación para asegurar que el token se guarde
  Future<void> initializeFCMTokenAfterLogin() async {
    ReleaseLogger.log(
      '🔄 Inicializando FCM token después del login...',
      tag: 'NotificationService',
    );
    await _getFCMToken();

    // ✅ CRÍTICO: Inicializar monitoreo de llamadas entrantes para cancelación automática
    // Esto permite detectar cuando el caller cancela antes de que el receiver conteste
    await _startIncomingCallsMonitoring();
  }

  /// Iniciar monitoreo de llamadas entrantes para cancelación automática
  Future<void> _startIncomingCallsMonitoring() async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      ReleaseLogger.log(
        '🔧 [NotificationService] Iniciando monitoreo de llamadas entrantes para: ${currentUser.uid}',
        tag: 'NotificationService',
      );

      // ✅ Los listeners globales de llamadas se manejan en main.dart via CallsOrchestrator.initializeGlobalListeners()
      ReleaseLogger.log(
        '✅ [NotificationService] Listeners globales de llamadas ya iniciados en main.dart',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [NotificationService] Error iniciando monitoreo de llamadas: $e',
        tag: 'NotificationService',
      );
    }
  }

  // ✅ Helper eliminado: _getCallsOrchestrator() - ya no se usa porque los listeners globales se manejan en main.dart

  /// Verificar si hay usuario autenticado e iniciar monitoreo automáticamente
  Future<void> _checkAndStartCallMonitoring() async {
    try {
      ReleaseLogger.log(
        '🔍 [NotificationService] Verificando estado de autenticación...',
        tag: 'NotificationService',
      );

      final currentUser = _auth.currentUser;
      if (currentUser != null) {
        ReleaseLogger.log(
          '👤 [NotificationService] Usuario autenticado detectado: ${currentUser.uid}',
          tag: 'NotificationService',
        );
        ReleaseLogger.log(
          '🚀 [NotificationService] Iniciando monitoreo automático de llamadas entrantes',
          tag: 'NotificationService',
        );
        await _startIncomingCallsMonitoring();
      } else {
        ReleaseLogger.log(
          '❌ [NotificationService] No hay usuario autenticado - monitoreo se iniciará después del login',
          tag: 'NotificationService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [NotificationService] Error verificando autenticación: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// Limpiar tokens FCM duplicados de otros usuarios
  /// Esto previene que las notificaciones lleguen a usuarios anteriores del mismo dispositivo
  Future<void> _cleanupDuplicateTokens(String newToken) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      ReleaseLogger.log(
        '🧹 Verificando tokens FCM duplicados para: ${newToken.substring(0, 20)}...',
        tag: 'NotificationService',
      );

      // Buscar otros usuarios que tengan el mismo token FCM
      final duplicateUsersQuery = await _firestore
          .collection('users')
          .where('fcmToken', isEqualTo: newToken)
          .get();

      int cleanedCount = 0;
      for (final doc in duplicateUsersQuery.docs) {
        final userId = doc.id;

        // No limpiar el token del usuario actual
        if (userId == currentUserId) continue;

        // Limpiar token del usuario anterior
        await _firestore.collection('users').doc(userId).update({
          'fcmToken': FieldValue.delete(),
          'fcmTokenClearedAt': FieldValue.serverTimestamp(),
          'fcmTokenClearedReason': 'duplicate_token_cleanup',
        });

        cleanedCount++;
        ReleaseLogger.log(
          '🗑️ Token FCM limpiado del usuario anterior: $userId',
          tag: 'NotificationService',
        );
      }

      if (cleanedCount > 0) {
        ReleaseLogger.log(
          '✅ Se limpiaron $cleanedCount tokens FCM duplicados',
          tag: 'NotificationService',
        );
      } else {
        ReleaseLogger.log(
          '✅ No se encontraron tokens FCM duplicados',
          tag: 'NotificationService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        'Error limpiando tokens duplicados: $e',
        tag: 'NotificationService',
      );
      // No hacer throw para no bloquear el flujo principal de registro
    }
  }

  // Inicializar servicio de notificaciones
  /// Set navigator key for navigation from background
  void setNavigatorKey(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    ReleaseLogger.log(
      '✅ Navigator key configurado en NotificationService',
      tag: 'NotificationService',
    );
  }

  /// ✅ CLEAN: Navegar cuando el navigator esté disponible (solución reactiva)
  void _navigateWhenReady(String callId) {
    ReleaseLogger.log(
      '🔄 Programando navegación para $callId',
      tag: 'NotificationService',
    );

    // Limpiar cualquier navegación pendiente anterior
    _cancelPendingNavigation();

    // Guardar como pendiente
    _pendingCallNavigation = callId;

    // Configurar timeout de 10 segundos para evitar navegación zombie
    _navigationTimeoutTimer = Timer(const Duration(seconds: 10), () {
      if (_pendingCallNavigation != null) {
        ReleaseLogger.error(
          '❌ Timeout esperando Navigator para $callId',
          tag: 'NotificationService',
        );
        _pendingCallNavigation = null;
      }
    });

    // Intentar navegar inmediatamente
    if (_navigatorKey?.currentState?.mounted == true) {
      ReleaseLogger.log(
        '✅ Navigator disponible INMEDIATAMENTE',
        tag: 'NotificationService',
      );
      _attemptPendingNavigation();
    } else {
      // Navigator no disponible, esperar al siguiente frame
      ReleaseLogger.log(
        '⏳ Navigator no disponible, esperando frames...',
        tag: 'NotificationService',
      );
      _waitForNavigatorWithFrameCallbacks(0);
    }
  }

  /// Cancelar cualquier navegación pendiente
  void _cancelPendingNavigation() {
    _navigationTimeoutTimer?.cancel();
    _navigationTimeoutTimer = null;
    _pendingCallNavigation = null;
  }

  /// Intentar navegar a la llamada pendiente (sin reintentos)
  void _attemptPendingNavigation() {
    if (_pendingCallNavigation == null) return;

    final callId = _pendingCallNavigation!;

    if (_navigatorKey?.currentState?.mounted == true) {
      ReleaseLogger.log(
        '✅ Navigator disponible - navegando a $callId',
        tag: 'NotificationService',
      );

      _navigatorKey!.currentState!.push(
        MaterialPageRoute(
          builder: (_) => AgoraCallScreen(callId: callId, isIncoming: true),
        ),
      );

      // Limpiar navegación pendiente
      _cancelPendingNavigation();
    } else {
      ReleaseLogger.log(
        '⏳ Navigator no disponible aún para $callId',
        tag: 'NotificationService',
      );
      // No hacer nada - onAppResumed se encargará
    }
  }

  /// Llamar cuando la app vuelva al foreground (solución reactiva)
  void onAppResumed() {
    ReleaseLogger.log(
      '▶️ App resumed - verificando navegación pendiente',
      tag: 'NotificationService',
    );

    if (_pendingCallNavigation == null) return;

    // Usar SchedulerBinding para ejecutar después del frame actual
    // Esto garantiza que el widget tree esté completamente reconstruido
    scheduler.SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduleNavigationAfterBuild();
    });
  }

  /// Programar navegación después de que el build esté completo
  void _scheduleNavigationAfterBuild() {
    if (_pendingCallNavigation == null) return;

    // El widget tree ya se reconstruyó, ahora esperamos al siguiente frame
    // donde el Navigator debería estar disponible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_navigatorKey?.currentState?.mounted == true) {
        _attemptPendingNavigation();
      } else {
        // Si aún no está disponible, esperar al siguiente frame
        // Esto es raro pero puede pasar si hay animaciones complejas
        ReleaseLogger.log(
          '⏳ Esperando siguiente frame para Navigator',
          tag: 'NotificationService',
        );
        _waitForNavigatorWithFrameCallbacks();
      }
    });
  }

  /// Esperar al Navigator usando frame callbacks (máximo 10 frames)
  void _waitForNavigatorWithFrameCallbacks([int frameCount = 0]) {
    if (_pendingCallNavigation == null) return;
    if (frameCount >= 10) {
      ReleaseLogger.error(
        '❌ Navigator no disponible después de 10 frames',
        tag: 'NotificationService',
      );
      _cancelPendingNavigation();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_navigatorKey?.currentState?.mounted == true) {
        _attemptPendingNavigation();
      } else {
        _waitForNavigatorWithFrameCallbacks(frameCount + 1);
      }
    });
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // ✅ FIX: Limpiar current_chat_id stale de SharedPreferences
      // Si la app fue killed mientras un chat estaba abierto, dispose() nunca se llamó
      // y SharedPreferences quedó con un valor viejo que causaría filtrado incorrecto
      try {
        final prefs = await SharedPreferences.getInstance();
        final staleChatId = prefs.getString('current_chat_id');
        if (staleChatId != null) {
          ReleaseLogger.log(
            '🧹 [Initialize] Limpiando current_chat_id stale: $staleChatId',
            tag: 'NotificationService',
          );
          await prefs.remove('current_chat_id');
        }
      } catch (e) {
        ReleaseLogger.error(
          '⚠️ [Initialize] Error limpiando current_chat_id stale: $e',
          tag: 'NotificationService',
        );
      }

      // 1. Background handler registration moved to main.dart
      // IMPORTANTE: El background handler ahora se registra en main.dart después de Firebase.initializeApp
      ReleaseLogger.log(
        '📝 Background handler registration delegated to main.dart',
        tag: 'NotificationService',
      );

      // 2. Solicitar permisos
      await _requestPermissions();

      // 2.1. Desactivar notificaciones push en foreground (iOS)
      // Las custom notifications in-app se encargan de mostrar los mensajes
      await _fcm.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
      ReleaseLogger.log(
        '✅ Notificaciones push desactivadas en foreground (solo custom notifications)',
        tag: 'NotificationService',
      );

      // 3. Configurar notificaciones locales
      await _initializeLocalNotifications();

      // 4. Obtener token FCM
      await _getFCMToken();

      // 5. Inicializar CallKit
      _initializeCallKit();

      // 6. Configurar listeners
      await _setupListeners();

      // 6.1. ✅ FIX KILLED STATE: Procesar navegación pendiente de main.dart
      // Cuando la app está killed y el user toca notificación:
      // - main.dart guarda los datos en SharedPreferences (porque getInitialMessage solo funciona una vez)
      // - Aquí los procesamos para navegar al chat
      await _processPendingNavigation();

      // 6.5. ✅ FIX: Suscribirse a cambios de estado de app para navegación pendiente
      _appStateSubscription = AppStateService().foregroundStateStream.listen((
        isInForeground,
      ) {
        if (isInForeground) {
          ReleaseLogger.log(
            '📱 App volvió a foreground - verificando navegación pendiente',
            tag: 'NotificationService',
          );
          onAppResumed();
        }
      });

      // 7. ✅ CRÍTICO: Verificar si hay usuario autenticado e iniciar monitoreo automáticamente
      await _checkAndStartCallMonitoring();

      // 8. ✅ Iniciar listener de Firestore para notificaciones en foreground
      await _startNotificationsListener();

      _isInitialized = true;
      ReleaseLogger.log(
        '✅ Servicio de notificaciones inicializado (DATA-ONLY strategy)',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error inicializando notificaciones: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Solicitar permisos de notificaciones
  Future<void> _requestPermissions() async {
    try {
      ReleaseLogger.log(
        '🔔 Solicitando permisos de notificaciones...',
        tag: 'NotificationService',
      );

      // ✅ FIX: Android 13+ (API 33) requiere permiso POST_NOTIFICATIONS explícito
      // Sin este permiso, las notificaciones no se muestran en Android 13+
      if (Platform.isAndroid) {
        final androidNotifPermission = await Permission.notification.status;
        ReleaseLogger.log(
          '🤖 [Android] Estado permiso notificaciones: $androidNotifPermission',
          tag: 'NotificationService',
        );

        if (androidNotifPermission.isDenied || androidNotifPermission.isRestricted) {
          ReleaseLogger.log(
            '🤖 [Android] Solicitando permiso POST_NOTIFICATIONS...',
            tag: 'NotificationService',
          );
          final result = await Permission.notification.request();
          ReleaseLogger.log(
            '🤖 [Android] Resultado solicitud: $result',
            tag: 'NotificationService',
          );

          if (result.isPermanentlyDenied) {
            ReleaseLogger.log(
              '⚠️ [Android] Permiso denegado permanentemente - usuario debe habilitarlo manualmente',
              tag: 'NotificationService',
            );
          }
        } else if (androidNotifPermission.isGranted) {
          ReleaseLogger.log(
            '✅ [Android] Permiso de notificaciones ya concedido',
            tag: 'NotificationService',
          );
        }
      }

      // Solicitar permisos de FCM (principalmente para iOS)
      final settings = await _fcm.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      ReleaseLogger.log(
        '📱 Permisos FCM: ${settings.authorizationStatus}',
        tag: 'NotificationService',
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        ReleaseLogger.log('✅ Permisos FCM concedidos', tag: 'NotificationService');
      } else if (settings.authorizationStatus ==
          AuthorizationStatus.provisional) {
        ReleaseLogger.log(
          '⚠️ Permisos FCM provisionales',
          tag: 'NotificationService',
        );
      } else {
        ReleaseLogger.log(
          '❌ Permisos FCM denegados o no decididos: ${settings.authorizationStatus}',
          tag: 'NotificationService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        'Error solicitando permisos: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Configurar notificaciones locales
  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // ✅ Inicializar NotificationTrackingService para auto-dismiss
    NotificationTrackingService().initialize(_localNotifications);

    // Crear canales de notificaciones para Android
    if (Platform.isAndroid) {
      // Canal para notificaciones normales (con sonido)
      const androidChannel = AndroidNotificationChannel(
        'high_importance_channel',
        'Notificaciones Importantes',
        description: 'Canal para notificaciones importantes de Talia',
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      );

      // ✅ FIX #4: Canal para mensajes con sonido (usado por Cloud Functions)
      const messagesChannel = AndroidNotificationChannel(
        'talia_messages',
        'Mensajes',
        description: 'Canal para mensajes de chat con sonido',
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      );

      // ✅ FIX #4: Canal silencioso para usuarios que desactivaron sonido
      const silentChannel = AndroidNotificationChannel(
        'talia_silent',
        'Notificaciones Silenciosas',
        description: 'Canal para notificaciones sin sonido',
        importance: Importance.high,
        enableVibration: false,
        playSound: false,
      );

      // Canal especial para llamadas (máxima prioridad)
      const callsChannel = AndroidNotificationChannel(
        'calls_channel',
        'Llamadas',
        description: 'Canal para llamadas entrantes',
        importance: Importance.max,
        enableVibration: true,
        playSound: true,
        enableLights: true,
      );

      final plugin = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      await plugin?.createNotificationChannel(androidChannel);
      await plugin?.createNotificationChannel(messagesChannel);
      await plugin?.createNotificationChannel(silentChannel);
      await plugin?.createNotificationChannel(callsChannel);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ✅ FIRESTORE LISTENER: Notificaciones en foreground
  // ═══════════════════════════════════════════════════════════════
  //
  // Similar a ChatStreamManager: escucha nuevas notificaciones en Firestore
  // y las muestra como notificación local cuando la app está en foreground.
  // Esto asegura que notificaciones NO-chat (emergencias, stories, etc.)
  // se muestren inmediatamente sin depender de FCM.
  //
  Future<void> _startNotificationsListener() async {
    // Cancelar listener anterior si existe
    await _notificationsStreamSubscription?.cancel();
    _notificationsStreamSubscription = null;

    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      ReleaseLogger.log(
        '⚠️ [NotificationsListener] No hay usuario autenticado - listener no iniciado',
        tag: 'NotificationService',
      );
      return;
    }

    // Guardar tiempo de inicio para filtrar solo notificaciones nuevas
    _notificationsListenerStartTime = DateTime.now();
    _processedNotificationIds.clear();

    ReleaseLogger.log(
      '🔔 [NotificationsListener] Iniciando listener para usuario ${currentUser.uid}',
      tag: 'NotificationService',
    );

    try {
      _notificationsStreamSubscription = _firestore
          .collection('notifications')
          .where('userId', isEqualTo: currentUser.uid)
          .orderBy('timestamp', descending: true)
          .limit(10)
          .snapshots()
          .listen(
        (snapshot) async {
          for (final change in snapshot.docChanges) {
            // Solo procesar documentos nuevos (added)
            if (change.type != DocumentChangeType.added) continue;

            final doc = change.doc;
            final data = doc.data();
            if (data == null) continue;

            // Deduplicación
            if (_processedNotificationIds.contains(doc.id)) continue;
            _processedNotificationIds.add(doc.id);

            // Filtrar notificaciones anteriores al inicio del listener
            final timestamp = data['timestamp'];
            if (timestamp != null) {
              DateTime? notifTime;
              if (timestamp is Timestamp) {
                notifTime = timestamp.toDate();
              } else if (timestamp is int) {
                notifTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
              }

              if (notifTime != null && notifTime.isBefore(_notificationsListenerStartTime!)) {
                continue;
              }
            }

            // Ignorar notificaciones de chat (ya manejadas por ChatStreamManager)
            final type = data['type'] as String? ?? '';
            if (type == 'chat_message' || type == 'message' || type == 'group_message') {
              continue;
            }

            // Ignorar notificaciones de llamadas (ya manejadas por CallKit)
            if (type == 'incoming_call' || type == 'video_call' || type == 'audio_call' ||
                type == 'group_video_call' || type == 'group_audio_call' || type == 'emergency_call') {
              continue;
            }

            // Ignorar notificaciones ya leídas
            if (data['read'] == true) continue;

            await _showNotificationFromFirestore(doc.id, data, type);
          }
        },
        onError: (error) {
          ReleaseLogger.error(
            '❌ [NotificationsListener] Error: $error',
            tag: 'NotificationService',
          );
        },
      );

      ReleaseLogger.log(
        '✅ [NotificationsListener] Listener activo',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [NotificationsListener] Error iniciando listener: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// Mostrar notificación local desde documento de Firestore
  Future<void> _showNotificationFromFirestore(
    String docId,
    Map<String, dynamic> data,
    String type,
  ) async {
    try {
      final title = data['title'] as String? ?? 'Talia';
      final body = data['body'] as String? ?? '';

      ReleaseLogger.log(
        '📬 [NotificationsListener] Mostrando: type=$type, title=$title',
        tag: 'NotificationService',
      );

      // Generar ID único para la notificación
      final notificationId = docId.hashCode;

      // Configurar detalles según plataforma
      NotificationDetails details;
      if (Platform.isAndroid) {
        details = const NotificationDetails(
          android: AndroidNotificationDetails(
            'high_importance_channel',
            'Notificaciones Importantes',
            channelDescription: 'Canal para notificaciones importantes de Talia',
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: true,
            playSound: true,
          ),
        );
      } else {
        details = const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
      }

      // Preparar payload para navegación al tocar
      final payload = jsonEncode({
        'type': type,
        'notificationId': docId,
        ...data,
      });

      await _localNotifications.show(
        notificationId,
        title,
        body,
        details,
        payload: payload,
      );

      ReleaseLogger.log(
        '✅ [NotificationsListener] Notificación mostrada (id=$notificationId)',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [NotificationsListener] Error mostrando notificación: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// Reiniciar listener de notificaciones (llamar cuando cambia el usuario)
  Future<void> restartNotificationsListener() async {
    await _startNotificationsListener();
  }

  // Obtener token FCM
  Future<void> _getFCMToken() async {
    try {
      ReleaseLogger.log(
        '🔄 Verificando estado de autenticación...',
        tag: 'NotificationService',
      );
      if (_auth.currentUser == null) {
        ReleaseLogger.log(
          '⚠️ No hay usuario autenticado, FCM token se obtendrá después del login',
          tag: 'NotificationService',
        );
        return;
      }

      ReleaseLogger.log(
        '🔄 Obteniendo FCM token...',
        tag: 'NotificationService',
      );
      _fcmToken = await _fcm.getToken();

      if (_fcmToken == null) {
        ReleaseLogger.error(
          '❌ No se pudo obtener el FCM token',
          tag: 'NotificationService',
        );
        ReleaseLogger.error(
          '   Esto puede ocurrir si:',
          tag: 'NotificationService',
        );
        ReleaseLogger.error(
          '   - Los permisos de notificaciones están denegados',
          tag: 'NotificationService',
        );
        ReleaseLogger.error(
          '   - No hay conexión a internet',
          tag: 'NotificationService',
        );
        ReleaseLogger.error(
          '   - El dispositivo no está registrado en APNs (iOS)',
          tag: 'NotificationService',
        );
        return;
      }

      ReleaseLogger.log(
        '🔑 FCM Token obtenido: ${_fcmToken!.substring(0, 20)}...',
        tag: 'NotificationService',
      );
      ReleaseLogger.log(
        '💾 Guardando FCM token en Firestore...',
        tag: 'NotificationService',
      );

      // IMPORTANTE: Limpiar token duplicado de otros usuarios antes de registrar
      await _cleanupDuplicateTokens(_fcmToken!);

      // Guardar token en Firestore (upsert)
      await _upsertUserData({
        'fcmToken': _fcmToken,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      });
      ReleaseLogger.log(
        '✅ FCM token guardado exitosamente',
        tag: 'NotificationService',
      );

      // Escuchar cambios de token
      _fcm.onTokenRefresh.listen((newToken) async {
        ReleaseLogger.log(
          '🔄 FCM token actualizado',
          tag: 'NotificationService',
        );
        _fcmToken = newToken;
        if (_auth.currentUser != null) {
          // Limpiar token duplicado de otros usuarios antes de registrar el nuevo
          await _cleanupDuplicateTokens(newToken);

          _upsertUserData({
            'fcmToken': newToken,
            'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo token: $e',
        tag: 'NotificationService',
      );
      ReleaseLogger.error(
        '   Stack trace: ${StackTrace.current}',
        tag: 'NotificationService',
      );
    }
  }

  // Inicializar CallKit para llamadas en pantalla completa
  void _initializeCallKit() {
    _callKit.initialize(
      onCallKitShown: (callId) {
        // V2: CallKit handling (no orchestrator needed)
        ReleaseLogger.log(
          '✅ CallKit mostrado: $callId',
          tag: 'NotificationService',
        );
      },
      onCallAccepted: (callData) async {
        ReleaseLogger.log(
          '🔥 ============================================',
          tag: 'NotificationService',
        );
        ReleaseLogger.log(
          '✅ CallKit: Llamada aceptada',
          tag: 'NotificationService',
        );
        ReleaseLogger.log(
          '📦 Call data completo: $callData',
          tag: 'NotificationService',
        );
        ReleaseLogger.log(
          '🔥 ============================================',
          tag: 'NotificationService',
        );

        // ✅ V2: Aceptar llamada y navegar directamente a AgoraCallScreen
        final callId = callData['id'] as String?;
        ReleaseLogger.log(
          '🔍 Call ID extraído: $callId',
          tag: 'NotificationService',
        );

        if (callId != null) {
          try {
            // ✅ CRITICAL: Mark call as being processed IMMEDIATELY to prevent IncomingCallScreen
            final cache = CallStateCacheService();
            if (!cache.markAsProcessing(
              callId,
              CallProcessingSource.callKitAccept,
            )) {
              ReleaseLogger.log(
                '⏭️ Call $callId already being processed',
                tag: 'NotificationService',
              );
              return;
            }

            // ✅ CRITICAL: Mark as handled by VoIP to prevent IncomingCallScreen
            VoIPService().markCallAsVoIPHandled(callId);
            ReleaseLogger.log(
              '✅ Call $callId marked as handled by VoIP',
              tag: 'NotificationService',
            );

            // ✅ OPTIMISTIC UI: Navigate IMMEDIATELY - don't wait for Firebase
            // This ensures WhatsApp-style instant screen appearance
            // NOTE: AgoraCallScreen handles acceptCall internally - DO NOT call it here
            // to prevent duplicate join channel attempts (error -17)
            if (onNavigateToCall != null) {
              ReleaseLogger.log(
                '⚡ [OPTIMISTIC] Navegando INMEDIATAMENTE a call screen (Android CallKit)',
                tag: 'NotificationService',
              );
              onNavigateToCall!(callId, isIncoming: true);
              ReleaseLogger.log(
                '✅ [OPTIMISTIC] Navegación ejecutada - AgoraCallScreen manejará acceptCall',
                tag: 'NotificationService',
              );
            } else {
              ReleaseLogger.error(
                '❌ [NotificationService V2] onNavigateToCall callback NOT configured',
                tag: 'NotificationService',
              );
            }

            // ✅ FIX: DO NOT call acceptCall here - AgoraCallScreen handles it
            // Calling acceptCall here AND in AgoraCallScreen causes:
            // 1. Double join channel attempt
            // 2. Error -17 (ERR_JOIN_CHANNEL_REJECTED)
            // 3. Black screen for receiver
          } catch (e) {
            ReleaseLogger.error(
              '❌ Error en flujo CallKit (V2): $e',
              tag: 'NotificationService',
            );
          }
        } else {
          ReleaseLogger.error(
            '❌ CallKit: callId es null en callData',
            tag: 'NotificationService',
          );
        }
      },
      onCallDeclined: (callId) async {
        ReleaseLogger.log(
          '❌ CallKit: Llamada rechazada - $callId',
          tag: 'NotificationService',
        );

        // V2: Decline call using CallController
        try {
          final controller = calls_v2.CallController();
          await controller.declineCall(callId);
          ReleaseLogger.log(
            '✅ CallKit: Rechazo propagado a Firestore para callId: $callId',
            tag: 'NotificationService',
          );
        } catch (error) {
          ReleaseLogger.error(
            '❌ CallKit: Error rechazando llamada en Firestore: $error',
            tag: 'NotificationService',
          );
        }
      },
      onCallEnded: (callId) {
        ReleaseLogger.log(
          '🔚 CallKit: Llamada finalizada - $callId',
          tag: 'NotificationService',
        );
        // Limpiar recursos si es necesario
      },
    );
    ReleaseLogger.log(
      '✅ CallKit inicializado correctamente',
      tag: 'NotificationService',
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // LISTENERS FCM SIMPLIFICADOS (DATA-ONLY STRATEGY)
  // ═══════════════════════════════════════════════════════════════
  Future<void> _setupListeners() async {
    // Mensajes cuando la app está en primer plano
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final messageType = message.data['type'];
      final messageId = message.data['messageId'];

      final platform = Platform.isIOS ? 'iOS' : 'Android';
      ReleaseLogger.log(
        '📨 [Foreground $platform] type=$messageType, messageId=$messageId',
        tag: 'NotificationService',
      );

      // Filtrar mensajes muy viejos (>60s)
      final sentTime = message.sentTime;
      if (sentTime != null && DateTime.now().difference(sentTime).inSeconds > 60) {
        ReleaseLogger.log('⚠️ [Foreground] Mensaje antiguo - SKIP', tag: 'NotificationService');
        return;
      }

      // 1. LOCATION REQUEST: Silencioso
      if (messageType == 'location_request') {
        try {
          await LocationService().updateLocationNow();
          ReleaseLogger.log('✅ [Foreground] Ubicación actualizada', tag: 'NotificationService');
        } catch (e) {
          ReleaseLogger.error('❌ [Foreground] Error ubicación: $e', tag: 'NotificationService');
        }
        return;
      }

      // 2. LLAMADAS: Mostrar CallKit
      if (messageType == 'incoming_call' ||
          messageType == 'video_call' ||
          messageType == 'audio_call' ||
          messageType == 'group_video_call' ||
          messageType == 'group_audio_call' ||
          messageType == 'emergency_call') {

        final callId = message.data['callId'] ?? message.messageId ?? '';

        // Deduplicación
        if (_processedCallIds.contains(callId) || _globalProcessedCallIds.contains(callId)) {
          return;
        }
        _processedCallIds.add(callId);
        _globalProcessedCallIds.add(callId);

        // Verificar timestamp
        if (sentTime != null && DateTime.now().difference(sentTime).inSeconds > 30) {
          return;
        }

        VoIPService().markCallAsVoIPHandled(callId);

        try {
          // ✅ FIX: Mostrar CallKit en AMBAS plataformas cuando la app está en foreground
          // VoIP push solo maneja background en iOS, foreground necesita CallKit manual
          final isVideo = message.data['isVideo'] == 'true' || message.data['isVideo'] == true;
          final isAudioType = messageType == 'audio_call' || messageType == 'group_audio_call';

          await _callKit.showIncomingCall(
            callId: callId,
            callerName: message.data['callerName'] ?? 'Usuario',
            callerId: message.data['callerId'] ?? message.data['senderId'] ?? '',
            callerPhotoUrl: message.data['callerPhotoURL'] ?? message.data['senderPhotoUrl'],
            callType: (isAudioType || !isVideo) ? 'audio' : 'video',
            isEmergency: message.data['isEmergency'] == 'true',
            extraData: message.data,
          );
          ReleaseLogger.log('✅ [Foreground ${Platform.isIOS ? "iOS" : "Android"}] CallKit mostrado para llamada $callId', tag: 'NotificationService');
        } catch (e) {
          ReleaseLogger.error('❌ [Foreground] Error CallKit: $e', tag: 'NotificationService');
        }
        return;
      }

      // 3. MENSAJES DE CHAT: StreamDetector maneja foreground, FCM solo background
      // ═══════════════════════════════════════════════════════════════
      // ⚠️ NO mostrar notificación aquí - StreamDetector es más rápido (~100ms vs 2-5s)
      // ChatStreamManager._fetchAndShowLatestMessage ya muestra la notificación
      // FCM onMessage solo se usa para logging/debugging en foreground
      // ═══════════════════════════════════════════════════════════════
      if (messageType == 'chat_message' || messageType == 'group_message') {
        ReleaseLogger.log(
          '📱 [Foreground $platform] Chat message recibido via FCM - StreamDetector maneja notificación',
          tag: 'NotificationService',
        );
        // NO llamar a showLocalChatNotification - StreamDetector ya lo hace
        return;
      }

      // ═══════════════════════════════════════════════════════════════
      // 4. ✅ FIX #10: STORY APPROVAL - Actualización INMEDIATA del cache
      // ═══════════════════════════════════════════════════════════════
      // Cuando el parent aprueba/rechaza una historia, el child recibe notificación
      // Actualizar el cache local INMEDIATAMENTE para que la UI muestre el nuevo estado
      if (messageType == 'story_approved' || messageType == 'story_rejected') {
        final storyId = message.data['storyId'] as String?;
        ReleaseLogger.log(
          '📸 [Foreground $platform] Story $messageType - storyId: $storyId',
          tag: 'NotificationService',
        );

        try {
          if (storyId != null && storyId.isNotEmpty) {
            // ✅ FIX #10: Actualizar status en cache local INMEDIATAMENTE (no esperar Firestore)
            final newStatus = messageType == 'story_approved'
                ? StoryStatus.approved
                : StoryStatus.rejected;

            StoryOrchestrator().cacheManagerForTesting.updateStoryStatus(storyId, newStatus);
            ReleaseLogger.log(
              '✅ [Foreground] Cache de story $storyId actualizado a $newStatus INMEDIATAMENTE',
              tag: 'NotificationService',
            );
          }

          // También forzar refresh completo como backup (asíncrono, sin esperar)
          StoryService().forceRefreshCache().catchError((e) {
            ReleaseLogger.error(
              '❌ [Foreground] Error en refresh backup de stories: $e',
              tag: 'NotificationService',
            );
          });
        } catch (e) {
          ReleaseLogger.error(
            '❌ [Foreground] Error actualizando cache de stories: $e',
            tag: 'NotificationService',
          );
        }
        // Continuar para mostrar notificación local si corresponde
      }
    });

    // Mensajes cuando se toca la notificación (app en segundo plano)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      ReleaseLogger.log(
        '🔔 Notificación tocada: ${message.data['type']}',
        tag: 'NotificationService',
      );
      handleNotificationTap(message.data);
    });

    // Verificar si la app se abrió desde una notificación (app cerrada)
    _fcm.getInitialMessage().then((RemoteMessage? message) async {
      if (message != null) {
        ReleaseLogger.log(
          '🚀 App abierta desde notificación: ${message.data['type']}',
          tag: 'NotificationService',
        );
        // Delay para dar tiempo a que los shells se inicialicen
        Future.delayed(Duration(milliseconds: 500), () {
          handleNotificationTap(message.data);
        });
      }
    });

    // ✅ FIX: Handler para notificaciones de Android creadas por MyFirebaseMessagingService
    // El servicio nativo de Android crea notificaciones con Intent extras, necesitamos leerlos
    if (Platform.isAndroid) {
      try {
        final androidNotificationData = await _notificationChannel.invokeMethod<Map>('getInitialNotification');
        if (androidNotificationData != null) {
          final data = Map<String, dynamic>.from(androidNotificationData);
          ReleaseLogger.log(
            '🤖 [Android] App abierta desde notificación nativa - datos: $data',
            tag: 'NotificationService',
          );

          // Delay para dar tiempo a que los shells se inicialicen
          Future.delayed(Duration(milliseconds: 500), () {
            handleNotificationTap(data);
          });
        }
      } catch (e) {
        ReleaseLogger.error(
          '⚠️ [Android] Error obteniendo notificación inicial: $e',
          tag: 'NotificationService',
        );
      }
    }

    // ✅ CRITICAL FIX: Handler para taps de Communication Notifications desde iOS
    // Las Communication Notifications pasan los datos via method channel en lugar de flutter_local_notifications
    _notificationChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTapped') {
        ReleaseLogger.log(
          '👆 [iOS] Communication Notification tocada - recibido desde Swift',
          tag: 'NotificationService',
        );

        final data = Map<String, dynamic>.from(call.arguments as Map);
        ReleaseLogger.log(
          '📦 Datos recibidos: $data',
          tag: 'NotificationService',
        );

        // Navegar al chat usando el mismo handler
        handleNotificationTap(data);
      }
    });
  }

  // Mostrar notificación local
  Future<void> _showLocalNotification(RemoteMessage message) async {
    try {
      // Verificar usuario actual
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.log(
          '⚠️ No hay usuario autenticado',
          tag: 'NotificationService',
        );
        return;
      }

      // Obtener tipo de notificación
      final notificationType = message.data['type'] ?? 'unknown';
      final senderId = message.data['senderId'];
      final chatId =
          message.data['chatId']; // Para verificar si es del chat actual

      ReleaseLogger.log(
        '📨 Procesando notificación local:',
        tag: 'NotificationService',
      );
      ReleaseLogger.log(
        '   Tipo: $notificationType',
        tag: 'NotificationService',
      );
      ReleaseLogger.log(
        '   Usuario: ${currentUser.uid.substring(0, 8)}...',
        tag: 'NotificationService',
      );
      ReleaseLogger.log('   Chat ID: $chatId', tag: 'NotificationService');
      ReleaseLogger.log(
        '   Chat actual: $_currentChatId',
        tag: 'NotificationService',
      );

      // Verificar si se debe mostrar la notificación
      final decision = await _filter.shouldSendNotification(
        userId: currentUser.uid,
        notificationType: notificationType,
        senderId: senderId,
        chatId: chatId,
        currentChatId: _currentChatId,
      );

      if (!decision.shouldSend) {
        ReleaseLogger.log(
          '🚫 Notificación bloqueada: ${decision.reason}',
          tag: 'NotificationService',
        );
        return;
      }

      // ✅ FIX: Verificar si el chat/grupo está silenciado (Hive local)
      // Grupos usan 'groupId', chats 1-1 usan 'chatId'
      final conversationId = chatId ?? message.data['groupId'];
      if (conversationId != null) {
        final preferencesCache = ChatPreferencesCache();
        await preferencesCache.initialize(); // Returns early if already initialized
        if (preferencesCache.isMuted(conversationId)) {
          ReleaseLogger.log(
            '🔇 Notificación bloqueada: Chat/Grupo silenciado (ID: $conversationId)',
            tag: 'NotificationService',
          );
          return;
        }
      }

      ReleaseLogger.log(
        '✅ Notificación permitida: ${decision.reason}',
        tag: 'NotificationService',
      );

      // Obtener configuración de sonido
      final soundConfig = await _filter.getSoundConfig(currentUser.uid);

      // Preparar la foto del remitente para Android (SIEMPRE usar foto del sender)
      String? largeIconPath;

      // Descargar foto del remitente para Android (LargeIcon) y iOS (Attachment)
      if (Platform.isAndroid || Platform.isIOS) {
        final senderPhotoUrl = message.data['senderPhotoUrl'];

        if (senderPhotoUrl != null &&
            senderPhotoUrl.isNotEmpty &&
            senderPhotoUrl != 'null') {
          try {
            ReleaseLogger.log(
              '📥 [Android] Descargando foto del remitente: $senderPhotoUrl',
              tag: 'NotificationService',
            );
            // ✅ FIX #8: Timeout agresivo de 1s (igual que iOS AppDelegate.swift:323)
            // Evita bloquear notificación por 10s si descarga falla
            final response = await http
                .get(Uri.parse(senderPhotoUrl))
                .timeout(Duration(seconds: 5));

            if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
              final originalImage = img.decodeImage(response.bodyBytes);

              if (originalImage != null) {
                // Redimensionar a 192x192 (tamaño óptimo para largeIcon)
                final resizedImage = img.copyResize(
                  originalImage,
                  width: 192,
                  height: 192,
                  interpolation: img.Interpolation.linear,
                );

                final pngBytes = img.encodePng(resizedImage);

                final directory = await getTemporaryDirectory();
                final timestamp = DateTime.now().millisecondsSinceEpoch;
                final filePath =
                    '${directory.path}/sender_photo_$timestamp.png';
                final file = File(filePath);
                await file.writeAsBytes(pngBytes);

                if (await file.exists()) {
                  largeIconPath = filePath;
                  ReleaseLogger.log(
                    '✅ [Android] Foto del remitente procesada: $largeIconPath',
                    tag: 'NotificationService',
                  );
                }
              } else {
                ReleaseLogger.error(
                  '⚠️ [Android] No se pudo decodificar la imagen',
                  tag: 'NotificationService',
                );
              }
            } else {
              ReleaseLogger.error(
                '⚠️ [Android] Respuesta inválida: ${response.statusCode}',
                tag: 'NotificationService',
              );
            }
          } catch (e) {
            ReleaseLogger.error(
              '❌ [Android] Error descargando foto: $e',
              tag: 'NotificationService',
            );
          }
        } else {
          ReleaseLogger.log(
            '⚠️ [Android] No hay senderPhotoUrl disponible',
            tag: 'NotificationService',
          );
        }
      }

      // Configuración para Android con foto del sender (largeIcon)
      AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'high_importance_channel',
        'Notificaciones Importantes',
        channelDescription: 'Canal para notificaciones importantes',
        importance: Importance.high,
        priority: Priority.high,
        enableVibration: soundConfig.vibrationEnabled,
        playSound: soundConfig.soundEnabled,
        icon: '@mipmap/ic_launcher',
        // largeIcon de la foto del sender (aparece circular a la izquierda en Android)
        largeIcon: largeIconPath != null
            ? FilePathAndroidBitmap(largeIconPath)
            : null,
      );

      // Configuración para iOS
      // ✅ FIX: Agregar attachment para mostrar foto en foreground
      List<DarwinNotificationAttachment>? iosAttachments;
      if (largeIconPath != null && Platform.isIOS) {
        iosAttachments = [DarwinNotificationAttachment(largeIconPath)];
      }

      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundConfig.soundEnabled,
        attachments: iosAttachments,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Convertir data a JSON para poder parsearlo después
      String payload = '';
      try {
        payload = message.data.isNotEmpty ? jsonEncode(message.data) : '';
      } catch (e) {
        ReleaseLogger.error(
          '⚠️ Error codificando payload: $e',
          tag: 'NotificationService',
        );
      }

      await _localNotifications.show(
        message.hashCode,
        message.notification?.title ?? 'Talia',
        message.notification?.body ?? '',
        details,
        payload: payload,
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error mostrando notificación local: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Manejar tap en notificación local
  void _onNotificationTapped(NotificationResponse response) {
    ReleaseLogger.log(
      '👆 Notificación local tocada: ${response.payload}',
      tag: 'NotificationService',
    );

    if (response.payload != null && response.payload!.isNotEmpty) {
      try {
        // Parsear el JSON del payload
        final data = jsonDecode(response.payload!) as Map<String, dynamic>;
        ReleaseLogger.log(
          '📦 Datos parseados: $data',
          tag: 'NotificationService',
        );

        // Manejar según el tipo
        handleNotificationTap(data);
      } catch (e) {
        ReleaseLogger.error(
          '❌ Error parseando payload: $e',
          tag: 'NotificationService',
        );
      }
    }
  }

  /// ✅ FIX KILLED STATE: Process pending navigation from main.dart
  /// When app is killed and user taps notification, main.dart saves the data
  /// because getInitialMessage() only works once. We process it here.
  Future<void> _processPendingNavigation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingData = prefs.getString('pending_notification_data');

      if (pendingData != null) {
        ReleaseLogger.log(
          '📱 [PendingNav] Encontrada navegación pendiente de killed state',
          tag: 'NotificationService',
        );

        // Decode JSON data
        final data = Map<String, dynamic>.from(jsonDecode(pendingData));

        // Clear pending data immediately to avoid re-processing
        await prefs.remove('pending_notification_data');

        ReleaseLogger.log(
          '📱 [PendingNav] Procesando navegación: type=${data['type']}, chatId=${data['chatId']}',
          tag: 'NotificationService',
        );

        // Small delay to ensure UI is ready for navigation
        await Future.delayed(const Duration(milliseconds: 500));

        // Navigate using existing handler
        handleNotificationTap(data);

        ReleaseLogger.log(
          '✅ [PendingNav] Navegación desde killed state completada',
          tag: 'NotificationService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [PendingNav] Error procesando navegación pendiente: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// Manejar tap en notificación (público para uso desde in-app banner)
  void handleNotificationTap(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    ReleaseLogger.log(
      '📍 Navegando según tipo: $type',
      tag: 'NotificationService',
    );

    switch (type) {
      // ═══════════════════════════════════════════════════════════════
      // LLAMADAS
      // ═══════════════════════════════════════════════════════════════
      case 'video_call':
      case 'audio_call':
      case 'incoming_call':
      case 'group_video_call':
      case 'group_audio_call':
        ReleaseLogger.log(
          '📞 Notificación de llamada tocada, mostrando diálogo',
          tag: 'NotificationService',
        );
        data['fromNotificationTap'] = true;
        _incomingCallController.add(data);
        break;

      // ═══════════════════════════════════════════════════════════════
      // MENSAJES DE CHAT
      // ═══════════════════════════════════════════════════════════════
      case 'chat_message':
      case 'group_message':
        ReleaseLogger.log(
          '💬 Notificación de chat tocada, navegando',
          tag: 'NotificationService',
        );
        _chatNotificationTapController.add(data);
        break;

      // ═══════════════════════════════════════════════════════════════
      // HISTORIAS
      // ═══════════════════════════════════════════════════════════════
      case 'story_approval_request':
        ReleaseLogger.log(
          '📸 Notificación de historia pendiente tocada, navegando a aprobación',
          tag: 'NotificationService',
        );
        _storyApprovalNotificationTapController.add(data);
        break;

      case 'story_approved':
      case 'story_rejected':
      case 'story_reply':
      case 'new_story':
        ReleaseLogger.log(
          '📸 Notificación de historia ($type) tocada, navegando a story viewer',
          tag: 'NotificationService',
        );
        // ✅ FIX #10: Actualizar cache INMEDIATAMENTE al tap de notificación
        if (type == 'story_approved' || type == 'story_rejected') {
          final storyId = data['storyId'] as String?;
          if (storyId != null && storyId.isNotEmpty) {
            try {
              final newStatus = type == 'story_approved'
                  ? StoryStatus.approved
                  : StoryStatus.rejected;
              StoryOrchestrator().cacheManagerForTesting.updateStoryStatus(storyId, newStatus);
              ReleaseLogger.log(
                '✅ [Tap] Cache de story $storyId actualizado a $newStatus',
                tag: 'NotificationService',
              );
            } catch (e) {
              ReleaseLogger.error(
                '❌ [Tap] Error actualizando cache de stories: $e',
                tag: 'NotificationService',
              );
            }
          }
          // También forzar refresh como backup
          StoryService().forceRefreshCache().catchError((e) {
            ReleaseLogger.error(
              '❌ Error refrescando cache de stories al tap: $e',
              tag: 'NotificationService',
            );
          });
        }
        _storyNotificationTapController.add(data);
        break;

      // ═══════════════════════════════════════════════════════════════
      // CONTACTOS
      // ═══════════════════════════════════════════════════════════════
      case 'contact_request':
        ReleaseLogger.log(
          '👥 Notificación de solicitud de contacto tocada, navegando a pendientes',
          tag: 'NotificationService',
        );
        _contactRequestNotificationTapController.add(data);
        break;

      case 'contact_approved':
        ReleaseLogger.log(
          '✅ Notificación de contacto aprobado tocada, navegando a contactos',
          tag: 'NotificationService',
        );
        _contactApprovedNotificationTapController.add(data);
        break;

      // ═══════════════════════════════════════════════════════════════
      // GRUPOS
      // ═══════════════════════════════════════════════════════════════
      case 'group_approval_request':
      case 'group_permission_reminder':
        ReleaseLogger.log(
          '👥 Notificación de aprobación de grupo tocada, navegando a aprobación',
          tag: 'NotificationService',
        );
        _groupApprovalNotificationTapController.add(data);
        break;

      case 'group_membership_approved':
        ReleaseLogger.log(
          '🎉 Notificación de membresía aprobada tocada, navegando al grupo',
          tag: 'NotificationService',
        );
        _groupMembershipApprovedNotificationTapController.add(data);
        break;

      // ═══════════════════════════════════════════════════════════════
      // EMERGENCIAS
      // ═══════════════════════════════════════════════════════════════
      case 'emergency':
        ReleaseLogger.log(
          '🆘 Notificación de emergencia tocada, navegando a detalles',
          tag: 'NotificationService',
        );
        _emergencyNotificationTapController.add(data);
        break;

      // ═══════════════════════════════════════════════════════════════
      // ALERTAS Y REPORTES
      // ═══════════════════════════════════════════════════════════════
      case 'activity_alert':
      case 'bullying_alert':
        ReleaseLogger.log(
          '⚠️ Notificación de alerta ($type) tocada, navegando a alertas',
          tag: 'NotificationService',
        );
        _alertNotificationTapController.add(data);
        break;

      case 'report_ready':
        ReleaseLogger.log(
          '📊 Notificación de reporte listo tocada, navegando a reportes',
          tag: 'NotificationService',
        );
        _reportNotificationTapController.add(data);
        break;

      default:
        ReleaseLogger.log(
          '⚠️ Tipo de notificación no manejado: $type',
          tag: 'NotificationService',
        );
    }
  }

  // ==================== ENVIAR NOTIFICACIONES ====================

  /// Helper para crear notificación en Firestore después de verificar filtros
  ///
  /// Retorna true si la notificación fue creada, false si fue bloqueada
  Future<bool> _createNotificationIfAllowed({
    required String userId,
    required String notificationType,
    required String title,
    required String body,
    required Map<String, dynamic> data,
    String? senderId,
    String? imageUrl,
    String? chatId, // Para verificar si es del chat actual
  }) async {
    try {
      // Verificar si se debe enviar
      final decision = await _filter.shouldSendNotification(
        userId: userId,
        notificationType: notificationType,
        senderId: senderId,
        chatId: chatId,
        currentChatId: _currentChatId,
      );

      if (!decision.shouldSend) {
        ReleaseLogger.log(
          '🚫 Notificación bloqueada para usuario ${userId.substring(0, 8)}...: ${decision.reason}',
          tag: 'NotificationService',
        );
        return false;
      }

      // ✅ FIX #13: Código muerto eliminado (40 líneas)
      // Las notificaciones son creadas por Cloud Functions (chats.js:100-113)
      // El cliente SOLO envía mensajes, Cloud Functions crean notificaciones automáticamente

      ReleaseLogger.log(
        '✅ Notificación delegada a Cloud Functions para usuario ${userId.substring(0, 8)}... (tipo: $notificationType)',
        tag: 'NotificationService',
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error creando notificación: $e',
        tag: 'NotificationService',
      );
      return false;
    }
  }

  // Enviar notificación de solicitud de permiso para grupo
  Future<void> sendGroupInvitationPermissionRequest({
    required String parentId,
    required String childName,
    required String groupName,
    required String contactName,
    required String inviterName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'group_permission_request',
        'title': '🔒 Solicitud de Grupo para $childName',
        'body':
            '$inviterName quiere agregar a $childName al grupo "$groupName". Necesita aprobar el contacto con $contactName.',
        'data': {
          'type': 'group_permission_request',
          'childName': childName,
          'groupName': groupName,
          'contactName': contactName,
          'inviterName': inviterName,
        },
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': 'high',
      });

      ReleaseLogger.log(
        '✅ Notificación de solicitud de grupo enviada al padre: $parentId',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de grupo: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de membresía aprobada
  Future<void> sendGroupMembershipApproved({
    required String userId,
    required String groupName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': userId,
        'type': 'group_membership_approved',
        'title': '🎉 ¡Te agregaron al grupo!',
        'body': 'Ya puedes chatear en el grupo "$groupName"',
        'data': {'type': 'group_membership_approved', 'groupName': groupName},
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': 'normal',
      });

      ReleaseLogger.log(
        '✅ Notificación de membresía aprobada enviada a: $userId',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de membresía: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de nuevo mensaje en grupo
  Future<void> sendGroupMessageNotification({
    required String groupId,
    required String groupName,
    required String senderName,
    required String messageText,
    required List<String> memberIds,
    required String senderId,
  }) async {
    try {
      // Enviar a todos los miembros excepto al remitente
      final recipientIds = memberIds.where((id) => id != senderId).toList();

      for (final recipientId in recipientIds) {
        await _firestore.collection('notifications').add({
          'userId': recipientId,
          'type': 'group_message',
          'title': '💬 $groupName',
          'body': '$senderName: $messageText',
          'data': {
            'type': 'group_message',
            'groupId': groupId,
            'groupName': groupName,
            'senderId': senderId,
            'senderName': senderName,
          },
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
          'priority': 'normal',
        });
      }

      ReleaseLogger.log(
        '✅ Notificaciones de grupo enviadas a ${recipientIds.length} miembros',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificaciones de grupo: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar recordatorio a padres sobre solicitudes pendientes
  Future<void> sendGroupPermissionReminder({
    required String parentId,
    required String childName,
    required String groupName,
    required int pendingDays,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'group_permission_reminder',
        'title': '⏰ Recordatorio: Solicitud de Grupo Pendiente',
        'body':
            'Hace $pendingDays días que $childName está esperando unirse al grupo "$groupName". ¿Puedes revisar la solicitud?',
        'data': {
          'type': 'group_permission_reminder',
          'childName': childName,
          'groupName': groupName,
          'pendingDays': pendingDays,
        },
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': 'normal',
      });

      ReleaseLogger.log(
        '✅ Recordatorio de grupo enviado al padre: $parentId',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando recordatorio de grupo: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de nuevo mensaje de chat
  Future<void> sendChatMessageNotification({
    required String recipientId,
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required String messageText,
    required String chatId,
    bool isGroup = false,
    String? groupName,
  }) async {
    try {
      ReleaseLogger.log(
        '📤 Enviando notificación de mensaje:',
        tag: 'NotificationService',
      );
      ReleaseLogger.log(
        '   - Destinatario: $recipientId',
        tag: 'NotificationService',
      );
      ReleaseLogger.log(
        '   - Remitente: $senderId ($senderName)',
        tag: 'NotificationService',
      );
      ReleaseLogger.log('   - Chat ID: $chatId', tag: 'NotificationService');
      ReleaseLogger.log(
        '   - Mensaje: ${messageText.substring(0, messageText.length > 50 ? 50 : messageText.length)}...',
        tag: 'NotificationService',
      );

      // Preparar datos
      final messagePreview = messageText.length > 100
          ? '${messageText.substring(0, 100)}...'
          : messageText;

      final title = isGroup ? '👥 $groupName' : '💬 $senderName';
      final body = isGroup ? '$senderName: $messagePreview' : messagePreview;

      final data = {
        'type': NotificationTypes.chatMessage,
        'senderId': senderId,
        'senderName': senderName,
        'senderPhotoUrl': senderPhotoUrl ?? '',
        'chatId': chatId,
        'messagePreview': messageText,
        'isGroup': isGroup,
        'groupName': groupName ?? '',
      };

      // Crear notificación si está permitida
      final created = await _createNotificationIfAllowed(
        userId: recipientId,
        notificationType: NotificationTypes.chatMessage,
        title: title,
        body: body,
        data: data,
        senderId: senderId,
        imageUrl: senderPhotoUrl,
        chatId: chatId,
      );

      if (created) {
        ReleaseLogger.log(
          '   → La Cloud Function debería enviarla automáticamente',
          tag: 'NotificationService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de mensaje: $e',
        tag: 'NotificationService',
      );
      ReleaseLogger.error(
        '   Stack trace: ${StackTrace.current}',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de nueva solicitud de contacto
  Future<void> sendContactRequestNotification({
    required String parentId,
    required String childName,
    required String contactName,
    String? childId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: parentId,
        notificationType: NotificationTypes.contactRequest,
        title: '🔔 Nueva solicitud de contacto',
        body: '$childName quiere agregar a $contactName',
        data: {
          'type': NotificationTypes.contactRequest,
          'childName': childName,
          'contactName': contactName,
          'childId': childId,
        },
        senderId: childId,
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de solicitud: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de contacto aprobado
  Future<void> sendContactApprovedNotification({
    required String childId,
    required String contactName,
    String? parentId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: childId,
        notificationType: NotificationTypes.contactApproved,
        title: '✅ Contacto aprobado',
        body: 'Tus padres aprobaron a $contactName. Ya puedes chatear!',
        data: {
          'type': NotificationTypes.contactApproved,
          'contactName': contactName,
        },
        senderId: parentId,
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de aprobación: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de aprobación automática al padre
  Future<void> sendAutoApprovalNotification({
    required String parentId,
    required String childId,
    required String contactName,
  }) async {
    try {
      // Obtener el nombre del hijo
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childName = childDoc.data()?['name'] ?? 'Tu hijo';

      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'auto_approval',
        'title': '🤖 Aprobación automática',
        'body': 'Se aprobó automáticamente a "$contactName" para $childName',
        'data': {
          'type': 'auto_approval',
          'childId': childId,
          'childName': childName,
          'contactName': contactName,
        },
        'read': false,
        'timestamp': FieldValue.serverTimestamp(),
        'priority': 'normal',
      });

      ReleaseLogger.log(
        '✅ Notificación de aprobación automática enviada al padre',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de aprobación automática: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar alerta de bullying
  Future<void> sendBullyingAlert({
    required String parentId,
    required String childName,
    required double severity,
    String? childId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: parentId,
        notificationType: NotificationTypes.bullyingAlert,
        title: '⚠️ ALERTA: Posible bullying detectado',
        body: 'Se detectó contenido preocupante en mensajes de $childName',
        data: {
          'type': NotificationTypes.bullyingAlert,
          'childName': childName,
          'severity': severity,
          'childId': childId,
        },
        senderId: childId,
      );
      ReleaseLogger.log(
        '⚠️ Alerta de bullying enviada/verificada',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando alerta de bullying: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de reporte disponible
  Future<void> sendReportReadyNotification({
    required String parentId,
    required String childName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'report_ready',
        'title': '📊 Reporte semanal disponible',
        'body': 'El reporte de $childName está listo para revisar',
        'data': {'type': 'report_ready', 'childName': childName},
        'read': false,
        'timestamp': FieldValue.serverTimestamp(),
        'priority': 'normal',
      });

      ReleaseLogger.log(
        '📊 Notificación de reporte enviada',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de historia pendiente de aprobación
  Future<void> sendStoryApprovalRequestNotification({
    required String parentId,
    required String childName,
    required String storyId,
    String? childId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: parentId,
        notificationType: NotificationTypes.storyApprovalRequest,
        title: '📸 Nueva historia pendiente',
        body:
            '$childName quiere compartir una historia. ¡Revísala y apruébala!',
        data: {
          'type': NotificationTypes.storyApprovalRequest,
          'childName': childName,
          'storyId': storyId,
          'childId': childId,
        },
        senderId: childId,
      );
      ReleaseLogger.log(
        '📸 Notificación de historia pendiente enviada/verificada',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de historia: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de historia aprobada
  Future<void> sendStoryApprovedNotification({
    required String childId,
    String? parentId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: childId,
        notificationType: NotificationTypes.storyApproved,
        title: '✅ Historia aprobada',
        body:
            '¡Genial! Tus padres aprobaron tu historia. Ya está visible para tus contactos.',
        data: {'type': NotificationTypes.storyApproved},
        senderId: parentId,
      );
      ReleaseLogger.log(
        '✅ Notificación de historia aprobada enviada/verificada',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de aprobación: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de historia rechazada
  Future<void> sendStoryRejectedNotification({
    required String childId,
    String? reason,
    String? parentId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: childId,
        notificationType: NotificationTypes.storyRejected,
        title: '❌ Historia rechazada',
        body: reason != null && reason.isNotEmpty
            ? 'Tus padres rechazaron tu historia: $reason'
            : 'Tus padres rechazaron tu historia. Intenta con otro contenido.',
        data: {'type': NotificationTypes.storyRejected, 'reason': reason},
        senderId: parentId,
      );
      ReleaseLogger.log(
        '❌ Notificación de historia rechazada enviada/verificada',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de rechazo: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Enviar notificación de respuesta a historia
  Future<void> sendStoryReplyNotification({
    required String userId,
    required String replierName,
    required String replyText,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: userId,
        notificationType: NotificationTypes.storyReply,
        title: '💬 Nueva respuesta a tu historia',
        body: '$replierName respondió: $replyText',
        data: {
          'type': NotificationTypes.storyReply,
          'replierName': replierName,
          'replyText': replyText,
        },
      );
      ReleaseLogger.log(
        '💬 Notificación de respuesta a historia enviada/verificada',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error enviando notificación de respuesta: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Obtener notificaciones no leídas
  Stream<QuerySnapshot> getUnreadNotifications(String userId) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('read', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  // Marcar notificación como leída
  Future<void> markAsRead(String notificationId) async {
    try {
      await _firestore.collection('notifications').doc(notificationId).update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error marcando como leída: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Marcar todas como leídas
  Future<void> markAllAsRead(String userId) async {
    try {
      final batch = _firestore.batch();
      final notifications = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .where('read', isEqualTo: false)
          .get();

      for (var doc in notifications.docs) {
        batch.update(doc.reference, {
          'read': true,
          'readAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
      ReleaseLogger.log(
        '✅ Todas las notificaciones marcadas como leídas',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error marcando todas como leídas: $e',
        tag: 'NotificationService',
      );
    }
  }

  // Obtener contador de notificaciones no leídas
  Stream<int> getUnreadCount(String userId) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('read', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  // Limpiar token al cerrar sesión
  Future<void> clearToken() async {
    try {
      if (_auth.currentUser != null) {
        await _firestore.collection('users').doc(_auth.currentUser!.uid).update(
          {'fcmToken': FieldValue.delete()},
        );
      }
      _fcmToken = null;
      ReleaseLogger.log('🗑️ Token FCM limpiado', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error limpiando token: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// ═══════════════════════════════════════════════════════════════
  /// 🔔 ÚNICO PUNTO DE ENTRADA PARA NOTIFICACIONES DE CHAT
  /// ═══════════════════════════════════════════════════════════════
  /// Este método es llamado desde:
  /// - firebaseMessagingBackgroundHandler (background/terminated)
  /// - onMessage listener (foreground)
  ///
  /// Incluye deduplicación en memoria para evitar notificaciones duplicadas.
  /// ═══════════════════════════════════════════════════════════════
  Future<void> showLocalChatNotification({
    required String senderId,
    required String senderName,
    required String messageText,
    required String chatId,
    String? messageId,
    bool isGroup = false,
    String? groupName,
    String? senderPhotoUrl,
  }) async {
    // ═══════════════════════════════════════════════════════════════
    // DEDUPLICACIÓN: Evitar mostrar la misma notificación dos veces
    // ═══════════════════════════════════════════════════════════════
    if (messageId != null && messageId.isNotEmpty) {
      if (_processedMessageIds.contains(messageId)) {
        ReleaseLogger.log(
          '⏭️ [Notification] messageId=$messageId ya mostrado - SKIP',
          tag: 'NotificationService',
        );
        return;
      }
      _processedMessageIds.add(messageId);

      // Limpiar IDs viejos para evitar memory leak (mantener últimos 200)
      if (_processedMessageIds.length > 200) {
        final toRemove = _processedMessageIds.take(100).toList();
        _processedMessageIds.removeAll(toRemove);
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // FILTRO: No mostrar si el usuario está viendo este chat
    // ═══════════════════════════════════════════════════════════════
    if (_currentChatId != null && _currentChatId == chatId) {
      ReleaseLogger.log(
        '🚫 [Notification] Usuario viendo chat $chatId - SKIP',
        tag: 'NotificationService',
      );
      return;
    }

    try {
      ReleaseLogger.log(
        '🔔 [Notification] Mostrando notificación: $senderName',
        tag: 'NotificationService',
      );
      ReleaseLogger.log(
        '   - Remitente: $senderId ($senderName)',
        tag: 'NotificationService',
      );
      ReleaseLogger.log('   - Chat ID: $chatId', tag: 'NotificationService');

      // ✅ FIX #8: Obtener preferencias de sonido/vibración del usuario
      final currentUser = FirebaseAuth.instance.currentUser;
      NotificationSoundConfig? soundConfig;
      if (currentUser != null) {
        try {
          soundConfig = await _filter.getSoundConfig(currentUser.uid);
          ReleaseLogger.log(
            '🔊 [Notification] Preferencias: sound=${soundConfig.soundEnabled}, vibration=${soundConfig.vibrationEnabled}',
            tag: 'NotificationService',
          );
        } catch (e) {
          // Usar valores por defecto si falla
          ReleaseLogger.error('⚠️ [Notification] Error obteniendo preferencias: $e', tag: 'NotificationService');
        }
      }
      // Valores por defecto si no hay preferencias
      final playSound = soundConfig?.soundEnabled ?? true;
      final enableVibration = soundConfig?.vibrationEnabled ?? true;

      final title = isGroup ? '👥 $groupName' : '💬 $senderName';
      final messagePreview = messageText.length > 100
          ? '${messageText.substring(0, 100)}...'
          : messageText;
      final body = isGroup ? '$senderName: $messagePreview' : messagePreview;

      final data = {
        'type': isGroup
            ? NotificationTypes.groupMessage
            : NotificationTypes.chatMessage,
        'senderId': senderId,
        'senderName': senderName,
        'chatId': chatId,
        'messagePreview': messageText,
        'isGroup': isGroup.toString(),
        'groupName': groupName ?? '',
      };

      // ✅ FIX #6: CRITICAL - Stream Detector must function in iOS foreground
      // Stream Detector MUST work when app is in FOREGROUND to display INSTANT notifications (<100ms)
      // Photo will appear as attachment (not circular in iOS), but this is acceptable
      // vs waiting for FCM push which has 2-5 second delay
      // DO NOT disable this functionality - it's core to the instant notification system

      // ✅ Descargar foto del remitente para ANDROID e iOS
      String? photoPath;
      try {
        // ✅ FIX #5: Usar senderPhotoUrl directamente (ya viene del Stream Detector)
        // ELIMINADA query redundante que agregaba 50-200ms de latencia
        String? photoUrl = senderPhotoUrl;

        if (photoUrl != null && photoUrl.isNotEmpty && photoUrl != 'null') {
          ReleaseLogger.log(
            '📥 Descargando foto del remitente: $photoUrl',
            tag: 'NotificationService',
          );
          // ✅ FIX #8: Timeout agresivo de 1s (igual que iOS AppDelegate.swift:323)
          // Evita bloquear notificación por 10s si descarga falla
          // ✅ FIX #13: Usar DefaultCacheManager para aprovechar caché de imágenes (mucho más rápido)
          final file = await DefaultCacheManager()
              .getSingleFile(photoUrl)
              .timeout(Duration(seconds: 5));
          
          final bytes = await file.readAsBytes();
          // Simular response para mantener lógica existente de resize
          final response = http.Response.bytes(bytes, 200);

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            final originalImage = img.decodeImage(response.bodyBytes);

            if (originalImage != null) {
              // ✅ FIX: Usar copyResizeCropSquare para evitar distorsión si la imagen no es cuadrada
              final resizedImage = img.copyResizeCropSquare(
                originalImage,
                size: 192,
              );
              final pngBytes = img.encodePng(resizedImage);

              final directory = await getTemporaryDirectory();
              final timestamp = DateTime.now().millisecondsSinceEpoch;
              final filePath = '${directory.path}/sender_photo_$timestamp.png';
              final file = File(filePath);
              await file.writeAsBytes(pngBytes);

              if (await file.exists()) {
                photoPath = filePath;
                ReleaseLogger.log(
                  '✅ Foto del remitente procesada: $photoPath',
                  tag: 'NotificationService',
                );
              }
            }
          } else {
            ReleaseLogger.error(
              '⚠️ Respuesta inválida: ${response.statusCode}',
              tag: 'NotificationService',
            );
          }
        } else {
          ReleaseLogger.log(
            '⚠️ No hay photoURL disponible para el sender',
            tag: 'NotificationService',
          );
        }
      } catch (e) {
        ReleaseLogger.error(
          '❌ Error descargando foto del sender: $e',
          tag: 'NotificationService',
        );
      }

      // ✅ Crear Person para el REMITENTE SIN foto en el Person
      // ❌ NO usar .icon en Person - causa que la foto aparezca como adjunto pequeño
      // La foto debe ir en largeIcon del AndroidNotificationDetails
      final sender = Person(
        name: senderName,
        key: senderId,
        // ❌ NO incluir icon aquí
      );

      // ✅ Crear Person para el usuario actual (YO - el que recibe)
      final me = Person(name: 'Yo', key: 'me');

      // ✅ Usar MessagingStyleInformation para mostrar foto circular a la IZQUIERDA
      final messagingStyle = MessagingStyleInformation(
        me, // ✅ Usuario actual (el que recibe)
        groupConversation:
            false, // ✅ CRÍTICO: false para chat 1-1 (muestra foto a la izquierda)
        conversationTitle: null, // ✅ null para chat 1-1 evita "Talia · Sender"
        messages: [
          Message(
            body, // Texto del mensaje
            DateTime.now(),
            sender, // ✅ Remitente del mensaje (SIN foto en Person)
          ),
        ],
      );

      // Crear detalles de notificación Android con MessagingStyle
      // ✅ FIX #8: Usar preferencias de sonido/vibración del usuario
      final androidDetails = AndroidNotificationDetails(
        'high_importance_channel',
        'Notificaciones Importantes',
        channelDescription: 'Canal para notificaciones importantes',
        importance: Importance.max,
        priority: Priority.max,
        icon: '@mipmap/ic_launcher',
        largeIcon: photoPath != null
            ? FilePathAndroidBitmap(photoPath)
            : null, // ✅ Avatar circular grande a la IZQUIERDA
        showWhen: true,
        enableVibration: enableVibration, // ✅ FIX: Usar preferencia
        playSound: playSound, // ✅ FIX: Usar preferencia
        styleInformation:
            messagingStyle, // ✅ MessagingStyle - foto a la IZQUIERDA
        visibility: NotificationVisibility.public,
        onlyAlertOnce: false,
        autoCancel: true,
        ongoing: false,
      );

      // ✅ iOS: Usar Communication Notifications nativas via platform channel
      if (Platform.isIOS) {
        bool success = false;
        try {
          // ✅ FIX #5: Usar senderPhotoUrl directamente (ya viene del Stream Detector)
          // ELIMINADA query redundante que agregaba 50-200ms de latencia
          String? photoUrl = senderPhotoUrl;

          ReleaseLogger.log(
            '📱 [iOS FOREGROUND] Llamando a Communication Notification nativa para: $senderName',
            tag: 'NotificationService',
          );

          final result = await _notificationChannel.invokeMethod('showCommunicationNotification', {
            'senderId': senderId,
            'senderName': senderName,
            'messageText': body,
            'chatId': chatId,
            'isGroup': isGroup,
            'senderPhotoUrl': photoPath ?? photoUrl ?? '',
            'playSound': playSound, // ✅ FIX #8: Pasar preferencia de sonido
          });

          success = result == true;
          ReleaseLogger.log(
            '✅ [iOS FOREGROUND] Communication Notification resultado: $result',
            tag: 'NotificationService',
          );
        } catch (e) {
          ReleaseLogger.error(
            '❌ [iOS FOREGROUND] Error llamando a Communication Notification: $e',
            tag: 'NotificationService',
          );
        }

        // ✅ FALLBACK: Si falla la Communication Notification, usar flutter_local_notifications
        if (!success) {
          ReleaseLogger.log(
            '🔄 [iOS FOREGROUND] Fallback: usando flutter_local_notifications',
            tag: 'NotificationService',
          );
          try {
            final iosDetails = DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: playSound, // ✅ FIX #8: Usar preferencia del usuario
              threadIdentifier: chatId,
            );
            final details = NotificationDetails(iOS: iosDetails);

            // ✅ Usar ID consistente para poder cancelar después
            final contextType = isGroup ? NotificationContext.group : NotificationContext.chat;
            final notificationId = NotificationTrackingService.generateNotificationId(
              contextType,
              chatId,
              messageId: messageId,
            );

            await _localNotifications.show(
              notificationId,
              title,
              body,
              details,
              payload: jsonEncode(data),
            );

            // ✅ Trackear notificación para auto-dismiss
            await NotificationTrackingService().trackNotification(
              type: contextType,
              contextId: chatId,
              notificationId: notificationId,
            );

            ReleaseLogger.log(
              '✅ [iOS FOREGROUND] Fallback notification mostrada (id=$notificationId)',
              tag: 'NotificationService',
            );
          } catch (e2) {
            ReleaseLogger.error(
              '❌ [iOS FOREGROUND] Error en fallback: $e2',
              tag: 'NotificationService',
            );
          }
        }
        return;  // ✅ Retornar después de iOS para no continuar a Android
      } else {
        // Android: Llamar código nativo para crear ShortcutInfo (requerido para avatar)
        // flutter_local_notifications NO puede crear ShortcutInfo, necesario para Android 11+
        try {
          ReleaseLogger.log(
            '🤖 [Android] Llamando código nativo para crear notificación con ShortcutInfo',
            tag: 'NotificationService',
          );

          // ✅ Generar ID consistente para tracking y dismiss
          final contextType = isGroup ? NotificationContext.group : NotificationContext.chat;
          final notificationId = NotificationTrackingService.generateNotificationId(
            contextType,
            chatId,
            messageId: messageId,
          );

          await _notificationChannel.invokeMethod('showChatNotification', {
            'title': title,
            'body': body,
            'senderId': senderId,
            'senderName': senderName,
            'senderPhotoUrl': senderPhotoUrl ?? '', // ✅ Enviar URL HTTP, no ruta local
            'chatId': chatId,
            'isGroup': isGroup,
            'groupName': groupName ?? '',
            'notificationId': notificationId, // ✅ Pasar ID consistente al código nativo
          });

          // ✅ Trackear notificación para auto-dismiss
          await NotificationTrackingService().trackNotification(
            type: contextType,
            contextId: chatId,
            notificationId: notificationId,
          );

          ReleaseLogger.log(
            '✅ [Android] Notificación nativa creada con ShortcutInfo (id=$notificationId)',
            tag: 'NotificationService',
          );
          return; // Salir después de llamar código nativo
        } catch (e) {
          ReleaseLogger.error(
            '❌ [Android] Error llamando código nativo: $e - usando fallback',
            tag: 'NotificationService',
          );
          // Si falla, continuar con flutter_local_notifications como fallback
        }

        // Fallback: Usar flutter_local_notifications (sin ShortcutInfo, avatar puede no mostrarse correctamente)
        final details = NotificationDetails(
          android: androidDetails,
        );

        // ✅ Usar ID consistente para poder cancelar después
        final contextType = isGroup ? NotificationContext.group : NotificationContext.chat;
        final notificationId = NotificationTrackingService.generateNotificationId(
          contextType,
          chatId,
          messageId: messageId,
        );

        // ✅ Agregar distintivo "Foreground:" para identificar notificaciones del Stream Detector
        final foregroundTitle = 'Foreground: $title';

        // Mostrar notificación local en Android
        await _localNotifications.show(
          notificationId,
          foregroundTitle,
          body,
          details,
          payload: jsonEncode(data),
        );

        // ✅ Trackear notificación para auto-dismiss
        await NotificationTrackingService().trackNotification(
          type: contextType,
          contextId: chatId,
          notificationId: notificationId,
        );
      }

      ReleaseLogger.log(
        '✅ [INSTANT] Notificación local mostrada exitosamente',
        tag: 'NotificationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error mostrando notificación local instantánea: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// Limpia todas las notificaciones de un chat específico (1-1 o grupo)
  Future<void> clearChatNotifications(
    String chatId, {
    bool isGroup = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // Buscar todas las notificaciones del usuario para este chat
      final query = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: user.uid)
          .where('chatId', isEqualTo: chatId)
          .get();

      if (query.docs.isEmpty) return;

      // Borrar todas las notificaciones encontradas
      final batch = _firestore.batch();
      for (final doc in query.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();

      // Opcional: También limpiar notificaciones locales del sistema
      if (Platform.isAndroid || Platform.isIOS) {
        // Nota: No hay forma directa de limpiar notificaciones específicas del sistema
        // sin un ID específico, pero las nuevas notificaciones no aparecerán
        await _localNotifications.cancelAll();
        ReleaseLogger.log(
          '🗑️ Notificaciones locales limpiadas',
          tag: 'NotificationService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error limpiando notificaciones del chat $chatId: $e',
        tag: 'NotificationService',
      );
    }
  }

  /// Limpia todas las notificaciones de un grupo específico (alias para claridad)
  Future<void> clearGroupNotifications(String groupId) async {
    return clearChatNotifications(groupId, isGroup: true);
  }

  /// ✅ Cleanup cuando se destruya el servicio (para prevenir memory leaks)
  void dispose() {
    ReleaseLogger.log(
      '🧹 Limpiando NotificationService...',
      tag: 'NotificationService',
    );

    // Cancelar navegación pendiente
    _cancelPendingNavigation();

    // Cancelar suscripción a cambios de estado de app
    _appStateSubscription?.cancel();
    _appStateSubscription = null;

    // Cancelar listener de notificaciones de Firestore
    _notificationsStreamSubscription?.cancel();
    _notificationsStreamSubscription = null;
    _processedNotificationIds.clear();

    ReleaseLogger.log(
      '✅ NotificationService limpiado',
      tag: 'NotificationService',
    );
  }
}
