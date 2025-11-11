import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'services/call_initiation_service.dart';
import 'services/call_state_service.dart';
import 'managers/agora_engine_manager.dart';
import '../../utils/release_logger.dart';
import '../../services/voip_service.dart';
import '../../services/callkit_service.dart';

/// Orchestrador principal para videollamadas siguiendo patrón de historias
///
/// Responsabilidades:
/// - Coordina todos los servicios, managers y repositories
/// - Proporciona API simple y unificada para controllers
/// - Maneja el ciclo completo de vida de videollamadas
/// - Integra con VoIP y CallKit para experiencia nativa
class VideoCallOrchestrator {
  static VideoCallOrchestrator? _instance;

  factory VideoCallOrchestrator({
    CallInitiationService? callInitiationService,
    CallStateService? callStateService,
    AgoraEngineManager? agoraManager,
    VoIPService? voipService,
    CallKitService? callKitService,
    firebase_auth.FirebaseAuth? auth,
  }) {
    _instance ??= VideoCallOrchestrator._internal(
      callInitiationService,
      callStateService,
      agoraManager,
      voipService,
      callKitService,
      auth,
    );
    return _instance!;
  }

  VideoCallOrchestrator._internal(
    CallInitiationService? callInitiationService,
    CallStateService? callStateService,
    AgoraEngineManager? agoraManager,
    VoIPService? voipService,
    CallKitService? callKitService,
    firebase_auth.FirebaseAuth? auth,
  ) : _callInitiationService = callInitiationService ?? CallInitiationService(),
      _callStateService = callStateService ?? CallStateService(),
      _agoraManager = agoraManager ?? AgoraEngineManager(),
      _voipService = voipService ?? VoIPService(),
      _callKitService = callKitService ?? CallKitService(),
      _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Repositories (delegados a servicios especializados para mejor separación)
  // Los repositories son accedidos por los services, no directamente por el orchestrator

  // Services
  final CallInitiationService _callInitiationService;
  final CallStateService _callStateService;

  // Managers
  final AgoraEngineManager _agoraManager;

  // Platform services
  final VoIPService _voipService;
  final CallKitService _callKitService;

  // Auth
  final firebase_auth.FirebaseAuth _auth;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

  // Estado del orchestrator
  bool _isInitialized = false;
  String? _currentCallId;
  Timer? _connectionTimer;

  // Callbacks públicos para comunicación con controller
  Function(String)? onConnectionStatusChanged;
  Function(Set<int>)? onRemoteUsersChanged;
  Function(bool)? onLocalUserJoined;
  Function(String)? onError;
  Function()? onCallEnded;

  // Streams públicos
  Stream<CallStateUpdate> get callStateStream =>
      _callStateService.callStateStream;
  Stream<List<IncomingCall>> get incomingCallsStream =>
      _callStateService.incomingCallsStream;

  // Getters delegados
  bool get isMuted => _agoraManager.isMuted;
  bool get isCameraOff => _agoraManager.isCameraOff;
  bool get isJoined => _agoraManager.isJoined;
  int? get localUid => _agoraManager.localUid;
  Set<int> get remoteUids => _agoraManager.remoteUids;
  String? get currentCallId => _currentCallId;
  RtcEngine? get agoraEngine => _agoraManager.engine;

