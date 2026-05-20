import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
// V2 Architecture imports
import '../calls_v2/controllers/call_controller.dart' as calls_v2;
import '../calls_v2/services/agora_engine_service.dart';
import '../calls_v2/services/call_state_cache_service.dart';
import '../calls_v2/services/voip_token_service.dart';
import '../utils/release_logger.dart';

class VoIPService {
  static final VoIPService _instance = VoIPService._internal();
  factory VoIPService() => _instance;
  VoIPService._internal() {
    // ✅ CRITICAL FIX: Inicializar stream controllers INMEDIATAMENTE
    _pendingCallNotifier = StreamController<Map<String, dynamic>>.broadcast();
    _callKitEndedNotifier = StreamController<String>.broadcast();
    ReleaseLogger.log('🔧 [VoIP] Stream controllers inicializados en constructor', tag: 'VoIPService');
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

  // ✅ Stream para notificar cuando CallKit termina una llamada activa
  // AgoraCallScreen escucha este stream para terminar la llamada correctamente
  late StreamController<String> _callKitEndedNotifier;
  Stream<String> get callKitEndedStream => _callKitEndedNotifier.stream;

  // ✅ V2 NAVIGATION: Callback para navegar a call screen después de aceptar desde CallKit
  Function(String callId, {bool isIncoming})? _onNavigateToCall;

  // ✅ FIX: Store pending call when callback is not ready (app launching from killed state)
  String? _pendingCallId;

  /// Setter for onNavigateToCall that processes any pending calls
  set onNavigateToCall(Function(String callId, {bool isIncoming})? callback) {
    _onNavigateToCall = callback;
    ReleaseLogger.log('✅ [VoIP] onNavigateToCall callback configurado', tag: 'VoIPService');

    // Process pending call if any
    if (callback != null && _pendingCallId != null) {
      final callId = _pendingCallId!;
      _pendingCallId = null;
      ReleaseLogger.log('🔄 [VoIP] Procesando llamada pendiente: $callId', tag: 'VoIPService');
      _processPendingCall(callId, callback);
    }
  }

  /// Process a pending call - verify it's still active before navigating
  Future<void> _processPendingCall(
    String callId,
    Function(String callId, {bool isIncoming}) callback,
  ) async {
    try {
      // ✅ FIX: Verify call is still active before navigating
      // This handles the case where caller hung up while receiver's app was initializing
      final callDoc = await FirebaseFirestore.instance
          .collection('calls_v2')
          .doc(callId)
          .get();

      if (!callDoc.exists) {
        ReleaseLogger.log('⚠️ [VoIP] Llamada pendiente $callId ya no existe', tag: 'VoIPService');
        return;
      }

      final callData = callDoc.data()!;
      final endedAt = callData['endedAt'];

      if (endedAt != null) {
        ReleaseLogger.log('⚠️ [VoIP] Llamada pendiente $callId ya terminó - no navegando', tag: 'VoIPService');
        // Clean up CallKit UI since call is already ended
        await _endCallKitUI(callId);
        return;
      }

      // Call is still active, proceed with navigation
      ReleaseLogger.log('✅ [VoIP] Llamada pendiente $callId sigue activa - navegando', tag: 'VoIPService');
      callback(callId, isIncoming: true);
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error procesando llamada pendiente: $e', tag: 'VoIPService');
      // On error, try to navigate anyway - AgoraCallScreen will handle if call doesn't exist
      callback(callId, isIncoming: true);
    }
  }

  /// End CallKit UI for a specific call
  /// ✅ FIX: Use native method channel instead of FlutterCallkitIncoming
  /// The CallKit was shown natively in AppDelegate with a different UUID,
  /// so we need to use the native endCallKit method that has the UUID mapping
  Future<void> _endCallKitUI(String callId) async {
    try {
      ReleaseLogger.log('📵 [VoIP] Cerrando CallKit UI para $callId via native channel', tag: 'VoIPService');

      // ✅ FIX: Use native method channel that has the UUID mapping
      await _voipChannel.invokeMethod('endCallKit', {'callId': callId});

      // Also try the plugin as fallback (for calls shown via plugin)
      try {
        await FlutterCallkitIncoming.endCall(callId);
        await FlutterCallkitIncoming.endAllCalls();
      } catch (e) {
        // Ignore - the native channel should have handled it
      }

      ReleaseLogger.log('✅ [VoIP] CallKit UI cerrado para $callId', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error cerrando CallKit UI: $e', tag: 'VoIPService');
    }
  }

  /// Getter for onNavigateToCall
  Function(String callId, {bool isIncoming})? get onNavigateToCall => _onNavigateToCall;

  // 🔄 COORDINACIÓN: Track de llamadas activas desde VoIP/CallKit
  final Set<String> _voipActiveCallIds = <String>{};

  // ✅ FIX: Listeners para detectar cuando el caller corta antes de que B conteste
  // Esto cierra el CallKit UI si la llamada se cancela mientras B no ha aceptado
  final Map<String, StreamSubscription<DocumentSnapshot>> _incomingCallListeners = {};

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

  /// ✅ FIX: Escuchar cuando una llamada entrante es cancelada por el caller
  /// Esto cierra el CallKit UI si A corta antes de que B conteste
  void _watchIncomingCallForCancellation(String callId) {
    // Evitar duplicados
    if (_incomingCallListeners.containsKey(callId)) {
      ReleaseLogger.log('⏭️ [VoIP] Ya escuchando llamada $callId', tag: 'VoIPService');
      return;
    }

    ReleaseLogger.log('👁️ [VoIP] Iniciando listener para detectar cancelación de llamada $callId', tag: 'VoIPService');

    final subscription = _firestore
        .collection('calls_v2')
        .doc(callId)
        .snapshots()
        .listen((snapshot) async {
      if (!snapshot.exists) {
        ReleaseLogger.log('⚠️ [VoIP] Llamada $callId ya no existe - cerrando CallKit', tag: 'VoIPService');
        await _endCallKitUI(callId);
        _cancelIncomingCallListener(callId);
        return;
      }

      final data = snapshot.data();
      final endedAt = data?['endedAt'];

      if (endedAt != null) {
        ReleaseLogger.log('📵 [VoIP] Llamada $callId fue cancelada por el caller - cerrando CallKit', tag: 'VoIPService');
        await _endCallKitUI(callId);
        _cancelIncomingCallListener(callId);
      }
    }, onError: (e) {
      ReleaseLogger.error('❌ [VoIP] Error en listener de llamada $callId: $e', tag: 'VoIPService');
      _cancelIncomingCallListener(callId);
    });

    _incomingCallListeners[callId] = subscription;
  }

  /// Cancelar el listener de una llamada entrante
  void _cancelIncomingCallListener(String callId) {
    final subscription = _incomingCallListeners.remove(callId);
    subscription?.cancel();
    ReleaseLogger.log('🛑 [VoIP] Listener de llamada $callId cancelado', tag: 'VoIPService');
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

        // ✅ FIX: Iniciar listener para detectar si el caller corta antes de que B acepte
        // Esto cierra el CallKit UI automáticamente si A cancela la llamada
        final String? callId = data['callId'] as String?;
        if (callId != null) {
          _watchIncomingCallForCancellation(callId);
        }
        break;

      case 'onCallAccepted':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('✅ [VoIP] Llamada aceptada desde CallKit nativo: $callId', tag: 'VoIPService');

        // ✅ FIX: Cancelar listener de cancelación ya que la llamada fue aceptada
        _cancelIncomingCallListener(callId);

        // Buscar la llamada en Firestore para obtener los datos completos
        await _handleNativeCallAccepted(callId);
        break;

      case 'onCallDeclined':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('❌ [VoIP] Llamada RECHAZADA desde CallKit nativo: $callId', tag: 'VoIPService');

        // ✅ FIX: Cancelar listener de cancelación ya que la llamada fue rechazada
        _cancelIncomingCallListener(callId);

        // ✅ CRITICAL FIX: Actualizar Firestore con decline para que A vea el rechazo
        try {
          // Use V2 architecture
          final controller = calls_v2.CallController();
          await controller.declineCall(callId);
          ReleaseLogger.log('✅ [VoIP] Llamada rechazada en Firestore via CallController V2', tag: 'VoIPService');
        } catch (e) {
          ReleaseLogger.error('❌ [VoIP] Error rechazando llamada via CallController V2: $e', tag: 'VoIPService');
          rethrow; // Re-throw error since no fallback available
        }
        break;

      case 'onCallEnded':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('📵 [VoIP] Llamada terminada desde CallKit nativo: $callId', tag: 'VoIPService');

        // ✅ FIX: Cancelar listener de cancelación
        _cancelIncomingCallListener(callId);

        // ✅ FIX: Terminar la llamada directamente via CallController
        // Esto soluciona el problema donde B cuelga desde CallKit pero no deja el canal de Agora
        // causando que A detecte la desconexión 26 segundos después por timeout
        //
        // NOTA: No podemos depender de que AgoraCallScreen escuche el stream porque en iOS
        // cuando la app está en background, el initState() de AgoraCallScreen no se ejecuta correctamente
        await _handleCallKitEnded(callId);
        break;

      case 'onVideoCallReady':
        // ✅ FIX VIDEO FROM LOCK SCREEN: iOS tells us audio is ready and we should show video UI
        // This happens after user answers from lock screen and audio session activates
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('📹 [VoIP] Video call ready notification from iOS: $callId', tag: 'VoIPService');
        await _handleVideoCallReady(callId);
        break;

      case 'onCallCancelled':
        // ✅ FIX: Handle call cancellation from VoIP push
        // This is sent by the server when the caller cancels before receiver answers
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('📵 [VoIP] Llamada cancelada desde VoIP push: $callId', tag: 'VoIPService');

        // Cancel any listener for this call
        _cancelIncomingCallListener(callId);

        // Unmark from VoIP tracking
        unmarkVoIPCall(callId);
        break;

      default:
        ReleaseLogger.log('⚠️ [VoIP] Método desconocido: ${call.method}', tag: 'VoIPService');
    }
  }

  /// ✅ FIX AUDIO FROM LOCK SCREEN: Accept AND join Agora immediately
  /// This fixes the issue where audio calls answered from lock screen
  /// had no audio until the user opened the app, because:
  /// - VoIPService only accepted in Firestore
  /// - AgoraCallScreen.initState() didn't run until app was in foreground
  /// - Without joining Agora, there was no audio
  ///
  /// Now we join Agora immediately here, and AgoraCallScreen will detect
  /// that we're already in the channel and skip the join.
  Future<void> _handleNativeCallAccepted(String callId) async {
    try {
      ReleaseLogger.log('📞 [VoIP] Call accepted from CallKit: $callId', tag: 'VoIPService');

      // Check cache for duplicate processing
      if (!_cache.markAsProcessing(callId, CallProcessingSource.voipPush)) {
        ReleaseLogger.log('⏭️ [VoIP] Call $callId already being processed, skipping duplicate', tag: 'VoIPService');
        return;
      }

      // ✅ Mark as handled by VoIP to prevent IncomingCallScreen
      markCallAsVoIPHandled(callId);

      final controller = calls_v2.CallController();
      controller.initialize();

      // ✅ FIX: Accept AND join Agora immediately for instant audio
      // This is critical for calls answered from lock screen
      ReleaseLogger.log('📞 [VoIP] Accepting call AND joining Agora for instant audio', tag: 'VoIPService');

      // Step 1: Accept the call (this also joins Agora via acceptCall)
      final acceptResult = await controller.acceptCall(callId);
      if (acceptResult.success) {
        ReleaseLogger.log('✅ [VoIP] Call accepted AND joined Agora successfully', tag: 'VoIPService');
        // Mark as accepted so AgoraCallScreen knows we're already in channel
        _cache.markCallAsAccepted(callId);
      } else {
        ReleaseLogger.error('❌ [VoIP] Failed to accept call: ${acceptResult.error}', tag: 'VoIPService');
      }

      // ✅ Navigation will happen via onVideoCallReady when audio session activates
      // At this point, audio is already connected via Agora!
      ReleaseLogger.log('✅ [VoIP] Audio connected, waiting for onVideoCallReady to show UI', tag: 'VoIPService');

      // Clear from cache
      _cache.clearCall(callId);
    } catch (e, stackTrace) {
      _cache.clearCall(callId);
      ReleaseLogger.error('❌ [VoIP] Error accepting call: $e', tag: 'VoIPService');
      ReleaseLogger.error('❌ [VoIP] Stack trace: $stackTrace', tag: 'VoIPService');
    }
  }

  // REMOVED: _processLegacyCallAcceptance - no longer needed after video_calls deletion

  /// ✅ FIX VIDEO FROM LOCK SCREEN: Handle video call ready notification from iOS
  /// This is called when audio session activates after user answers from lock screen
  /// At this point, the call is already connected via Agora, we just need to show the UI
  Future<void> _handleVideoCallReady(String callId) async {
    try {
      ReleaseLogger.log('📹 [VoIP] Handling video call ready: $callId', tag: 'VoIPService');

      // Force navigation to call screen - the call is already accepted and connected
      // We just need to show the video UI now that iOS allows it
      if (_onNavigateToCall != null) {
        ReleaseLogger.log('📹 [VoIP] Forcing navigation to video call screen', tag: 'VoIPService');
        _onNavigateToCall!(callId, isIncoming: true);
        ReleaseLogger.log('✅ [VoIP] Video call navigation executed', tag: 'VoIPService');
      } else {
        ReleaseLogger.error('❌ [VoIP] No navigation callback for video call', tag: 'VoIPService');
        // Store as pending for when callback is ready
        _pendingCallId = callId;
      }
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error handling video call ready: $e', tag: 'VoIPService');
    }
  }

  /// Verificar y procesar token VoIP pendiente después del login exitoso
  /// En iOS, el token VoIP se recibe automáticamente pero solo se puede guardar cuando el usuario está autenticado
  Future<void> processVoIPTokenAfterLogin() async {
    try {
      ReleaseLogger.log('📱[VoIP] Solicitando token VoIP después del login...', tag: 'VoIPService');

      if (_auth.currentUser == null) {
        ReleaseLogger.log('⚠️ [VoIP] Usuario no autenticado, no se puede procesar token', tag: 'VoIPService');
        return;
      }

      // Solo iOS usa VoIP push
      if (!Platform.isIOS) {
        ReleaseLogger.log('📱 [VoIP] Android no usa VoIP push - skip', tag: 'VoIPService');
        return;
      }

      // ✅ FIX: Solicitar token VoIP inmediatamente después del login
      // Antes solo logueaba pero no pedía el token, causando que el usuario
      // tuviera que cerrar y abrir la app para que se registrara
      final token = await _tokenService.requestFreshToken();
      if (token != null) {
        ReleaseLogger.log('✅ [VoIP] Token VoIP obtenido después del login: ${token.substring(0, 20)}...', tag: 'VoIPService');
      } else {
        ReleaseLogger.log('⚠️ [VoIP] No se pudo obtener token VoIP después del login', tag: 'VoIPService');
      }
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

  /// ✅ FIX: Handle CallKit ended event by directly ending the call
  /// This is called when user hangs up from iOS CallKit native UI during an active call.
  /// We must end the call properly (leave Agora + update Firestore) otherwise the other
  /// party will only detect the disconnect after ~26 seconds via Agora timeout.
  ///
  /// CRITICAL: iOS gives very little time after CallKit ends. We must:
  /// 1. Leave Agora channel FIRST (most important for other party to see disconnect)
  /// 2. Update Firestore SECOND
  /// 3. Emit to stream LAST (for UI cleanup)
  Future<void> _handleCallKitEnded(String callId) async {
    try {
      ReleaseLogger.log('🔚 [VoIP] Handling CallKit ended for call: $callId', tag: 'VoIPService');

      // ✅ CRITICAL FIX: Check if app initiated the end
      // If AgoraCallScreen called endCall(), it will handle cleanup.
      // We should NOT do duplicate cleanup here (especially dispose which causes crash)
      if (_cache.isCallEndingFromApp(callId)) {
        ReleaseLogger.log(
          '⏭️ [VoIP] Call $callId is ending from app - skipping VoIP cleanup to avoid race condition',
          tag: 'VoIPService',
        );
        // Just emit to stream for any listeners, but don't do Agora/Firestore cleanup
        _callKitEndedNotifier.add(callId);
        unmarkVoIPCall(callId);
        return;
      }

      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.log('⚠️ [VoIP] No current user, cannot end call', tag: 'VoIPService');
        return;
      }

      // ✅ STEP 1: Leave Agora channel IMMEDIATELY (most critical)
      // This ensures the other party sees us disconnect right away
      final agoraEngine = AgoraEngineService();
      ReleaseLogger.log('📤 [VoIP] Attempting to leave Agora channel (isInChannel: ${agoraEngine.isInChannel})...', tag: 'VoIPService');

      if (agoraEngine.engine != null && agoraEngine.isInChannel) {
        try {
          await agoraEngine.leaveChannel();
          ReleaseLogger.log('✅ [VoIP] Left Agora channel successfully', tag: 'VoIPService');
        } catch (e) {
          ReleaseLogger.error('⚠️ [VoIP] Error leaving Agora channel: $e', tag: 'VoIPService');
        }
      } else {
        ReleaseLogger.log('⚠️ [VoIP] Agora engine is null or not in channel, skipping leaveChannel', tag: 'VoIPService');
      }

      // ✅ STEP 2: Update Firestore to mark call as ended
      ReleaseLogger.log('📝 [VoIP] Updating Firestore to end call $callId', tag: 'VoIPService');
      try {
        await _firestore.collection('calls_v2').doc(callId).update({
          'endedAt': FieldValue.serverTimestamp(),
          'endedBy': currentUserId,
        });
        ReleaseLogger.log('✅ [VoIP] Firestore updated successfully', tag: 'VoIPService');
      } catch (e) {
        ReleaseLogger.error('⚠️ [VoIP] Error updating Firestore: $e', tag: 'VoIPService');
      }

      // ✅ STEP 3: Emit to stream for UI cleanup (least critical)
      _callKitEndedNotifier.add(callId);

      // ✅ REMOVED: Don't dispose engine here!
      // The engine cleanup is handled by AgoraCallScreen.dispose()
      // Disposing here while AgoraCallScreen is still using it causes crash

      unmarkVoIPCall(callId);
      ReleaseLogger.log('✅ [VoIP] Call $callId ended successfully via VoIPService', tag: 'VoIPService');

    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [VoIP] Error handling CallKit ended: $e', tag: 'VoIPService');
      ReleaseLogger.error('❌ [VoIP] Stack trace: $stackTrace', tag: 'VoIPService');
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
  /// ✅ Solo ejecuta en iOS - Android no tiene este method channel
  Future<void> notifyCallEnded(String callId) async {
    // 🔄 CLEANUP: Desmarcar llamada del tracking VoIP (ambas plataformas)
    unmarkVoIPCall(callId);

    // Solo iOS tiene el method channel endCallKit
    if (!Platform.isIOS) {
      ReleaseLogger.log('ℹ️ [VoIP] Android - skipping endCallKit (not needed)', tag: 'VoIPService');
      return;
    }

    try {
      await _voipChannel.invokeMethod('endCallKit', {'callId': callId});
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

    // ✅ FIX: Cancelar todos los listeners de llamadas entrantes
    for (final subscription in _incomingCallListeners.values) {
      subscription.cancel();
    }
    _incomingCallListeners.clear();

    _pendingCallNotifier.close();
    _callKitEndedNotifier.close();

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
