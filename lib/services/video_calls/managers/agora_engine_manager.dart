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
      ReleaseLogger.log('✅ Agora Engine ya inicializado', tag: 'AgoraManager');
      return true;
    }

    try {
      ReleaseLogger.log('🚀 Inicializando Agora Engine...', tag: 'AgoraManager');

      await _appConfig.initialize();
      final appId = _appConfig.agoraAppId;
      ReleaseLogger.log('📋 App ID obtenido: ${appId.substring(0, 8)}...', tag: 'AgoraManager');

      if (appId.isEmpty) {
        throw Exception('Agora App ID vacío - verifica configuración');
      }

      ReleaseLogger.log('🔧 Creando Agora RTC Engine...', tag: 'AgoraManager');
      _engine = createAgoraRtcEngine();

      ReleaseLogger.log('⚙️ Inicializando engine con App ID...', tag: 'AgoraManager');
      await _engine!.initialize(RtcEngineContext(
        appId: appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      // Configurar callbacks
      ReleaseLogger.log('📡 Configurando event handlers...', tag: 'AgoraManager');
      _setupEventHandlers();

      // Configurar audio/video según tipo de llamada
      if (isVideo) {
        ReleaseLogger.log('📹 Habilitando video...', tag: 'AgoraManager');
        await _engine!.enableVideo();

        ReleaseLogger.log('📷 Iniciando vista previa de video...', tag: 'AgoraManager');
        await _engine!.startPreview();
      } else {
        ReleaseLogger.log('🔇 Deshabilitando video (llamada de audio)...', tag: 'AgoraManager');
        await _engine!.disableVideo();
      }

      ReleaseLogger.log('🎤 Habilitando audio...', tag: 'AgoraManager');
      await _engine!.enableAudio();

      _isInitialized = true;
      ReleaseLogger.log('✅ Agora Engine inicializado exitosamente', tag: 'AgoraManager');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ Error inicializando Agora Engine: $e', tag: 'AgoraManager');
      ReleaseLogger.error('❌ Stack trace: ${StackTrace.current}', tag: 'AgoraManager');
      onError?.call('Error inicializando motor de videollamada: $e');
      return false;
    }
  }

  /// Unirse a un canal de Agora
  Future<bool> joinChannel({
    required String channelId,
    required String token,
    required int uid,
    bool? isVideo, // Añadir parámetro para configurar audio/video
  }) async {
    if (!_isInitialized || _engine == null) {
      ReleaseLogger.error('❌ Agora Engine no inicializado', tag: 'AgoraManager');
      return false;
    }

    // ✅ CRÍTICO: Evitar double join - verificar si ya está conectado a este canal
    if (_isJoined) {
      ReleaseLogger.log('⚠️ [AgoraManager] Ya conectado al canal, saltando joinChannel', tag: 'AgoraManager');
      return true;
    }

    try {
      ReleaseLogger.log('🔗 Iniciando conexión a canal Agora...', tag: 'AgoraManager');
      ReleaseLogger.log('📋 Parámetros: channelId=$channelId, uid=$uid, token=${token.substring(0, 20)}...', tag: 'AgoraManager');

      // ✅ CRÍTICO: Configurar media options según tipo de llamada
      final options = ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        // Audio configurations (always needed)
        publishMicrophoneTrack: true,
        autoSubscribeAudio: true,
        // Video configurations (only for video calls)
        publishCameraTrack: isVideo ?? false,
        autoSubscribeVideo: isVideo ?? false,
      );

      if (token.isEmpty) {
        throw Exception('Token vacío detectado en AgoraEngineManager');
      }

      if (channelId.isEmpty) {
        throw Exception('Channel ID vacío detectado en AgoraEngineManager');
      }

      ReleaseLogger.log('🚀 Llamando a engine.joinChannel()...', tag: 'AgoraManager');
      ReleaseLogger.log('🔑 CANAL DE CONEXIÓN: "$channelId" (${channelId.length} chars)', tag: 'AgoraManager');
      await _engine!.joinChannel(
        token: token,
        channelId: channelId,
        uid: uid,
        options: options,
      );

      ReleaseLogger.log('✅ engine.joinChannel() completado - esperando onJoinChannelSuccess...', tag: 'AgoraManager');
      onConnectionStatusChanged?.call('Conectando...');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ Error uniéndose al canal $channelId: $e', tag: 'AgoraManager');
      ReleaseLogger.error('❌ Stack trace: ${StackTrace.current}', tag: 'AgoraManager');
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
          ReleaseLogger.log('🎉 onJoinChannelSuccess: localUid=${connection.localUid}, elapsed=${elapsed}ms', tag: 'AgoraManager');
          _localUid = connection.localUid;
          _isJoined = true;
          onConnectionStatusChanged?.call('Conectado');
          onLocalUserJoined?.call(true);
        },

        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          ReleaseLogger.log('👥 onUserJoined: remoteUid=$remoteUid, elapsed=${elapsed}ms, canal=${connection.channelId}', tag: 'AgoraManager');
          _remoteUids.add(remoteUid);
          ReleaseLogger.log('👥 Total usuarios remotos: ${_remoteUids.length} - UIDs: $_remoteUids', tag: 'AgoraManager');
          onRemoteUsersChanged?.call(Set.from(_remoteUids));
          onConnectionStatusChanged?.call('En llamada');
        },

        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          ReleaseLogger.log('👋 onUserOffline: remoteUid=$remoteUid, reason=$reason', tag: 'AgoraManager');
          _remoteUids.remove(remoteUid);
          onRemoteUsersChanged?.call(Set.from(_remoteUids));

          // Si no quedan usuarios remotos, notificar
          if (_remoteUids.isEmpty) {
            onConnectionStatusChanged?.call('Usuario desconectado');
          }
        },

        onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {
          ReleaseLogger.log('🔄 onConnectionStateChanged: state=$state, reason=$reason', tag: 'AgoraManager');
          switch (state) {
            case ConnectionStateType.connectionStateDisconnected:
              ReleaseLogger.log('❌ Conexión DESCONECTADA (reason: $reason)', tag: 'AgoraManager');
              onConnectionStatusChanged?.call('Desconectado');
              break;
            case ConnectionStateType.connectionStateConnecting:
              ReleaseLogger.log('🔗 Conexión CONECTANDO (reason: $reason)', tag: 'AgoraManager');
              onConnectionStatusChanged?.call('Conectando...');
              break;
            case ConnectionStateType.connectionStateConnected:
              ReleaseLogger.log('✅ Conexión CONECTADA (reason: $reason)', tag: 'AgoraManager');
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
          ReleaseLogger.error('❌ onError - ErrorCode: $err, Message: $msg', tag: 'AgoraManager');
          ReleaseLogger.error('❌ Error detail: error=$err, message=$msg', tag: 'AgoraManager');
          onError?.call('Error en la llamada: $msg (Code: $err)');
        },

        // Agregar más handlers para debugging
        onLeaveChannel: (RtcConnection connection, RtcStats stats) {
          ReleaseLogger.log('🚪 onLeaveChannel: duration=${stats.duration}s', tag: 'AgoraManager');
          _isJoined = false;
          _localUid = null;
          _remoteUids.clear();
        },

        onTokenPrivilegeWillExpire: (RtcConnection connection, String token) {
          ReleaseLogger.error('⚠️ onTokenPrivilegeWillExpire: token expirando pronto', tag: 'AgoraManager');
        },

        onRequestToken: (RtcConnection connection) {
          ReleaseLogger.error('🔑 onRequestToken: se requiere nuevo token', tag: 'AgoraManager');
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