  /// Inicializar orchestrator
  Future<bool> initialize() async {
    if (_isInitialized) {
      return true;
    }

    try {
      // Configurar callbacks del Agora Manager
      _setupAgoraCallbacks();

      // ✅ CRÍTICO: Registrar servicios externos en CallStateService para cancelación de notificaciones
      _callStateService.registerExternalServices(
        voipService: _voipService,
        callKitService: _callKitService,
      );

      _isInitialized = true;
      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error inicializando VideoCallOrchestrator: $e',
        tag: 'VideoCallOrchestrator',
      );
      return false;
    }
  }

  /// Iniciar una nueva videollamada
  Future<Map<String, dynamic>> startCall({
    required String receiverId,
    required String receiverName,
    required bool isVideo,
  }) async {
    try {
      ReleaseLogger.log(
        '🚀 [Orchestrator] ══════════════════════════════════════════════════════',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.log(
        '🚀 [Orchestrator] INICIANDO START CALL',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.log(
        '🚀 [Orchestrator] receiverId: $receiverId, receiverName: $receiverName, isVideo: $isVideo',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.log(
        '🚀 [Orchestrator] ══════════════════════════════════════════════════════',
        tag: 'VideoCallOrchestrator',
      );

      if (!_isInitialized) {
        ReleaseLogger.log(
          '⚙️ [Orchestrator] Orchestrator NO inicializado - inicializando...',
          tag: 'VideoCallOrchestrator',
        );
        await initialize();
      } else {
        ReleaseLogger.log(
          '✅ [Orchestrator] Orchestrator ya inicializado',
          tag: 'VideoCallOrchestrator',
        );
      }

      // 1. Iniciar llamada usando CallInitiationService
      ReleaseLogger.log(
        '📞 [Orchestrator] PASO 1: Llamando a CallInitiationService.initiateCall',
        tag: 'VideoCallOrchestrator',
      );

      final result = await _callInitiationService.initiateCall(
        receiverId: receiverId,
        receiverName: receiverName,
        isVideo: isVideo,
      );

      ReleaseLogger.log(
        '📞 [Orchestrator] RESULTADO de CallInitiationService: success=${result['success']}',
        tag: 'VideoCallOrchestrator',
      );

      if (!result['success']) {
        ReleaseLogger.error(
          '❌ [Orchestrator] CallInitiationService FALLÓ: ${result['error']}',
          tag: 'VideoCallOrchestrator',
        );
        return result;
      }

      final callId = result['callId'] as String;
      ReleaseLogger.log(
        '✅ [Orchestrator] CallId obtenido: $callId',
        tag: 'VideoCallOrchestrator',
      );

      // 2. Solo inicializar Agora Engine, NO unirse al canal
      // El join será manejado por VideoCallScreen.joinExistingCall()
      ReleaseLogger.log(
        '🎥 [Orchestrator] PASO 2: Inicializando Agora Engine (sin join)',
        tag: 'VideoCallOrchestrator',
      );

      final engineInitialized = await _agoraManager.initialize(
        isVideo: isVideo,
      );

      if (!engineInitialized) {
        ReleaseLogger.error(
          '❌ [Orchestrator] Error inicializando Agora Engine',
          tag: 'VideoCallOrchestrator',
        );
        return {
          'success': false,
          'error': 'Error inicializando motor de videollamada',
        };
      }

      ReleaseLogger.log(
        '✅ [Orchestrator] Agora Engine inicializado exitosamente',
        tag: 'VideoCallOrchestrator',
      );

      _currentCallId = callId;

      ReleaseLogger.log(
        '📝 [Orchestrator] Current call ID establecido: $_currentCallId',
        tag: 'VideoCallOrchestrator',
      );

      // 3. Iniciar monitoreo de estado
      ReleaseLogger.log(
        '🔧 [Orchestrator] PASO 3: Iniciando monitoreo para callId: $_currentCallId (startCall)',
        tag: 'VideoCallOrchestrator',
      );

      _callStateService.startMonitoringCall(_currentCallId!);

      ReleaseLogger.log(
        '🎉 [Orchestrator] START CALL COMPLETADO EXITOSAMENTE',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.log(
        '📋 [Orchestrator] Retornando resultado con callId: $callId',
        tag: 'VideoCallOrchestrator',
      );

      return result;
    } catch (e) {
      ReleaseLogger.error(
        '💥 [Orchestrator] ERROR CRÍTICO en startCall: $e',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.error(
        '🔍 [Orchestrator] Stack trace: ${StackTrace.current}',
        tag: 'VideoCallOrchestrator',
      );
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Aceptar videollamada entrante
  Future<Map<String, dynamic>> acceptCall(String callId) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      // 1. Aceptar llamada usando CallInitiationService
      final result = await _callInitiationService.acceptCall(callId);

      if (!result['success']) {
        return result;
      }

      // 2. Configurar estado local
      _currentCallId = callId;
      final channelName = result['channelName'] as String;
      final token = result['token'] as String;
      final uid = result['uid'] as int;
      final isVideo = result['isVideo'] as bool;

      // 3. Inicializar Agora Engine
      final engineInitialized = await _agoraManager.initialize(
        isVideo: isVideo,
      );
      if (!engineInitialized) {
        return {
          'success': false,
          'error': 'Error inicializando motor de videollamada',
        };
      }

      // 4. Unirse al canal
      final joined = await _agoraManager.joinChannel(
        channelId: channelName,
        token: token,
        uid: uid,
      );

      if (!joined) {
        return {
          'success': false,
          'error': 'Error uniéndose al canal de videollamada',
        };
      }

      // 5. Iniciar monitoreo de estado
      ReleaseLogger.log(
        '🔧 [Orchestrator] Iniciando monitoreo para callId: $callId (acceptCall)',
        tag: 'VideoCallOrchestrator',
      );
      _callStateService.startMonitoringCall(callId);

      return result;
    } catch (e) {
      ReleaseLogger.error(
        'Error aceptando videollamada $callId: $e',
        tag: 'VideoCallOrchestrator',
      );
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Rechazar videollamada entrante
  Future<bool> rejectCall(String callId, {String reason = 'declined'}) async {
    try {
      final success = await _callInitiationService.rejectCall(
        callId,
        reason: reason,
      );

      // Notificar a VoIP/CallKit sobre el rechazo
      if (Platform.isIOS) {
        await _voipService.notifyCallEnded(callId);
      } else if (Platform.isAndroid) {
        await _callKitService.endCall(callId);
      }

      return success;
    } catch (e) {
      ReleaseLogger.error(
        'Error rechazando videollamada $callId: $e',
        tag: 'VideoCallOrchestrator',
      );
      return false;
    }
  }

  /// Terminar videollamada activa
  Future<bool> endCall() async {
    print('🔥 [DEBUG] ENDCALL ORCHESTRATOR CALLED - currentCallId: $_currentCallId');
    ReleaseLogger.log(
      '🔚 [Orchestrator] ═══════════════════════════════════════════════════════════',
      tag: 'VideoCallOrchestrator',
    );
    ReleaseLogger.log(
      '🔚 [Orchestrator] END CALL EJECUTÁNDOSE',
      tag: 'VideoCallOrchestrator',
    );
    ReleaseLogger.log(
      '🔚 [Orchestrator] Current call ID: $_currentCallId',
      tag: 'VideoCallOrchestrator',
    );
    ReleaseLogger.log(
      '🔚 [Orchestrator] StackTrace: ${StackTrace.current}',
      tag: 'VideoCallOrchestrator',
    );
    ReleaseLogger.log(
      '🔚 [Orchestrator] ═══════════════════════════════════════════════════════════',
      tag: 'VideoCallOrchestrator',
    );

    if (_currentCallId == null) {
      ReleaseLogger.log(
        '⚠️ [Orchestrator] END CALL: No hay callId actual - retornando true',
        tag: 'VideoCallOrchestrator',
      );
      return true;
    }

    try {
      final callIdToEnd = _currentCallId!;

      ReleaseLogger.log(
        '📝 [Orchestrator] PASO 1: Terminando en Firestore callId: $callIdToEnd',
        tag: 'VideoCallOrchestrator',
      );

      // 1. Terminar llamada en Firestore
      await _callInitiationService.endCall(callIdToEnd);

      ReleaseLogger.log(
        '✅ [Orchestrator] PASO 1 COMPLETADO: Llamada terminada en Firestore',
        tag: 'VideoCallOrchestrator',
      );

      ReleaseLogger.log(
        '📞 [Orchestrator] PASO 2: Saliendo del canal de Agora',
        tag: 'VideoCallOrchestrator',
      );

      // 2. Salir del canal de Agora
      await _agoraManager.leaveChannel();

      ReleaseLogger.log(
        '✅ [Orchestrator] PASO 2 COMPLETADO: Salido del canal Agora',
        tag: 'VideoCallOrchestrator',
      );

      ReleaseLogger.log(
        '🔧 [Orchestrator] PASO 3: Deteniendo monitoreo para $callIdToEnd',
        tag: 'VideoCallOrchestrator',
      );

      // 3. Detener monitoreo
      _callStateService.stopMonitoringCall(callIdToEnd);

      ReleaseLogger.log(
        '✅ [Orchestrator] PASO 3 COMPLETADO: Monitoreo detenido',
        tag: 'VideoCallOrchestrator',
      );

      // 4. Notificar a VoIP/CallKit
      if (Platform.isIOS) {
        ReleaseLogger.log(
          '🍎 [Orchestrator] PASO 4: Notificando iOS VoIP',
          tag: 'VideoCallOrchestrator',
        );
        await _voipService.notifyCallEnded(callIdToEnd);
      } else if (Platform.isAndroid) {
        ReleaseLogger.log(
          '🤖 [Orchestrator] PASO 4: Notificando Android CallKit',
          tag: 'VideoCallOrchestrator',
        );
        await _callKitService.endCall(callIdToEnd);
      }

      ReleaseLogger.log(
        '✅ [Orchestrator] PASO 4 COMPLETADO: Notificaciones enviadas',
        tag: 'VideoCallOrchestrator',
      );

      ReleaseLogger.log(
        '🧹 [Orchestrator] PASO 5: Limpiando estado local',
        tag: 'VideoCallOrchestrator',
      );

      // 5. Limpiar estado local
      _cleanup();

      ReleaseLogger.log(
        '✅ [Orchestrator] PASO 5 COMPLETADO: Estado local limpio',
        tag: 'VideoCallOrchestrator',
      );

      ReleaseLogger.log(
        '📢 [Orchestrator] PASO 6: Notificando callback onCallEnded',
        tag: 'VideoCallOrchestrator',
      );

      // 6. Notificar al controller
      onCallEnded?.call();

      ReleaseLogger.log(
        '🎉 [Orchestrator] END CALL COMPLETADO EXITOSAMENTE',
        tag: 'VideoCallOrchestrator',
      );

      return true;
    } catch (e) {
      ReleaseLogger.error(
        '💥 [Orchestrator] ERROR en endCall: $e',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.error(
        '🔍 [Orchestrator] Stack trace del error: ${StackTrace.current}',
        tag: 'VideoCallOrchestrator',
      );

      // Forzar cleanup local aunque falle el server
      ReleaseLogger.log(
        '🧹 [Orchestrator] FORZANDO cleanup por error',
        tag: 'VideoCallOrchestrator',
      );
      _cleanup();
      onCallEnded?.call();
      return false;
    }
  }

  /// Alternar estado del micrófono
  Future<bool> toggleMute() async {
    return await _agoraManager.toggleMute();
  }

  /// Alternar estado de la cámara
  Future<bool> toggleCamera() async {
    return await _agoraManager.toggleCamera();
  }

  /// Cambiar cámara (frontal/trasera)
  Future<bool> switchCamera() async {
    return await _agoraManager.switchCamera();
  }

  /// Unirse a un canal existente sin crear nueva llamada
  ///
  /// Este método se usa cuando las credenciales ya fueron creadas
  /// por un proceso previo de inicio de llamada
  Future<bool> joinExistingChannel({
    required String callId,
    required String channelName,
    required String token,
    required int uid,
    required bool isVideo,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      ReleaseLogger.log(
        '🔗 [Orchestrator] Uniéndose a canal existente: $channelName',
        tag: 'VideoCallOrchestrator',
      );

      // Inicializar Agora Engine sin crear nueva llamada
      final engineInitialized = await _agoraManager.initialize(
        isVideo: isVideo,
      );
      if (!engineInitialized) {
        ReleaseLogger.error(
          '❌ [Orchestrator] Error inicializando Agora Engine',
          tag: 'VideoCallOrchestrator',
        );
        return false;
      }

      // Unirse al canal directamente con credenciales existentes
      final joined = await _agoraManager.joinChannel(
        channelId: channelName,
        token: token,
        uid: uid,
      );

      if (!joined) {
        ReleaseLogger.error(
          '❌ [Orchestrator] Error uniéndose al canal $channelName',
          tag: 'VideoCallOrchestrator',
        );
        return false;
      }

      // Configurar timeout de conexión
      _setupConnectionTimeout();

      // ✅ CRÍTICO: Iniciar monitoreo de estado de llamada
      // Sin esto, la UI no detecta cuando el otro usuario termina la llamada
      _currentCallId = callId;
      _callStateService.startMonitoringCall(callId);

      ReleaseLogger.log(
        '🔧 [Orchestrator] Iniciando monitoreo de estado para callId: $callId',
        tag: 'VideoCallOrchestrator',
      );

      ReleaseLogger.log(
        '✅ [Orchestrator] Unido exitosamente al canal existente',
        tag: 'VideoCallOrchestrator',
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [Orchestrator] Error uniéndose al canal existente: $e',
        tag: 'VideoCallOrchestrator',
      );
      return false;
    }
  }

  /// Iniciar monitoreo de llamadas entrantes
  void startMonitoringIncomingCalls() {
    final currentUser = _auth.currentUser;
    if (currentUser != null) {
      _callStateService.startMonitoringIncomingCalls(currentUser.uid);
    }
  }

  /// Detener monitoreo de llamadas entrantes
  void stopMonitoringIncomingCalls() {
    _callStateService.stopMonitoringIncomingCalls();
  }

  /// Obtener llamadas activas del usuario actual
  Future<List<ActiveCall>> getActiveCalls() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return [];
    }
    return await _callStateService.getActiveCalls(currentUser.uid);
  }

  /// Verificar si hay llamadas activas
  Future<bool> hasActiveCalls() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return false;
    }
    return await _callStateService.hasActiveCalls(currentUser.uid);
  }

  /// Legacy compatibility method for watching incoming calls
  /// This method provides backward compatibility with the old VideoCallService interface
  Stream<QuerySnapshot> watchIncomingCalls(String userId) {
    return FirebaseFirestore.instance
        .collection('video_calls')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'calling')
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  /// Legacy compatibility method for starting group video calls
  Future<Map<String, dynamic>> startGroupCall({
    required String groupId,
    required String groupName,
    required List<String> memberIds,
  }) async {
    // For now, group calls use the same infrastructure but with group context
    // This is a simplified implementation - full group calls would require more complex logic
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return {'success': false, 'error': 'Usuario no autenticado'};
    }

    try {
      // Start a call with the first available member for now
      if (memberIds.isNotEmpty) {
        final result = await startCall(
          receiverId: memberIds.first,
          receiverName: groupName,
          isVideo: true,
        );
        // Add channelName to the result
        final channelName = result['channelName'] ?? 'group_${groupId}_${DateTime.now().millisecondsSinceEpoch}';
        return {
          'success': true,
          'channelName': channelName,
          ...result,
        };
      } else {
        return {'success': false, 'error': 'No hay miembros disponibles para la llamada'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Legacy compatibility method for starting group audio calls
  Future<Map<String, dynamic>> startGroupAudioCall({
    required String groupId,
    required String groupName,
    required List<String> memberIds,
  }) async {
    // For now, group calls use the same infrastructure but with group context
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return {'success': false, 'error': 'Usuario no autenticado'};
    }

    try {
      // Start an audio call with the first available member for now
      if (memberIds.isNotEmpty) {
        final result = await startCall(
          receiverId: memberIds.first,
          receiverName: groupName,
          isVideo: false,
        );
        // Add channelName to the result
        final channelName = result['channelName'] ?? 'group_${groupId}_${DateTime.now().millisecondsSinceEpoch}';
        return {
          'success': true,
          'channelName': channelName,
          ...result,
        };
      } else {
        return {'success': false, 'error': 'No hay miembros disponibles para la llamada'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Configurar callbacks del Agora Manager
  void _setupAgoraCallbacks() {
    _agoraManager.onLocalUserJoined = (joined) {
      ReleaseLogger.log(
        '📱 [Orchestrator] Local user joined callback: $joined',
        tag: 'VideoCallOrchestrator',
      );
      onLocalUserJoined?.call(joined);
    };

    _agoraManager.onRemoteUsersChanged = (remoteUids) {
      ReleaseLogger.log(
        '👥 [Orchestrator] Remote users changed callback: ${remoteUids.length} users - $remoteUids',
        tag: 'VideoCallOrchestrator',
      );
      onRemoteUsersChanged?.call(remoteUids);
    };

    _agoraManager.onConnectionStatusChanged = (status) {
      ReleaseLogger.log(
        '🔄 [Orchestrator] Connection status callback: $status',
        tag: 'VideoCallOrchestrator',
      );
      onConnectionStatusChanged?.call(status);
    };

    _agoraManager.onError = (error) {
      ReleaseLogger.error(
        '❌ [Orchestrator] Error callback: $error',
        tag: 'VideoCallOrchestrator',
      );
      onError?.call(error);
    };
  }

  /// Configurar timeout de conexión
  void _setupConnectionTimeout() {
    ReleaseLogger.log(
      '⏰ [Orchestrator] CONFIGURANDO CONNECTION TIMEOUT - 30 segundos',
      tag: 'VideoCallOrchestrator',
    );

    _connectionTimer?.cancel();

    ReleaseLogger.log(
      '⏰ [Orchestrator] Estado actual isJoined: ${_agoraManager.isJoined}',
      tag: 'VideoCallOrchestrator',
    );

    _connectionTimer = Timer(const Duration(seconds: 30), () {
      ReleaseLogger.log(
        '⏰ [Orchestrator] 🚨 CONNECTION TIMEOUT ACTIVADO - 30 segundos transcurridos',
        tag: 'VideoCallOrchestrator',
      );
      ReleaseLogger.log(
        '⏰ [Orchestrator] Estado isJoined al timeout: ${_agoraManager.isJoined}',
        tag: 'VideoCallOrchestrator',
      );

      if (!_agoraManager.isJoined) {
        ReleaseLogger.log(
          '💥 [Orchestrator] TIMEOUT: Usuario no se unió - TERMINANDO LLAMADA',
          tag: 'VideoCallOrchestrator',
        );
        onError?.call('Timeout de conexión. No se pudo establecer la llamada.');
        endCall();
      } else {
        ReleaseLogger.log(
          '✅ [Orchestrator] TIMEOUT: Usuario YA está unido - NO terminar llamada',
          tag: 'VideoCallOrchestrator',
        );
      }
    });

    ReleaseLogger.log(
      '⏰ [Orchestrator] CONNECTION TIMEOUT establecido para 30 segundos',
      tag: 'VideoCallOrchestrator',
    );
  }

  /// Limpiar recursos y estado local
  void _cleanup() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
    _currentCallId = null;
  }

  /// Obtener información de debug
  Map<String, dynamic> getDebugInfo() {
    return {
      'orchestrator': {
        'isInitialized': _isInitialized,
        'currentCallId': _currentCallId,
        'hasConnectionTimer': _connectionTimer != null,
      },
      'agoraManager': _agoraManager.getDebugInfo(),
    };
  }

  /// Dispose completo del orchestrator
  Future<void> dispose() async {
    // Terminar llamada activa si existe
    if (_currentCallId != null) {
      await endCall();
    }

    // Detener monitoreos
    stopMonitoringIncomingCalls();

    // Limpiar managers y services
    await _agoraManager.dispose();
    _callStateService.dispose();

    // Limpiar estado
    _cleanup();
    _isInitialized = false;

    // Clear callbacks
    onConnectionStatusChanged = null;
    onRemoteUsersChanged = null;
    onLocalUserJoined = null;
    onError = null;
    onCallEnded = null;
  }
}
