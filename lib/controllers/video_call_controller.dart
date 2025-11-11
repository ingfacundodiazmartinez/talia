import 'dart:async';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../services/video_calls/video_call_orchestrator.dart';
import '../services/video_calls/services/call_state_service.dart';
import '../utils/release_logger.dart';

/// Controller para VideoCallScreen siguiendo CODING_RULES.md
///
/// Responsabilidades:
/// - Coordinar entre UI (VideoCallScreen) y lógica de negocio (VideoCallOrchestrator)
/// - Gestión de estado de UI específico
/// - Callbacks para comunicación bidireccional con la pantalla
/// - ZERO Firebase calls (todas están delegadas al orchestrator)
/// - Separación clara de responsabilidades
class VideoCallController {
  // Dependencies (injected)
  final VideoCallOrchestrator _orchestrator;

  // State
  final String callId;
  final String? channelName;
  final String? token;
  final int? uid;
  final bool isCaller;
  final String remoteName;
  final String receiverId;
  final bool isVideo;

  bool _isInitialized = false;
  bool _disposed = false;

  // Callbacks para comunicación con VideoCallScreen
  VoidCallback? onStateChanged;
  Function(String)? onConnectionStatusChanged;
  Function(Set<int>)? onRemoteUsersChanged;
  Function(bool)? onLocalUserJoined;
  Function(String)? onError;
  VoidCallback? onCallEnded;

  // Constructor
  VideoCallController({
    required this.callId,
    required this.channelName,
    required this.token,
    required this.uid,
    required this.isCaller,
    required this.remoteName,
    required this.receiverId,
    required this.isVideo,
    VideoCallOrchestrator? orchestrator,
  }) : _orchestrator = orchestrator ?? VideoCallOrchestrator();

  // Getters delegados al orchestrator
  bool get isInitialized => _isInitialized;
  bool get isMuted => _orchestrator.isMuted;
  bool get isCameraOff => _orchestrator.isCameraOff;
  bool get isJoined => _orchestrator.isJoined;
  int? get localUid => _orchestrator.localUid;
  Set<int> get remoteUids => _orchestrator.remoteUids;
  String get connectionStatus => _getConnectionStatusText();
  String? get currentCallId => _orchestrator.currentCallId;
  RtcEngine? get agoraEngine => _orchestrator.agoraEngine;

  // Streams del orchestrator
  Stream<CallStateUpdate> get callStateStream => _orchestrator.callStateStream;
  Stream<List<IncomingCall>> get incomingCallsStream => _orchestrator.incomingCallsStream;

