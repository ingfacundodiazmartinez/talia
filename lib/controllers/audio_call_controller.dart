import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/video_call_service.dart';
import '../services/callkit_service.dart';
import '../utils/release_logger.dart';

/// Controller para AudioCallScreen
///
/// Responsabilidades:
/// - Gestionar inicialización y finalización de llamadas de audio
/// - Manejar eventos de Agora RTC Engine
/// - Gestionar estado de Firestore para llamadas
/// - Controlar permisos de micrófono
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class AudioCallController {
  final String callId;
  final String? channelName;
  final String? token;
  final int? uid;
  final bool isCaller;
  final String remoteName;
  final String? receiverId;

  // Services
  final VideoCallService _callService;
  final CallKitService _callKitService;

  // State
  bool _isMuted = false;
  int? _remoteUid;
  bool _isConnecting = true;
  bool _isEnding = false;
  bool _isSpeakerOn = false;

  // Credenciales de Agora
  String? _channelName;
  String? _token;
  int? _uid;
  String? _realCallId;

  // Subscriptions
  StreamSubscription<DocumentSnapshot>? _callStatusSubscription;

  // Callbacks para actualizar UI
  Function(Map<String, dynamic>)? onStateChanged;
  Function(String)? onError;
  Function()? onCallEnded;

  AudioCallController({
    required this.callId,
    this.channelName,
    this.token,
    this.uid,
    required this.isCaller,
    required this.remoteName,
    this.receiverId,
    VideoCallService? callService,
    CallKitService? callKitService,
  }) : _callService = callService ?? VideoCallService(),
       _callKitService = callKitService ?? CallKitService() {

    // Inicializar credenciales desde parámetros
    _channelName = channelName;
    _token = token;
    _uid = uid;
  }

  // Getters
  bool get isMuted => _isMuted;
  int? get remoteUid => _remoteUid;
  bool get isConnecting => _isConnecting;
  bool get isEnding => _isEnding;
  bool get isSpeakerOn => _isSpeakerOn;
  String? get currentChannelName => _channelName;
  String? get currentToken => _token;
  int? get currentUid => _uid;
  String? get realCallId => _realCallId;

  /// Inicializar llamada de audio
  Future<void> initializeCall() async {
    try {
      ReleaseLogger.log('Iniciando initializeCall()', tag: 'AudioCall');
      ReleaseLogger.log('isCaller: $isCaller', tag: 'AudioCall');
      ReleaseLogger.log('callId: $callId', tag: 'AudioCall');
      ReleaseLogger.log('channelName (widget): $channelName', tag: 'AudioCall');
      ReleaseLogger.log('channelName (local): $_channelName', tag: 'AudioCall');
      ReleaseLogger.log('receiverId: $receiverId', tag: 'AudioCall');

      // Paso 0: Solicitar permisos si somos el CALLER en Android
      if (isCaller && Platform.isAndroid) {
        await _requestMicrophonePermission();
      } else {
        ReleaseLogger.log('Saltando verificación manual de permisos (iOS o receiver)', tag: 'AudioCall');
      }

      // Paso 1: Si es caller y no hay token/uid, obtener credenciales
      if (isCaller && (_token == null || _uid == null)) {
        ReleaseLogger.log('Iniciando llamada de audio en background...', tag: 'AudioCall');

        if (receiverId == null) {
          throw Exception('receiverId es requerido para iniciar una llamada');
        }

        // Iniciar llamada completa para obtener credenciales
        final result = await _callService.initiateCall(
          receiverId: receiverId!,
          receiverName: remoteName,
          isVideo: false,
        );

        if (result['success'] != true) {
          throw Exception(result['error'] ?? 'Error iniciando llamada');
        }

        // Actualizar datos de llamada
        _channelName = result['channelName'];
        _token = result['token'];
        _uid = result['uid'];
        _realCallId = result['channelName'];

        ReleaseLogger.log('Datos de llamada de audio obtenidos: channel=$_channelName, uid=$_uid', tag: 'AudioCall');

        // Ahora que tenemos el callId real, iniciar el listener
        _listenToCallStatus();
      }

      // Paso 2: Verificar que tenemos todas las credenciales
      if (_channelName == null || _token == null || _uid == null) {
        throw Exception('Faltan credenciales para unirse al canal');
      }

      // Paso 3: Inicializar Agora para audio
      await _callService.initializeAgoraAudio();

      // Paso 4: Configurar event handler personalizado
      ReleaseLogger.log('Registrando event handlers...', tag: 'AudioCall');
      _callService.engine?.registerEventHandler(_createAgoraEventHandler());

      // Paso 5: Unirse al canal de audio
      ReleaseLogger.log('Uniéndose al canal de audio: $_channelName', tag: 'AudioCall');
      await _callService.engine?.joinChannel(
        token: _token!,
        channelId: _channelName!,
        uid: _uid!,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          autoSubscribeAudio: true,
        ),
      );

      ReleaseLogger.log('initializeCall() completado exitosamente', tag: 'AudioCall');
    } catch (e) {
      ReleaseLogger.error('Error en initializeCall(): $e', tag: 'AudioCall');
      onError?.call('Error iniciando llamada: $e');
    }
  }

  /// Crear event handler de Agora
  RtcEngineEventHandler _createAgoraEventHandler() {
    return RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
        ReleaseLogger.log('Unido al canal de audio: ${connection.channelId}', tag: 'AudioCall');
        ReleaseLogger.log('Local UID: ${connection.localUid}', tag: 'AudioCall');
        ReleaseLogger.log('Elapsed: ${elapsed}ms', tag: 'AudioCall');

        // Configurar auricular por defecto
        _callService.engine?.setEnableSpeakerphone(false).then((_) {
          ReleaseLogger.log('Auricular activado (modo normal de llamada)', tag: 'AudioCall');
        }).catchError((e) {
          ReleaseLogger.warning('Error configurando auricular: $e', tag: 'AudioCall');
        });

        _isConnecting = false;
        _notifyStateChanged();

        // Workaround: verificar estado después de 2 segundos
        Future.delayed(Duration(seconds: 2), () {
          if (_remoteUid == null) {
            ReleaseLogger.warning('Después de 2s, aún no hay usuario remoto detectado', tag: 'AudioCall');
            ReleaseLogger.log('Estado: isConnecting=$_isConnecting, remoteUid=$_remoteUid', tag: 'AudioCall');
          }
        });
      },
      onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
        ReleaseLogger.log('Usuario remoto unido al canal: $remoteUid', tag: 'AudioCall');
        ReleaseLogger.log('Connection: ${connection.channelId}', tag: 'AudioCall');
        ReleaseLogger.log('Elapsed: ${elapsed}ms', tag: 'AudioCall');

        _remoteUid = remoteUid;
        _isConnecting = false;
        _notifyStateChanged();

        ReleaseLogger.log('Estado actualizado: remoteUid=$_remoteUid, isConnecting=$_isConnecting', tag: 'AudioCall');
      },
      onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
        ReleaseLogger.log('Usuario remoto desconectado: $remoteUid (razón: $reason)', tag: 'AudioCall');
        _remoteUid = null;
        _notifyStateChanged();
        endCall();
      },
      onError: (ErrorCodeType err, String msg) {
        ReleaseLogger.error('Error de Agora: $err - $msg', tag: 'AudioCall');
        onError?.call('Error en la llamada: $msg');
      },
      onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {
        ReleaseLogger.log('Estado de conexión cambió:', tag: 'AudioCall');
        ReleaseLogger.log('Nuevo estado: $state', tag: 'AudioCall');
        ReleaseLogger.log('Razón: $reason', tag: 'AudioCall');
        ReleaseLogger.log('Channel: ${connection.channelId}', tag: 'AudioCall');
      },
    );
  }

  /// Solicitar permisos de micrófono
  Future<void> _requestMicrophonePermission() async {
    try {
      ReleaseLogger.log('Solicitando permisos de micrófono...', tag: 'AudioCall');
      final microphoneStatus = await Permission.microphone.status;
      ReleaseLogger.log('Estado actual del micrófono: $microphoneStatus', tag: 'AudioCall');

      if (microphoneStatus.isDenied || microphoneStatus.isPermanentlyDenied) {
        ReleaseLogger.log('Permisos denegados, solicitando...', tag: 'AudioCall');
        final result = await Permission.microphone.request();
        ReleaseLogger.log('Resultado de solicitud: $result', tag: 'AudioCall');

        if (!result.isGranted) {
          throw Exception('Permisos de micrófono denegados');
        }
      }

      ReleaseLogger.log('Permisos de micrófono verificados exitosamente', tag: 'AudioCall');
    } catch (e) {
      ReleaseLogger.error('Error verificando permisos: $e', tag: 'AudioCall');
      rethrow;
    }
  }

  /// Escuchar estado de llamada en Firestore
  void _listenToCallStatus() {
    try {
      final callIdToListen = _realCallId ?? callId;
      ReleaseLogger.log('Iniciando listener para callId: $callIdToListen', tag: 'AudioCall');

      _callStatusSubscription = FirebaseFirestore.instance
          .collection('calls')
          .doc(callIdToListen)
          .snapshots()
          .listen(
        (snapshot) {
          try {
            if (!snapshot.exists) {
              ReleaseLogger.warning('Documento de llamada no existe: $callIdToListen', tag: 'AudioCall');
              return;
            }

            final callData = snapshot.data() as Map<String, dynamic>;
            final status = callData['status'] as String?;
            ReleaseLogger.log('Estado de llamada actualizado: $status', tag: 'AudioCall');

            switch (status) {
              case 'ended':
              case 'declined':
              case 'cancelled':
                ReleaseLogger.log('Llamada terminada por el estado: $status', tag: 'AudioCall');
                if (!_isEnding) {
                  endCall();
                }
                break;
              case 'missed':
                ReleaseLogger.log('Llamada perdida detectada', tag: 'AudioCall');
                if (!_isEnding) {
                  endCall();
                }
                break;
              default:
                ReleaseLogger.log('Estado de llamada: $status', tag: 'AudioCall');
            }
          } catch (e) {
            ReleaseLogger.error('Error procesando snapshot de llamada: $e', tag: 'AudioCall');
          }
        },
        onError: (error) {
          ReleaseLogger.error('Error en listener de estado de llamada: $error', tag: 'AudioCall');
        },
      );
    } catch (e) {
      ReleaseLogger.error('Error configurando listener de estado: $e', tag: 'AudioCall');
    }
  }

  /// Alternar mute del micrófono
  Future<void> toggleMute() async {
    try {
      _isMuted = !_isMuted;
      await _callService.engine?.muteLocalAudioStream(_isMuted);
      ReleaseLogger.log('Micrófono ${_isMuted ? 'silenciado' : 'activado'}', tag: 'AudioCall');
      _notifyStateChanged();
    } catch (e) {
      ReleaseLogger.error('Error alternando mute: $e', tag: 'AudioCall');
    }
  }

  /// Alternar altavoz
  Future<void> toggleSpeaker() async {
    try {
      _isSpeakerOn = !_isSpeakerOn;
      await _callService.engine?.setEnableSpeakerphone(_isSpeakerOn);
      ReleaseLogger.log('Altavoz ${_isSpeakerOn ? 'activado' : 'desactivado'}', tag: 'AudioCall');
      _notifyStateChanged();
    } catch (e) {
      ReleaseLogger.error('Error alternando altavoz: $e', tag: 'AudioCall');
    }
  }

  /// Finalizar llamada
  Future<void> endCall() async {
    if (_isEnding) return;

    try {
      _isEnding = true;
      _notifyStateChanged();

      ReleaseLogger.log('Iniciando finalización de llamada...', tag: 'AudioCall');

      // 1. Cancelar subscription
      await _callStatusSubscription?.cancel();
      _callStatusSubscription = null;

      // 2. Salir del canal de Agora
      await _callService.engine?.leaveChannel();
      ReleaseLogger.log('Salido del canal de Agora', tag: 'AudioCall');

      // 3. Actualizar estado en Firestore
      final callIdToUpdate = _realCallId ?? callId;
      await _callService.endCall(callIdToUpdate);
      ReleaseLogger.log('Estado de llamada actualizado en Firestore', tag: 'AudioCall');

      // 4. Limpiar CallKit si está disponible
      if (Platform.isIOS) {
        try {
          await _callKitService.endCall(callIdToUpdate);
          ReleaseLogger.log('Llamada terminada en CallKit', tag: 'AudioCall');
        } catch (e) {
          ReleaseLogger.warning('Error terminando CallKit: $e', tag: 'AudioCall');
        }
      }

      ReleaseLogger.log('Llamada finalizada completamente', tag: 'AudioCall');
      onCallEnded?.call();
    } catch (e) {
      ReleaseLogger.error('Error finalizando llamada: $e', tag: 'AudioCall');
    }
  }

  /// Notificar cambios de estado a la UI
  void _notifyStateChanged() {
    onStateChanged?.call({
      'isMuted': _isMuted,
      'remoteUid': _remoteUid,
      'isConnecting': _isConnecting,
      'isEnding': _isEnding,
      'isSpeakerOn': _isSpeakerOn,
    });
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing AudioCallController', tag: 'AudioCall');
    _callStatusSubscription?.cancel();
  }
}