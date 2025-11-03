import 'dart:async';
import 'dart:io';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:permission_handler/permission_handler.dart';
import '../services/video_call_service.dart';
import '../services/voip_service.dart';
import '../services/callkit_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de videollamadas
///
/// Responsabilidades:
/// - Gestión de Agora RTC Engine
/// - Manejo de permisos de cámara y micrófono
/// - Coordinación con servicios de llamada (VideoCallService, VoIPService, CallKitService)
/// - Estado de la llamada y conexión
/// - Gestión de usuarios remotos
class VideoCallController {
  final String callId;
  final String? channelName;
  final String? token;
  final int? uid;
  final bool isCaller;
  final String remoteName;
  final String receiverId;
  final bool isVideo;

  // Servicios privados
  final VideoCallService _videoCallService;
  final VoIPService _voipService;
  final CallKitService _callKitService;
  final firebase_auth.FirebaseAuth _auth;

  // Estado de la llamada
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isJoined = false;
  int? _localUid;
  Set<int> _remoteUids = {};
  String _connectionStatus = 'Conectando...';
  bool _isEnding = false;
  bool _hasPermissions = false;

  // Agora Engine
  RtcEngine? _engine;

  // Timers y listeners
  Timer? _connectionTimer;
  StreamSubscription? _callStateSubscription;

