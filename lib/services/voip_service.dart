import 'dart:async';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
// V2 Architecture imports
import '../calls_v2/controllers/call_controller.dart' as calls_v2;
import '../calls_v2/services/incoming_calls_listener_service.dart';
import '../calls_v2/services/call_state_cache_service.dart';
import '../calls_v2/services/voip_token_service.dart';
import '../utils/release_logger.dart';

class VoIPService {
  static final VoIPService _instance = VoIPService._internal();
  factory VoIPService() => _instance;
  VoIPService._internal() {
    // ✅ CRITICAL FIX: Inicializar stream controller INMEDIATAMENTE
    _pendingCallNotifier = StreamController<Map<String, dynamic>>.broadcast();
    ReleaseLogger.log('🔧 [VoIP] Stream controller inicializado en constructor', tag: 'VoIPService');
  }

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final CallStateCacheService _cache = CallStateCacheService();
  final VoIPTokenService _tokenService = VoIPTokenService();

  static const MethodChannel _voipChannel = MethodChannel('com.talia.chat/voip');
  // CallKeep no tiene un stream de eventos como flutter_callkit_incoming
  // StreamSubscription? _callEventSubscription;

  // Stream para notificar cuando hay llamadas pendientes
  late StreamController<Map<String, dynamic>> _pendingCallNotifier;
  Stream<Map<String, dynamic>> get pendingCallStream {
    return _pendingCallNotifier.stream;
  }

  // ✅ V2 NAVIGATION: Callback para navegar a call screen después de aceptar desde CallKit
  Function(String callId, {bool isIncoming})? onNavigateToCall;

  // 🔄 COORDINACIÓN: Track de llamadas activas desde VoIP/CallKit
  final Set<String> _voipActiveCallIds = <String>{};

  /// Verificar si una llamada está siendo manejada por VoIP/CallKit
  bool isCallHandledByVoIP(String callId) {
    return _voipActiveCallIds.contains(callId);
  }

  /// Marcar llamada como manejada por VoIP (para evitar IncomingCallScreen)
  void markCallAsVoIPHandled(String callId) {
    _voipActiveCallIds.add(callId);
    ReleaseLogger.log('📞 [VOIP COORDINATION] Llamada $callId marcada como manejada por VoIP', tag: 'VoIPService');
  }

  /// Desmarcar llamada cuando termine
  void unmarkVoIPCall(String callId) {
    _voipActiveCallIds.remove(callId);
    ReleaseLogger.log('📞 [VOIP COORDINATION] Llamada $callId desmarcada de VoIP', tag: 'VoIPService');
  }

  /// ✅ FIX ESCENARIO CALLKIT: Limpiar tracking de llamadas VoIP más agresivamente
  void cleanupOldVoIPCalls() {
    ReleaseLogger.log(
      '🧹 [VOIP COORDINATION] Limpiando tracking VoIP. Llamadas activas: ${_voipActiveCallIds.length}',
      tag: 'VoIPService'
    );
    if (_voipActiveCallIds.isNotEmpty) {
      ReleaseLogger.log(
        '🧹 [VOIP COORDINATION] CallIds en tracking: ${_voipActiveCallIds.toList()}',
        tag: 'VoIPService'
      );
      _voipActiveCallIds.clear();
      ReleaseLogger.log('🧹 [VOIP COORDINATION] Tracking VoIP limpiado completamente', tag: 'VoIPService');
    }
  }

  /// ✅ DIAGNOSTICO: Ver qué llamadas están marcadas como VoIP
  void debugVoIPTracking() {
    ReleaseLogger.log(
      '🔍 [VOIP DEBUG] Llamadas marcadas como VoIP: ${_voipActiveCallIds.isEmpty ? "NINGUNA" : _voipActiveCallIds.toList()}',
      tag: 'VoIPService'
    );
  }