  /// Inicializar controller
  ///
  /// [context] es opcional y solo se usa para permisos específicos de Android
  Future<bool> initialize({BuildContext? context}) async {
    if (_disposed) return false;

    try {
      ReleaseLogger.info('Inicializando VideoCallController', tag: 'VideoCallController');

      // Configurar callbacks del orchestrator
      _setupOrchestratorCallbacks();

      // Inicializar orchestrator
      final success = await _orchestrator.initialize();
      if (success) {
        _isInitialized = true;
        onStateChanged?.call();
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('Error inicializando VideoCallController: $e', tag: 'VideoCallController');
      onError?.call('Error de inicialización: $e');
      return false;
    }
  }

  /// Iniciar nueva videollamada
  Future<Map<String, dynamic>> startCall({
    required String receiverId,
    required String receiverName,
    required bool isVideo,
  }) async {
    if (_disposed) return {'success': false, 'error': 'Controller disposed'};

    try {
      ReleaseLogger.info('Iniciando llamada: $receiverId', tag: 'VideoCallController');

      final result = await _orchestrator.startCall(
        receiverId: receiverId,
        receiverName: receiverName,
        isVideo: isVideo,
      );

      if (result['success']) {
        onStateChanged?.call();
      } else {
        onError?.call(result['error'] ?? 'Error desconocido');
      }

      return result;

    } catch (e) {
      ReleaseLogger.error('Error iniciando llamada: $e', tag: 'VideoCallController');
      onError?.call('Error iniciando llamada: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Aceptar llamada entrante
  Future<Map<String, dynamic>> acceptCall(String callId) async {
    if (_disposed) return {'success': false, 'error': 'Controller disposed'};

    try {
      ReleaseLogger.info('Aceptando llamada: $callId', tag: 'VideoCallController');

      final result = await _orchestrator.acceptCall(callId);

      if (result['success']) {
        onStateChanged?.call();
      } else {
        onError?.call(result['error'] ?? 'Error aceptando llamada');
      }

      return result;

    } catch (e) {
      ReleaseLogger.error('Error aceptando llamada: $e', tag: 'VideoCallController');
      onError?.call('Error aceptando llamada: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Rechazar llamada entrante
  Future<bool> rejectCall(String callId, {String reason = 'declined'}) async {
    if (_disposed) return false;

    try {
      return await _orchestrator.rejectCall(callId, reason: reason);
    } catch (e) {
      ReleaseLogger.error('Error rechazando llamada: $e', tag: 'VideoCallController');
      onError?.call('Error rechazando llamada: $e');
      return false;
    }
  }

  /// Terminar llamada actual
  Future<bool> endCall() async {
    if (_disposed) return false;

    try {
      final success = await _orchestrator.endCall();
      if (success) {
        onStateChanged?.call();
      }
      return success;

    } catch (e) {
      ReleaseLogger.error('Error terminando llamada: $e', tag: 'VideoCallController');
      onError?.call('Error terminando llamada: $e');
      return false;
    }
  }

  /// Alternar micrófono
  Future<bool> toggleMute() async {
    if (_disposed) return false;

    try {
      final success = await _orchestrator.toggleMute();
      if (success) {
        onStateChanged?.call();
      }
      return success;

    } catch (e) {
      ReleaseLogger.error('Error alternando mute: $e', tag: 'VideoCallController');
      onError?.call('Error alternando micrófono: $e');
      return false;
    }
  }

  /// Alternar cámara
  Future<bool> toggleCamera() async {
    if (_disposed) return false;

    try {
      final success = await _orchestrator.toggleCamera();
      if (success) {
        onStateChanged?.call();
      }
      return success;

    } catch (e) {
      ReleaseLogger.error('Error alternando cámara: $e', tag: 'VideoCallController');
      onError?.call('Error alternando cámara: $e');
      return false;
    }
  }

  /// Cambiar cámara (frontal/trasera)
  Future<bool> switchCamera() async {
    if (_disposed) return false;

    try {
      return await _orchestrator.switchCamera();
    } catch (e) {
      ReleaseLogger.error('Error cambiando cámara: $e', tag: 'VideoCallController');
      onError?.call('Error cambiando cámara: $e');
      return false;
    }
  }

  /// Invitar participante a llamada grupal
  Future<bool> inviteParticipant({
    required String participantId,
    required String participantName,
  }) async {
    if (_disposed) return false;

    try {
      // TODO: Implementar en VideoCallOrchestrator o delegar a service específico
      ReleaseLogger.info('Invitando participante: $participantId', tag: 'VideoCallController');

      // Por ahora, simular éxito - la implementación real irá en el orchestrator/service
      return true;

    } catch (e) {
      ReleaseLogger.error('Error invitando participante: $e', tag: 'VideoCallController');
      onError?.call('Error invitando participante: $e');
      return false;
    }
  }

  /// Iniciar monitoreo de llamadas entrantes
  void startMonitoringIncomingCalls() {
    if (_disposed) return;
    _orchestrator.startMonitoringIncomingCalls();
  }

  /// Detener monitoreo de llamadas entrantes
  void stopMonitoringIncomingCalls() {
    if (_disposed) return;
    _orchestrator.stopMonitoringIncomingCalls();
  }

  /// Obtener llamadas activas
  Future<List<ActiveCall>> getActiveCalls() async {
    if (_disposed) return [];
    return _orchestrator.getActiveCalls();
  }

  /// Verificar si hay llamadas activas
  Future<bool> hasActiveCalls() async {
    if (_disposed) return false;
    return await _orchestrator.hasActiveCalls();
  }

  /// Configurar callbacks del orchestrator
  void _setupOrchestratorCallbacks() {
    _orchestrator.onConnectionStatusChanged = (status) {
      ReleaseLogger.log('🔄 [Controller] Connection status: $status', tag: 'VideoCallController');
      onConnectionStatusChanged?.call(status);
      onStateChanged?.call();
    };

    _orchestrator.onRemoteUsersChanged = (remoteUids) {
      ReleaseLogger.log('👥 [Controller] Remote users changed: ${remoteUids.length} users - $remoteUids', tag: 'VideoCallController');
      onRemoteUsersChanged?.call(remoteUids);
      onStateChanged?.call();
    };

    _orchestrator.onLocalUserJoined = (joined) {
      ReleaseLogger.log('📱 [Controller] Local user joined: $joined', tag: 'VideoCallController');
      onLocalUserJoined?.call(joined);
      onStateChanged?.call();
    };

    _orchestrator.onError = (error) {
      ReleaseLogger.error('❌ [Controller] Error: $error', tag: 'VideoCallController');
      onError?.call(error);
    };

    _orchestrator.onCallEnded = () {
      ReleaseLogger.log('📞 [Controller] Call ended', tag: 'VideoCallController');
      onCallEnded?.call();
      onStateChanged?.call();
    };
  }

  /// Obtener texto del estado de conexión
  String _getConnectionStatusText() {
    if (!_isInitialized) return 'Inicializando...';
    if (!isJoined) return 'Conectando...';
    if (remoteUids.isEmpty) return 'Esperando...';
    return 'Conectado';
  }

  /// Unirse a una llamada existente usando credenciales ya obtenidas
  ///
  /// Este método se usa cuando las credenciales (channelName, token, uid) ya fueron
  /// creadas por el proceso de inicio de llamada en otra pantalla
  Future<bool> joinExistingCall({
    required String channelName,
    required String token,
    required int uid,
    required bool isVideo,
  }) async {
    if (_disposed) return false;

    try {
      ReleaseLogger.info('Uniéndose a llamada existente: $channelName', tag: 'VideoCallController');

      // Verificar que el orchestrator esté inicializado
      if (!_isInitialized) {
        final initSuccess = await initialize();
        if (!initSuccess) {
          ReleaseLogger.error('Error inicializando orchestrator para unirse a llamada', tag: 'VideoCallController');
          return false;
        }
      }

      // Unirse directamente al canal usando el orchestrator's Agora manager
      final success = await _orchestrator.joinExistingChannel(
        callId: callId,
        channelName: channelName,
        token: token,
        uid: uid,
        isVideo: isVideo,
      );

      if (success) {
        onStateChanged?.call();
      } else {
        onError?.call('Error uniéndose al canal existente');
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('Error uniéndose a llamada existente: $e', tag: 'VideoCallController');
      onError?.call('Error uniéndose a llamada existente: $e');
      return false;
    }
  }

  /// Obtener información de debug
  Map<String, dynamic> getDebugInfo() {
    return {
      'controller': {
        'isInitialized': _isInitialized,
        'callId': callId,
        'disposed': _disposed,
      },
      'orchestrator': _orchestrator.getDebugInfo(),
    };
  }

  /// Dispose del controller
  Future<void> dispose() async {
    if (_disposed) return;

    ReleaseLogger.info('Disposing VideoCallController', tag: 'VideoCallController');

    _disposed = true;

    // Limpiar callbacks
    onStateChanged = null;
    onConnectionStatusChanged = null;
    onRemoteUsersChanged = null;
    onLocalUserJoined = null;
    onError = null;
    onCallEnded = null;

    // Dispose del orchestrator
    await _orchestrator.dispose();

    _isInitialized = false;
  }
}