  // Callbacks para comunicación con el screen
  Function(String)? onConnectionStatusChanged;
  Function(Set<int>)? onRemoteUsersChanged;
  Function(bool)? onLocalUserJoined;
  Function(String)? onError;
  Function()? onCallEnded;
  Function()? onPermissionDenied;

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
    VideoCallService? videoCallService,
    VoIPService? voipService,
    CallKitService? callKitService,
    firebase_auth.FirebaseAuth? auth,
  }) : _videoCallService = videoCallService ?? VideoCallService(),
       _voipService = voipService ?? VoIPService(),
       _callKitService = callKitService ?? CallKitService(),
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para el estado
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isJoined => _isJoined;
  int? get localUid => _localUid;
  Set<int> get remoteUids => _remoteUids;
  String get connectionStatus => _connectionStatus;
  bool get isEnding => _isEnding;
  bool get hasPermissions => _hasPermissions;
  RtcEngine? get engine => _engine;

  /// Inicializar el controller
  Future<void> initialize() async {
    print('🏗️ [VideoCallController] Inicializando para callId: $callId');

    try {
      // Verificar y solicitar permisos
      await _checkPermissions();

      if (!_hasPermissions) {
        onPermissionDenied?.call();
        return;
      }

      // Inicializar Agora Engine
      await _initializeAgoraEngine();

      // Configurar listeners del estado de llamada
      _setupCallStateListener();

      // Unirse al canal
      await _joinChannel();

    } catch (e) {
      print('❌ [VideoCallController] Error inicializando: $e');
      onError?.call('Error inicializando llamada: $e');
    }
  }

  /// Verificar y solicitar permisos necesarios
  Future<void> _checkPermissions() async {
    final permissions = [Permission.camera, Permission.microphone];

    Map<Permission, PermissionStatus> statuses = await permissions.request();

    bool allGranted = statuses.values.every((status) => status.isGranted);

    if (!allGranted) {
      // Si falta algún permiso, verificar específicamente cuál
      if (isVideo && !statuses[Permission.camera]!.isGranted) {
        print('❌ [VideoCallController] Permiso de cámara denegado');
        onError?.call('Permiso de cámara requerido para videollamadas');
        return;
      }

      if (!statuses[Permission.microphone]!.isGranted) {
        print('❌ [VideoCallController] Permiso de micrófono denegado');
        onError?.call('Permiso de micrófono requerido para llamadas');
        return;
      }
    }

    _hasPermissions = true;
    print('✅ [VideoCallController] Permisos concedidos');
  }

  /// Inicializar Agora RTC Engine
  Future<void> _initializeAgoraEngine() async {
    const appId = '8ba8bc08b3ab48708b96f7bdbf6d6423';

    // Crear engine
    _engine = createAgoraRtcEngine();

    await _engine!.initialize(const RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    // Configurar callbacks
    _engine!.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          print('✅ [VideoCallController] Usuario local se unió al canal: ${connection.localUid}');
          _localUid = connection.localUid;
          _isJoined = true;
          _updateConnectionStatus('Conectado');
          onLocalUserJoined?.call(true);
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          print('✅ [VideoCallController] Usuario remoto se unió: $remoteUid');
          _remoteUids.add(remoteUid);
          onRemoteUsersChanged?.call(_remoteUids);
          _updateConnectionStatus('En llamada');
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          print('👋 [VideoCallController] Usuario remoto se desconectó: $remoteUid (razón: $reason)');
          _remoteUids.remove(remoteUid);
          onRemoteUsersChanged?.call(_remoteUids);

          // Si no quedan usuarios remotos, la llamada ha terminado
          if (_remoteUids.isEmpty) {
            _updateConnectionStatus('Llamada terminada');
            _endCall();
          }
        },
        onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {
          print('🔄 [VideoCallController] Estado de conexión: $state (razón: $reason)');

          switch (state) {
            case ConnectionStateType.connectionStateDisconnected:
              _updateConnectionStatus('Desconectado');
              break;
            case ConnectionStateType.connectionStateConnecting:
              _updateConnectionStatus('Conectando...');
              break;
            case ConnectionStateType.connectionStateConnected:
              _updateConnectionStatus('Conectado');
              break;
            case ConnectionStateType.connectionStateFailed:
              _updateConnectionStatus('Error de conexión');
              onError?.call('Error de conexión. Verifica tu conexión a internet.');
              break;
            default:
              break;
          }
        },
        onError: (ErrorCodeType err, String msg) {
          print('❌ [VideoCallController] Error de Agora: $err - $msg');
          onError?.call('Error en la llamada: $msg');
        },
      ),
    );

    // Habilitar video si es videollamada
    if (isVideo) {
      await _engine!.enableVideo();
    } else {
      await _engine!.disableVideo();
    }

    await _engine!.enableAudio();
  }

  /// Configurar listener del estado de llamada en Firestore
  void _setupCallStateListener() {
    _callStateSubscription = FirebaseFirestore.instance
        .collection('video_calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>;
        final status = data['status'] as String?;

        print('📞 [VideoCallController] Estado de llamada: $status');

        switch (status) {
          case 'ended':
          case 'cancelled':
            if (!_isEnding) {
              _endCall();
            }
            break;
          case 'accepted':
            _updateConnectionStatus('Conectado');
            break;
          default:
            break;
        }
      }
    });
  }

  /// Unirse al canal de Agora
  Future<void> _joinChannel() async {
    if (_engine == null) {
      throw Exception('Agora Engine no inicializado');
    }

    final options = ChannelMediaOptions(
      clientRoleType: ClientRoleType.clientRoleBroadcaster,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    );

    try {
      await _engine!.joinChannel(
        token: token ?? '',
        channelId: channelName ?? callId,
        uid: uid ?? 0,
        options: options,
      );

      _updateConnectionStatus('Conectando...');

      // Timer de timeout para conexión
      _connectionTimer = Timer(const Duration(seconds: 30), () {
        if (!_isJoined) {
          print('⏰ [VideoCallController] Timeout de conexión');
          onError?.call('Timeout de conexión. No se pudo establecer la llamada.');
          _endCall();
        }
      });

    } catch (e) {
      print('❌ [VideoCallController] Error uniéndose al canal: $e');
      onError?.call('Error uniéndose a la llamada: $e');
    }
  }

  /// Alternar estado del micrófono
  Future<void> toggleMute() async {
    if (_engine == null) return;

    _isMuted = !_isMuted;
    await _engine!.muteLocalAudioStream(_isMuted);
    print('🎤 [VideoCallController] Micrófono ${_isMuted ? 'silenciado' : 'activado'}');
  }

  /// Alternar estado de la cámara
  Future<void> toggleCamera() async {
    if (_engine == null || !isVideo) return;

    _isCameraOff = !_isCameraOff;
    await _engine!.muteLocalVideoStream(_isCameraOff);
    print('📹 [VideoCallController] Cámara ${_isCameraOff ? 'desactivada' : 'activada'}');
  }

  /// Cambiar cámara (frontal/trasera)
  Future<void> switchCamera() async {
    if (_engine == null || !isVideo) return;

    await _engine!.switchCamera();
    print('🔄 [VideoCallController] Cámara cambiada');
  }

  /// Terminar llamada
  Future<void> endCall() async {
    if (_isEnding) return;
    _isEnding = true;

    print('📞 [VideoCallController] Terminando llamada...');

    try {
      // Actualizar estado en Firestore
      await _videoCallService.endCall(callId);

      // Limpiar recursos locales
      await _cleanup();

      // Notificar al screen
      onCallEnded?.call();

    } catch (e) {
      print('❌ [VideoCallController] Error terminando llamada: $e');
      // Forzar cleanup aunque haya error
      await _cleanup();
      onCallEnded?.call();
    }
  }

  /// Método privado para terminar llamada (llamado por listeners)
  Future<void> _endCall() async {
    if (_isEnding) return;
    await endCall();
  }

  /// Actualizar estado de conexión
  void _updateConnectionStatus(String status) {
    _connectionStatus = status;
    onConnectionStatusChanged?.call(status);
  }

  /// Limpiar recursos
  Future<void> _cleanup() async {
    print('🧹 [VideoCallController] Limpiando recursos...');

    // Cancelar timers y subscriptions
    _connectionTimer?.cancel();
    _callStateSubscription?.cancel();

    // Salir del canal y destruir engine
    if (_engine != null) {
      await _engine!.leaveChannel();
      await _engine!.release();
      _engine = null;
    }

    // Limpiar estado de CallKit/VoIP si es necesario
    if (Platform.isIOS) {
      await _voipService.endCall(callId);
    } else if (Platform.isAndroid) {
      await _callKitService.endCall(callId);
    }
  }

  /// Obtener información del usuario actual
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Verificar si el usuario actual es el caller
  bool get isCurrentUserCaller => isCaller;

  /// Obtener información de la llamada
  Map<String, dynamic> getCallInfo() {
    return {
      'callId': callId,
      'channelName': channelName,
      'isCaller': isCaller,
      'remoteName': remoteName,
      'receiverId': receiverId,
      'isVideo': isVideo,
      'status': _connectionStatus,
      'isJoined': _isJoined,
      'remoteUsers': _remoteUids.length,
    };
  }

  /// Iniciar llamada desde el controller (si se llamó desde background)
  Future<void> initiateCall() async {
    if (isCaller) {
      try {
        await _videoCallService.startCall(
          receiverId: receiverId,
          isVideo: isVideo,
        );
      } catch (e) {
        print('❌ [VideoCallController] Error iniciando llamada: $e');
        onError?.call('Error iniciando llamada: $e');
      }
    }
  }

  /// Aceptar llamada entrante
  Future<void> acceptCall() async {
    if (!isCaller) {
      try {
        await _videoCallService.acceptCall(callId);
      } catch (e) {
        print('❌ [VideoCallController] Error aceptando llamada: $e');
        onError?.call('Error aceptando llamada: $e');
      }
    }
  }

  /// Dispose del controller
  void dispose() {
    print('🧹 [VideoCallController] Disposing controller');
    _cleanup();
  }
}