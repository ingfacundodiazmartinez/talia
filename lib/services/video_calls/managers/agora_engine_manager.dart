import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../../../utils/release_logger.dart';
import '../../../services/app_config_service.dart';

/// Manager especializado en gestión del Agora RTC Engine
///
/// Responsabilidades:
/// - Inicialización y configuración del engine de Agora
/// - Gestión de eventos de conexión y usuarios remotos
/// - Control de audio/video (mute, camera, switch)
/// - Limpieza de recursos de Agora
class AgoraEngineManager {
  RtcEngine? _engine;
  bool _isInitialized = false;
  final AppConfigService _appConfig = AppConfigService();

  // Estado del engine
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isJoined = false;
  int? _localUid;
  final Set<int> _remoteUids = {};

  // Callbacks públicos
  Function(bool joined)? onLocalUserJoined;
  Function(Set<int> remoteUids)? onRemoteUsersChanged;
  Function(String status)? onConnectionStatusChanged;
  Function(String error)? onError;

  // Getters
  RtcEngine? get engine => _engine;
  bool get isInitialized => _isInitialized;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isJoined => _isJoined;
  int? get localUid => _localUid;
  Set<int> get remoteUids => Set.from(_remoteUids);

  /// Inicializar Agora Engine
  Future<bool> initialize({required bool isVideo}) async {
    if (_isInitialized) {
      return true;
    }

    try {
      await _appConfig.initialize();
      final appId = _appConfig.agoraAppId;

      _engine = createAgoraRtcEngine();

      await _engine!.initialize(RtcEngineContext(
        appId: appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      // Configurar callbacks
      _setupEventHandlers();

      // Configurar audio/video según tipo de llamada
      if (isVideo) {
        await _engine!.enableVideo();
      } else {
        await _engine!.disableVideo();
      }

      await _engine!.enableAudio();

      _isInitialized = true;
      return true;

    } catch (e) {
      ReleaseLogger.error('Error inicializando Agora Engine: $e', tag: 'AgoraManager');
      onError?.call('Error inicializando motor de videollamada: $e');
      return false;
    }
  }

  /// Unirse a un canal de Agora
  Future<bool> joinChannel({
    required String channelId,
    required String token,
    required int uid,
  }) async {
    if (!_isInitialized || _engine == null) {
      ReleaseLogger.error('Agora Engine no inicializado', tag: 'AgoraManager');
      return false;
    }

    try {
      final options = ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      );

      if (token.isEmpty) {
        throw Exception('Token vacío detectado en AgoraEngineManager');
      }

      await _engine!.joinChannel(
        token: token,
        channelId: channelId,
        uid: uid,
        options: options,
      );

      onConnectionStatusChanged?.call('Conectando...');
      return true;

    } catch (e) {
      ReleaseLogger.error('Error uniéndose al canal $channelId: $e', tag: 'AgoraManager');
      onError?.call('Error uniéndose a la llamada: $e');
      return false;
    }
  }

  /// Configurar event handlers de Agora
  void _setupEventHandlers() {
    if (_engine == null) return;

    _engine!.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          _localUid = connection.localUid;
          _isJoined = true;
          onConnectionStatusChanged?.call('Conectado');
          onLocalUserJoined?.call(true);
        },

        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          _remoteUids.add(remoteUid);
          onRemoteUsersChanged?.call(Set.from(_remoteUids));
          onConnectionStatusChanged?.call('En llamada');
        },

        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          _remoteUids.remove(remoteUid);
          onRemoteUsersChanged?.call(Set.from(_remoteUids));