  // 🔒 LIFECYCLE MANAGEMENT para prevenir memory leaks
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Inicializar VoIP Push y CallKit
  Future<void> initialize() async {
    try {
      // 🔒 Prevenir re-inicialización innecesaria
      if (_isInitialized) {
        ReleaseLogger.log('📱 VoIP Service ya estaba inicializado', tag: 'VoIPService');
        // ✅ CRÍTICO: Aún verificar estado del token en reinicializaciones
        await _tokenService.validateAndRefreshIfNeeded();
        return;
      }

      ReleaseLogger.log('📱 Inicializando VoIP Service...', tag: 'VoIPService');

      // Configurar listener para el token VoIP desde iOS
      _voipChannel.setMethodCallHandler(_handleVoIPMethodCall);

      // Escuchar eventos de CallKit (con cleanup previo por seguridad)
      // _callEventSubscription?.cancel();
      // CallKeep no tiene un stream de eventos global como flutter_callkit_incoming
      // Los eventos se manejan individualmente en CallKitService
      // _callEventSubscription = FlutterCallkitIncoming.onEvent.listen(_handleCallKitEvent);

      // ✅ V2: Use VoIPTokenService for validation and refresh
      await _tokenService.validateAndRefreshIfNeeded();

      _isInitialized = true;

      ReleaseLogger.log('✅ VoIP Service inicializado', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ Error inicializando VoIP Service: $e', tag: 'VoIPService');
    }
  }

  /// Manejar llamadas de método desde iOS (ej: token VoIP)
  Future<dynamic> _handleVoIPMethodCall(MethodCall call) async {
    ReleaseLogger.log('📱 [VoIP] Método recibido: ${call.method}', tag: 'VoIPService');

    switch (call.method) {
      case 'onVoipToken':
        final String token = call.arguments as String;
        ReleaseLogger.log('📱 [VoIP] Token recibido: ${token.substring(0, 20)}...', tag: 'VoIPService');
        await _tokenService.saveToken(token);
        break;

      case 'onIncomingCall':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        ReleaseLogger.log('📞 [VoIP] Llamada entrante desde CallKit nativo', tag: 'VoIPService');
        ReleaseLogger.log('📞 [VoIP] Datos: $data', tag: 'VoIPService');
        // Los datos ya están siendo manejados por el listener de Firestore
        break;

      case 'onCallAccepted':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('✅ [VoIP] Llamada aceptada desde CallKit nativo: $callId', tag: 'VoIPService');

        // Buscar la llamada en Firestore para obtener los datos completos
        await _handleNativeCallAccepted(callId);
        break;

      case 'onCallDeclined':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('❌ [VoIP] Llamada RECHAZADA desde CallKit nativo: $callId', tag: 'VoIPService');

        // ✅ CRITICAL FIX: Actualizar Firestore con decline para que A vea el rechazo
        try {
          // Use V2 architecture
          final controller = calls_v2.CallController();
          await controller.declineCall(callId);
          ReleaseLogger.log('✅ [VoIP] Llamada rechazada en Firestore via CallController V2', tag: 'VoIPService');

          // NOTE: user_calls cleanup is now handled by Cloud Functions (deprecated client method)
          await IncomingCallsListenerService().clearIncomingCall(callId);
        } catch (e) {
          ReleaseLogger.error('❌ [VoIP] Error rechazando llamada via CallController V2: $e', tag: 'VoIPService');
          rethrow; // Re-throw error since no fallback available
        }
        break;

      case 'onCallEnded':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('📵 [VoIP] Llamada terminada desde CallKit nativo: $callId', tag: 'VoIPService');

        // NO llamar a endCall() - solo cerrar CallKit localmente
        // Si la llamada fue cancelada por el caller, el listener ya cerró el CallKit
        // Si el receptor presiona "rechazar", debe usar rejectCall() en lugar de endCall()
        ReleaseLogger.log('ℹ️ [VoIP] CallKit cerrado localmente, sin modificar Firestore', tag: 'VoIPService');
        break;

      default:
        ReleaseLogger.log('⚠️ [VoIP] Método desconocido: ${call.method}', tag: 'VoIPService');
    }
  }

  /// ✅ OPTIMIZED: Manejar aceptación de llamada con navegación optimista (UX improvement)
  /// OPTIMISTIC UI: Navigate IMMEDIATELY, accept call in background
  Future<void> _handleNativeCallAccepted(String callId) async {
    try {
      ReleaseLogger.log('🚀 [VoIP OPTIMISTIC] Aceptación con navegación inmediata: $callId', tag: 'VoIPService');

      // Check cache for duplicate processing
      if (!_cache.markAsProcessing(callId, CallProcessingSource.voipPush)) {
        ReleaseLogger.log('⏭️ [VoIP] Call $callId already being processed, skipping duplicate', tag: 'VoIPService');
        return;
      }

      // ✅ CRITICAL: Marcar como manejada por VoIP ANTES de procesar para evitar IncomingCallScreen
      markCallAsVoIPHandled(callId);

      // ✅ OPTIMISTIC UI: Navigate IMMEDIATELY - don't wait for Firebase
      // This gives instant response (WhatsApp-style UX)
      ReleaseLogger.log('⚡ [VoIP OPTIMISTIC] Navegando INMEDIATAMENTE a call screen', tag: 'VoIPService');
      if (onNavigateToCall != null) {
        onNavigateToCall!(callId, isIncoming: true);
        ReleaseLogger.log('✅ [VoIP OPTIMISTIC] Navegación ejecutada - usuario ve pantalla de llamada inmediatamente', tag: 'VoIPService');
      } else {
        ReleaseLogger.error('❌ [VoIP V2] onNavigateToCall callback NO configurado - no se puede navegar', tag: 'VoIPService');
      }

      // ✅ V2 Architecture: Accept call in BACKGROUND (non-blocking)
      // Screen will update reactively when Firestore updates
      ReleaseLogger.log('⚡ [VoIP V2] Aceptando llamada en background (no bloquea UI)...', tag: 'VoIPService');

      final controller = calls_v2.CallController();
      final acceptResult = await controller.acceptCall(callId);

      if (!acceptResult.success) {
        ReleaseLogger.error('❌ [VoIP V2] AcceptCall falló: ${acceptResult.error}', tag: 'VoIPService');
        // UI already showing call screen, will show error state there
        return;
      }

      // NOTE: user_calls updates are now handled by Cloud Functions (deprecated client method)
      await IncomingCallsListenerService().updateIncomingCallStatus(callId, 'accepted');

      // Clear from cache after successful processing
      _cache.clearCall(callId);

      ReleaseLogger.log('✅ [VoIP V2] Llamada aceptada en background - UI ya visible para el usuario', tag: 'VoIPService');
    } catch (e, stackTrace) {
      // Clear from cache on error
      _cache.clearCall(callId);

      ReleaseLogger.error('❌ [VoIP] Error manejando aceptación nativa: $e', tag: 'VoIPService');
      ReleaseLogger.error('❌ [VoIP] Stack trace: $stackTrace', tag: 'VoIPService');

      // ✅ CRITICAL DEBUG: Mostrar exactamente donde falló
      if (e.toString().contains('Null check operator')) {
        ReleaseLogger.error('❌ [VoIP] NULL POINTER EXCEPTION - verificar campos de callData', tag: 'VoIPService');
      }
      if (e.toString().contains('type \'Null\' is not a subtype')) {
        ReleaseLogger.error('❌ [VoIP] TYPE CAST EXCEPTION - verificar tipos de datos', tag: 'VoIPService');
      }
    }
  }

  // REMOVED: _processLegacyCallAcceptance - no longer needed after video_calls deletion

  /// Verificar y procesar token VoIP pendiente después del login exitoso
  /// En iOS, el token VoIP se recibe automáticamente pero solo se puede guardar cuando el usuario está autenticado
  Future<void> processVoIPTokenAfterLogin() async {
    try {
      ReleaseLogger.log('📱[VoIP] Verificando token VoIP pendiente después del login...', tag: 'VoIPService');

      if (_auth.currentUser == null) {
        ReleaseLogger.log('⚠️ [VoIP] Usuario no autenticado, no se puede procesar token', tag: 'VoIPService');
        return;
      }

      // En iOS, el token se maneja automáticamente por el AppDelegate
      // Este método está aquí para mantener consistencia con el FCM token
      // y por si necesitamos agregar lógica adicional en el futuro
      ReleaseLogger.log('✅ [VoIP] Usuario autenticado - el token VoIP se procesará automáticamente cuando iOS lo envíe', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error procesando token: $e', tag: 'VoIPService');
    }
  }

  // Token handling methods removed - now handled by VoIPTokenService

  /// Manejar eventos de CallKit (aceptar, rechazar, colgar)
  /// ⚠️ DEPRECATED: Este método ya no se usa con callkeep
  /// Los eventos ahora se manejan en CallKitService directamente
  /*
  Future<void> _handleCallKitEvent(CallEvent? event) async {
    if (event == null) {
      ReleaseLogger.log('📱[CallKit] EVENTO NULO RECIBIDO', tag: 'VoIPService');
      return;
    }

    ReleaseLogger.log('📱[CallKit] Evento recibido: ${event.event}', tag: 'VoIPService');
    ReleaseLogger.log('📱[CallKit] Datos: ${event.body}', tag: 'VoIPService');

    switch (event.event) {
      case Event.actionCallAccept:
        await _handleCallAccepted(event.body);
        break;

      case Event.actionCallDecline:
        await _handleCallDeclined(event.body);
        break;

      case Event.actionCallEnded:
        await _handleCallEnded(event.body);
        break;

      case Event.actionCallTimeout:
        ReleaseLogger.log('⏰ [CallKit] Llamada timeout', tag: 'VoIPService');
        break;

      default:
        ReleaseLogger.log('⚠️ [CallKit] Evento desconocido: ${event.event}', tag: 'VoIPService');
    }
  }
  */

  /// Cuando el usuario acepta la llamada desde CallKit
  Future<void> _handleCallAccepted(Map<String, dynamic>? data) async {
    try {
      ReleaseLogger.log('✅ [CallKit] Llamada aceptada - MÉTODO INICIADO', tag: 'VoIPService');
      ReleaseLogger.log('✅ [CallKit] Data recibida: ${data.toString()}', tag: 'VoIPService');

      if (data == null || data['extra'] == null) {
        ReleaseLogger.error('❌ [CallKit] Datos de llamada inválidos', tag: 'VoIPService');
        return;
      }

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;
      final callerId = extra['callerId'] as String;
      final callerName = extra['callerName'] as String;
      final channelName = extra['channelName'] as String;
      final callType = extra['callType'] as String?;
      final isEmergency = extra['isEmergency'] == 'true';

      // 📞 CRÍTICO: Marcar como manejada por VoIP para evitar conflictos
      markCallAsVoIPHandled(callId);

      ReleaseLogger.log('📞 [CallKit] Procesando llamada aceptada desde CallKit UI:', tag: 'VoIPService');
      ReleaseLogger.log('   - Call ID: $callId', tag: 'VoIPService');
      ReleaseLogger.log('   - Channel: $channelName', tag: 'VoIPService');
      ReleaseLogger.log('   - Type: $callType', tag: 'VoIPService');
      ReleaseLogger.log('   - Emergency: $isEmergency', tag: 'VoIPService');

      // ✅ V2: Use CallController
      final controller = calls_v2.CallController();
      final acceptResult = await controller.acceptCall(callId);
      if (!acceptResult.success) {
        ReleaseLogger.error('❌ [CallKit] AcceptCall falló - abortando flujo CallKit: ${acceptResult.error}', tag: 'VoIPService');
        return; // Abortar flujo completo
      }
      ReleaseLogger.log('✅ [CallKit] Llamada aceptada via CallController V2', tag: 'VoIPService');

      // NOTE: user_calls updates are now handled by Cloud Functions (deprecated client method)
      await IncomingCallsListenerService().updateIncomingCallStatus(callId, 'accepted');

      // Obtener token de Agora directamente (sin crear nueva llamada)
      ReleaseLogger.log('🎫 [CallKit] Generando token de Agora para unirse al canal: $channelName', tag: 'VoIPService');
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('generateAgoraToken').call({
        'channelName': channelName,
        'uid': 0, // Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      ReleaseLogger.log('✅ [CallKit] Token generado - UID: $uid', tag: 'VoIPService');

      // Guardar datos para navegación
      _pendingCallData = {
        'callId': callId,
        'channelName': channelName,
        'token': token,
        'uid': uid,
        'callType': callType,
        'callerName': callerName,
        'callerId': callerId,
      };

      ReleaseLogger.log('✅ [CallKit] Datos de llamada guardados para navegación', tag: 'VoIPService');
      ReleaseLogger.log('   - Caller ID: $callerId', tag: 'VoIPService');

      // Notificar inmediatamente que hay datos pendientes
      ReleaseLogger.log('🚀 [CallKit] Enviando datos al stream pendingCall', tag: 'VoIPService');
      _pendingCallNotifier.add(_pendingCallData!);
      ReleaseLogger.log('✅ [CallKit] Datos enviados al stream exitosamente', tag: 'VoIPService');

      // ✅ FIX NAVEGACIÓN: No limpiar inmediatamente - dejar que el listener procese
      // Limpiar después de un timeout para evitar memory leaks
      Timer(const Duration(seconds: 10), () {
        if (_pendingCallData != null) {
          ReleaseLogger.log('🧹 [VoIP] Limpieza automática de pendingCallData por timeout (CallKit)', tag: 'VoIPService');
          _pendingCallData = null;
        }
      });
    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error manejando aceptación: $e', tag: 'VoIPService');
    }
  }

  /// Cuando el usuario rechaza la llamada desde CallKit
  Future<void> _handleCallDeclined(Map<String, dynamic>? data) async {
    try {
      ReleaseLogger.log('🔥 [DEBUG] _handleCallDeclined MÉTODO INICIADO', tag: 'VoIPService');
      ReleaseLogger.log('❌ [CallKit] Llamada rechazada', tag: 'VoIPService');

      if (data == null || data['extra'] == null) {
        ReleaseLogger.log('❌ [DEBUG] _handleCallDeclined - data o extra es null, saliendo', tag: 'VoIPService');
        return;
      }

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;

      ReleaseLogger.log('🔥 [DEBUG] _handleCallDeclined - callId extraído: $callId', tag: 'VoIPService');
      ReleaseLogger.log('🔥 [DEBUG] _handleCallDeclined - llamando a CallController().declineCall()', tag: 'VoIPService');

      // ✅ V2: Use CallController
      final controller = calls_v2.CallController();
      await controller.declineCall(callId);
      ReleaseLogger.log('✅ [CallKit] Llamada rechazada via CallController V2', tag: 'VoIPService');

      // NOTE: user_calls cleanup is now handled by Cloud Functions (deprecated client method)
      await IncomingCallsListenerService().clearIncomingCall(callId);
      ReleaseLogger.log('✅ [CallKit] Llamada rechazada en Firestore', tag: 'VoIPService');

      // ✅ FIX: Cerrar CallKit UI inmediatamente después del rechazo
      await notifyCallEnded(callId);
      ReleaseLogger.log('✅ [CallKit] CallKit UI cerrado tras rechazo', tag: 'VoIPService');

    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error manejando rechazo: $e', tag: 'VoIPService');

      // ✅ FALLBACK: Incluso si hay error, intentar cerrar CallKit
      if (data?['extra']?['callId'] != null) {
        try {
          await notifyCallEnded(data!['extra']['callId']);
          ReleaseLogger.log('✅ [CallKit] CallKit cerrado en fallback tras error', tag: 'VoIPService');
        } catch (fallbackError) {
          ReleaseLogger.error('❌ [CallKit] Error en fallback: $fallbackError', tag: 'VoIPService');
        }
      }
    }
  }

  /// Cuando la llamada termina desde CallKit
  Future<void> _handleCallEnded(Map<String, dynamic>? data) async {
    try {
      ReleaseLogger.log('📵 [CallKit] Llamada terminada', tag: 'VoIPService');

      if (data == null || data['extra'] == null) return;

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;

      // NO llamar a endCall() - solo cerrar CallKit localmente
      // VoIP maneja el cierre automáticamente cuando detecta cambios en Firestore
      ReleaseLogger.log('ℹ️ [CallKit] CallKit cerrado localmente para: $callId', tag: 'VoIPService');
      ReleaseLogger.log('ℹ️ [CallKit] Si la llamada fue cancelada, el listener ya lo detectó', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error manejando fin de llamada: $e', tag: 'VoIPService');
    }
  }

  // Datos de llamada pendiente para navegación
  Map<String, dynamic>? _pendingCallData;

  /// Obtener y limpiar datos de llamada pendiente
  Map<String, dynamic>? getPendingCallData() {
    final data = _pendingCallData;
    _pendingCallData = null;
    return data;
  }

  /// Notificar a iOS nativo que la llamada terminó (para cerrar CallKit UI)
  Future<void> notifyCallEnded(String callId) async {
    try {
      await _voipChannel.invokeMethod('endCallKit', {'callId': callId});

      // 🔄 CLEANUP: Desmarcar llamada del tracking VoIP
      unmarkVoIPCall(callId);

      ReleaseLogger.log('✅ [VoIP] Notificado a iOS que la llamada terminó: $callId', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error notificando fin de llamada a iOS: $e', tag: 'VoIPService');
    }
  }

  // Token validation methods removed - now handled by VoIPTokenService

  /// 🔒 LIFECYCLE MANAGEMENT: Limpiar recursos y permitir re-inicialización
  void dispose() {
    ReleaseLogger.log('🗑️ Limpiando recursos VoIP Service...', tag: 'VoIPService');

    // _callEventSubscription?.cancel();
    // _callEventSubscription = null;

    _pendingCallNotifier.close();

    _isInitialized = false;

    ReleaseLogger.log('✅ VoIP Service resources disposed', tag: 'VoIPService');
  }

  /// 🔒 BACKGROUND LIFECYCLE: Limpiar recursos cuando la app va a background
  void onAppPaused() {
    ReleaseLogger.log('⏸️ VoIP Service: App pausada, manteniendo conexiones esenciales', tag: 'VoIPService');
    // No disposar completamente en pausa, VoIP debe seguir funcionando en background
  }

  /// 🔒 FOREGROUND LIFECYCLE: Re-conectar cuando la app vuelve de background
  Future<void> onAppResumed() async {
    ReleaseLogger.log('▶️ VoIP Service: App resumida', tag: 'VoIPService');

    // Verificar estado de conexiones y re-inicializar si es necesario
    if (!_isInitialized) {
      await initialize();
    }
  }
}
