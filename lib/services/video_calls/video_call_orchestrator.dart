import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
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
  static final VideoCallOrchestrator _instance = VideoCallOrchestrator._internal();
  factory VideoCallOrchestrator() => _instance;
  VideoCallOrchestrator._internal();

  // Repositories (delegados a servicios especializados para mejor separación)
  // Los repositories son accedidos por los services, no directamente por el orchestrator

  // Services
  final CallInitiationService _callInitiationService = CallInitiationService();
  final CallStateService _callStateService = CallStateService();

  // Managers
  final AgoraEngineManager _agoraManager = AgoraEngineManager();

  // Platform services
  final VoIPService _voipService = VoIPService();
  final CallKitService _callKitService = CallKitService();

  // Auth
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;

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
  Stream<CallStateUpdate> get callStateStream => _callStateService.callStateStream;
  Stream<List<IncomingCall>> get incomingCallsStream => _callStateService.incomingCallsStream;

  // Getters delegados
  bool get isMuted => _agoraManager.isMuted;
  bool get isCameraOff => _agoraManager.isCameraOff;
  bool get isJoined => _agoraManager.isJoined;
  int? get localUid => _agoraManager.localUid;
  Set<int> get remoteUids => _agoraManager.remoteUids;
  String? get currentCallId => _currentCallId;

  /// Inicializar orchestrator
  Future<bool> initialize() async {
    if (_isInitialized) {
      return true;
    }

    try {
      // Configurar callbacks del Agora Manager
      _setupAgoraCallbacks();

      _isInitialized = true;
      return true;

    } catch (e) {
      ReleaseLogger.error('Error inicializando VideoCallOrchestrator: $e', tag: 'VideoCallOrchestrator');
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
      if (!_isInitialized) {
        await initialize();
      }

      // 1. Iniciar llamada usando CallInitiationService
      final result = await _callInitiationService.initiateCall(
        receiverId: receiverId,
        receiverName: receiverName,
        isVideo: isVideo,
      );

      if (!result['success']) {
        return result;
      }

      // 2. Configurar estado local
      _currentCallId = result['callId'];
      final channelName = result['channelName'] as String;
      final token = result['token'] as String;
      final uid = result['uid'] as int;

      // 3. Inicializar Agora Engine
      final engineInitialized = await _agoraManager.initialize(isVideo: isVideo);
      if (!engineInitialized) {
        return {'success': false, 'error': 'Error inicializando motor de videollamada'};
      }

      // 4. Unirse al canal
      final joined = await _agoraManager.joinChannel(
        channelId: channelName,
        token: token,
        uid: uid,
      );

      if (!joined) {
        return {'success': false, 'error': 'Error uniéndose al canal de videollamada'};
      }

      // 5. Iniciar monitoreo de estado
      if (_currentCallId != null) {
        _callStateService.startMonitoringCall(_currentCallId!);
      }

      // 6. Configurar timeout de conexión
      _setupConnectionTimeout();

      return result;

    } catch (e) {
      ReleaseLogger.error('Error iniciando videollamada: $e', tag: 'VideoCallOrchestrator');
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
      final engineInitialized = await _agoraManager.initialize(isVideo: isVideo);
      if (!engineInitialized) {
        return {'success': false, 'error': 'Error inicializando motor de videollamada'};
      }

      // 4. Unirse al canal
      final joined = await _agoraManager.joinChannel(
        channelId: channelName,
        token: token,
        uid: uid,
      );

      if (!joined) {
        return {'success': false, 'error': 'Error uniéndose al canal de videollamada'};
      }

      // 5. Iniciar monitoreo de estado
      _callStateService.startMonitoringCall(callId);

      return result;

    } catch (e) {
      ReleaseLogger.error('Error aceptando videollamada $callId: $e', tag: 'VideoCallOrchestrator');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Rechazar videollamada entrante
  Future<bool> rejectCall(String callId, {String reason = 'declined'}) async {
    try {
      final success = await _callInitiationService.rejectCall(callId, reason: reason);

      // Notificar a VoIP/CallKit sobre el rechazo
      if (Platform.isIOS) {
        await _voipService.notifyCallEnded(callId);
      } else if (Platform.isAndroid) {
        await _callKitService.endCall(callId);
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('Error rechazando videollamada $callId: $e', tag: 'VideoCallOrchestrator');
      return false;
    }
  }

  /// Terminar videollamada activa
  Future<bool> endCall() async {
    if (_currentCallId == null) {
      return true;
    }

    try {
      final callIdToEnd = _currentCallId!;

      // 1. Terminar llamada en Firestore
      await _callInitiationService.endCall(callIdToEnd);

      // 2. Salir del canal de Agora
      await _agoraManager.leaveChannel();

      // 3. Detener monitoreo
      _callStateService.stopMonitoringCall(callIdToEnd);

      // 4. Notificar a VoIP/CallKit
      if (Platform.isIOS) {
        await _voipService.notifyCallEnded(callIdToEnd);
      } else if (Platform.isAndroid) {
        await _callKitService.endCall(callIdToEnd);
      }

      // 5. Limpiar estado local
      _cleanup();

      // 6. Notificar al controller
      onCallEnded?.call();

      return true;

    } catch (e) {
      ReleaseLogger.error('Error terminando videollamada: $e', tag: 'VideoCallOrchestrator');
      // Forzar cleanup local aunque falle el server
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

  /// Configurar callbacks del Agora Manager
  void _setupAgoraCallbacks() {
    _agoraManager.onLocalUserJoined = (joined) {
      onLocalUserJoined?.call(joined);
    };

    _agoraManager.onRemoteUsersChanged = (remoteUids) {
      onRemoteUsersChanged?.call(remoteUids);
    };

    _agoraManager.onConnectionStatusChanged = (status) {
      onConnectionStatusChanged?.call(status);
    };

    _agoraManager.onError = (error) {
      onError?.call(error);
    };
  }

  /// Configurar timeout de conexión
  void _setupConnectionTimeout() {
    _connectionTimer?.cancel();
    _connectionTimer = Timer(const Duration(seconds: 30), () {
      if (!_agoraManager.isJoined) {
        onError?.call('Timeout de conexión. No se pudo establecer la llamada.');
        endCall();
      }
    });
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