          // Si no quedan usuarios remotos, notificar
          if (_remoteUids.isEmpty) {
            onConnectionStatusChanged?.call('Usuario desconectado');
          }
        },

        onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {
          switch (state) {
            case ConnectionStateType.connectionStateDisconnected:
              onConnectionStatusChanged?.call('Desconectado');
              break;
            case ConnectionStateType.connectionStateConnecting:
              onConnectionStatusChanged?.call('Conectando...');
              break;
            case ConnectionStateType.connectionStateConnected:
              onConnectionStatusChanged?.call('Conectado');
              break;
            case ConnectionStateType.connectionStateFailed:
              _handleConnectionFailure(reason, connection);
              break;
            default:
              break;
          }
        },

        onError: (ErrorCodeType err, String msg) {
          ReleaseLogger.error('Error de Agora Engine: $err - $msg', tag: 'AgoraManager');
          onError?.call('Error en la llamada: $msg');
        },
      ),
    );
  }

  /// Manejar fallas de conexión específicas
  void _handleConnectionFailure(ConnectionChangedReasonType reason, RtcConnection connection) {
    ReleaseLogger.error('Conexión falló - Razón: $reason', tag: 'AgoraManager');
    ReleaseLogger.error('Canal: ${connection.channelId}, UID: ${connection.localUid}', tag: 'AgoraManager');

    String errorMessage = 'Error de conexión';
    switch (reason) {
      case ConnectionChangedReasonType.connectionChangedInvalidAppId:
        errorMessage = 'App ID inválido. Verifica la configuración.';
        break;
      case ConnectionChangedReasonType.connectionChangedInvalidChannelName:
        errorMessage = 'Nombre de canal inválido.';
        break;
      case ConnectionChangedReasonType.connectionChangedInvalidToken:
      case ConnectionChangedReasonType.connectionChangedTokenExpired:
        errorMessage = 'Token de acceso inválido o expirado.';
        break;
      case ConnectionChangedReasonType.connectionChangedRejectedByServer:
        errorMessage = 'Conexión rechazada por el servidor.';
        break;
      case ConnectionChangedReasonType.connectionChangedKeepAliveTimeout:
        errorMessage = 'Timeout de conexión. Verifica tu internet.';
        break;
      default:
        errorMessage = 'Error de conexión. Verifica tu internet.';
        break;
    }

    onConnectionStatusChanged?.call('Error de conexión');
    onError?.call(errorMessage);
  }

  /// Alternar estado del micrófono
  Future<bool> toggleMute() async {
    if (_engine == null) return false;

    try {
      _isMuted = !_isMuted;
      await _engine!.muteLocalAudioStream(_isMuted);
      return true;
    } catch (e) {
      ReleaseLogger.error('Error alternando mute: $e', tag: 'AgoraManager');
      return false;
    }
  }

  /// Alternar estado de la cámara
  Future<bool> toggleCamera() async {
    if (_engine == null) return false;

    try {
      _isCameraOff = !_isCameraOff;
      await _engine!.muteLocalVideoStream(_isCameraOff);
      return true;
    } catch (e) {
      ReleaseLogger.error('Error alternando cámara: $e', tag: 'AgoraManager');
      return false;
    }
  }

  /// Cambiar cámara (frontal/trasera)
  Future<bool> switchCamera() async {
    if (_engine == null) return false;

    try {
      await _engine!.switchCamera();
      return true;
    } catch (e) {
      ReleaseLogger.error('Error cambiando cámara: $e', tag: 'AgoraManager');
      return false;
    }
  }

  /// Configurar calidad de video
  Future<bool> setVideoConfiguration({
    int width = 640,
    int height = 480,
    int frameRate = 15,
    int bitrate = 400,
  }) async {
    if (_engine == null) return false;

    try {
      await _engine!.setVideoEncoderConfiguration(
        VideoEncoderConfiguration(
          dimensions: VideoDimensions(width: width, height: height),
          frameRate: frameRate,
          bitrate: bitrate,
          orientationMode: OrientationMode.orientationModeAdaptive,
        ),
      );
      return true;
    } catch (e) {
      ReleaseLogger.error('Error configurando calidad de video: $e', tag: 'AgoraManager');
      return false;
    }
  }

  /// Configurar modo de audio para llamadas
  Future<bool> setAudioProfile() async {
    if (_engine == null) return false;

    try {
      await _engine!.setAudioProfile(
        profile: AudioProfileType.audioProfileDefault,
        scenario: AudioScenarioType.audioScenarioGameStreaming,
      );
      return true;
    } catch (e) {
      ReleaseLogger.error('Error configurando perfil de audio: $e', tag: 'AgoraManager');
      return false;
    }
  }

  /// Salir del canal
  Future<bool> leaveChannel() async {
    if (_engine == null) return true;

    try {
      await _engine!.leaveChannel();

      // Reset estado
      _isJoined = false;
      _localUid = null;
      _remoteUids.clear();
      _isMuted = false;
      _isCameraOff = false;

      return true;
    } catch (e) {
      ReleaseLogger.error('Error saliendo del canal: $e', tag: 'AgoraManager');
      return false;
    }
  }

  /// Destruir engine y limpiar recursos
  Future<void> dispose() async {
    if (_engine != null) {
      try {
        await _engine!.leaveChannel();
        await _engine!.release();
      } catch (e) {
        ReleaseLogger.error('Error destruyendo Agora Engine: $e', tag: 'AgoraManager');
      }

      _engine = null;
      _isInitialized = false;
    }

    // Reset estado
    _isJoined = false;
    _localUid = null;
    _remoteUids.clear();
    _isMuted = false;
    _isCameraOff = false;

    // Clear callbacks
    onLocalUserJoined = null;
    onRemoteUsersChanged = null;
    onConnectionStatusChanged = null;
    onError = null;
  }

  /// Obtener información de debug del engine
  Map<String, dynamic> getDebugInfo() {
    return {
      'isInitialized': _isInitialized,
      'isJoined': _isJoined,
      'localUid': _localUid,
      'remoteUids': _remoteUids.toList(),
      'isMuted': _isMuted,
      'isCameraOff': _isCameraOff,
      'engineExists': _engine != null,
    };
  }
}