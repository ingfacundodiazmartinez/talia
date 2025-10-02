import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';

class VideoCallService {
  static final VideoCallService _instance = VideoCallService._internal();
  factory VideoCallService() => _instance;
  VideoCallService._internal();

  // TODO: Reemplazar con tu APP_ID de Agora Console (https://console.agora.io/)
  static const String APP_ID = 'f4537746b6fc4e65aca1bd969c42c988';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  RtcEngine? _engine;
  bool _isInitialized = false;
  bool _isMuted = false;
  bool _isCameraOff = false;

  /// Inicializar el engine de Agora para videollamadas
  Future<void> initializeAgora() async {
    // Si ya está inicializado, liberar primero para reiniciar en modo video
    if (_isInitialized && _engine != null) {
      print('⚠️ Agora ya está inicializado, liberando para reiniciar en modo video...');
      await _engine!.leaveChannel();
      await _engine!.release();
      _isInitialized = false;
      _engine = null;
    }

    try {
      print('🎥 Inicializando Agora...');

      // Crear engine
      _engine = createAgoraRtcEngine();

      // Inicializar engine
      await _engine!.initialize(
        RtcEngineContext(
          appId: APP_ID,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );

      // Configurar event handlers
      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            print('✅ Unido al canal: ${connection.channelId}');
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            print('👤 Usuario remoto unido: $remoteUid');
          },
          onUserOffline:
              (
                RtcConnection connection,
                int remoteUid,
                UserOfflineReasonType reason,
              ) {
                print('👋 Usuario remoto desconectado: $remoteUid');
              },
          onError: (ErrorCodeType err, String msg) {
            print('❌ Error de Agora: $err - $msg');
          },
        ),
      );

      // Habilitar video
      await _engine!.enableVideo();

      // Habilitar audio
      await _engine!.enableAudio();

      // Iniciar preview para solicitar permisos de iOS
      // Esto hará que iOS muestre el diálogo de permisos automáticamente
      await _engine!.startPreview();

      _isInitialized = true;
      print('✅ Agora inicializado correctamente');
    } catch (e) {
      print('❌ Error inicializando Agora: $e');
      rethrow;
    }
  }

  /// Inicializar el engine de Agora para llamadas de audio únicamente
  Future<void> initializeAgoraAudio() async {
    // Si ya está inicializado, liberar primero para reiniciar en modo audio
    if (_isInitialized && _engine != null) {
      print('⚠️ Agora ya está inicializado, liberando para reiniciar en modo audio...');
      await _engine!.leaveChannel();
      await _engine!.release();
      _isInitialized = false;
      _engine = null;
    }

    try {
      print('🎤 Inicializando Agora para audio...');

      // Crear engine
      _engine = createAgoraRtcEngine();

      // Inicializar engine
      await _engine!.initialize(
        RtcEngineContext(
          appId: APP_ID,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );

      // Configurar event handlers
      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            print('✅ Unido al canal de audio: ${connection.channelId}');
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            print('👤 Usuario remoto unido: $remoteUid');
          },
          onUserOffline:
              (
                RtcConnection connection,
                int remoteUid,
                UserOfflineReasonType reason,
              ) {
                print('👋 Usuario remoto desconectado: $remoteUid');
              },
          onError: (ErrorCodeType err, String msg) {
            print('❌ Error de Agora: $err - $msg');
          },
        ),
      );

      // Habilitar SOLO audio (sin video)
      await _engine!.enableAudio();

      _isInitialized = true;
      print('✅ Agora audio inicializado correctamente');
    } catch (e) {
      print('❌ Error inicializando Agora audio: $e');
      rethrow;
    }
  }

  /// Solicitar permisos de cámara y micrófono
  Future<Map<String, dynamic>> requestPermissions() async {
    try {
      print('🔒 Solicitando permisos de cámara y micrófono...');

      // Solicitar permisos directamente - esto mostrará el diálogo del sistema
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = await Permission.microphone.request();

      print('📹 Estado cámara después de request: $cameraStatus');
      print('🎤 Estado micrófono después de request: $microphoneStatus');

      // Verificar si fueron concedidos
      bool allGranted = cameraStatus.isGranted && microphoneStatus.isGranted;

      if (allGranted) {
        print('✅ Permisos concedidos');
        return {
          'granted': true,
          'permanentlyDenied': false,
        };
      }

      // Verificar si fueron permanentemente denegados
      bool isPermanentlyDenied = cameraStatus.isPermanentlyDenied || microphoneStatus.isPermanentlyDenied;

      if (isPermanentlyDenied) {
        print('⚠️ Permisos permanentemente denegados');
        return {
          'granted': false,
          'permanentlyDenied': true,
        };
      }

      print('❌ Permisos denegados');
      return {
        'granted': false,
        'permanentlyDenied': false,
      };
    } catch (e) {
      print('❌ Error solicitando permisos: $e');
      return {
        'granted': false,
        'permanentlyDenied': false,
      };
    }
  }

  /// Unirse a un canal de video
  Future<void> joinChannel({
    required String channelName,
    required String token,
    required int uid,
  }) async {
    if (!_isInitialized) {
      await initializeAgora();
    }

    try {
      print('🚀 Uniéndose al canal: $channelName con UID: $uid');

      // Configurar opciones del canal
      ChannelMediaOptions options = const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      );

      // Unirse al canal
      await _engine!.joinChannel(
        token: token,
        channelId: channelName,
        uid: uid,
        options: options,
      );

      print('✅ Unido al canal exitosamente');
    } catch (e) {
      print('❌ Error uniéndose al canal: $e');
      rethrow;
    }
  }

  /// Salir del canal
  Future<void> leaveChannel() async {
    try {
      print('👋 Saliendo del canal...');

      await _engine?.leaveChannel();
      await _engine?.stopPreview();

      print('✅ Canal abandonado');
    } catch (e) {
      print('❌ Error saliendo del canal: $e');
    }
  }

  /// Toggle micrófono (mute/unmute)
  Future<void> toggleMute() async {
    try {
      _isMuted = !_isMuted;
      await _engine?.muteLocalAudioStream(_isMuted);
      print(_isMuted ? '🔇 Micrófono silenciado' : '🎤 Micrófono activado');
    } catch (e) {
      print('❌ Error toggle mute: $e');
    }
  }

  /// Toggle cámara (on/off)
  Future<void> toggleCamera() async {
    try {
      _isCameraOff = !_isCameraOff;
      await _engine?.muteLocalVideoStream(_isCameraOff);
      print(_isCameraOff ? '📷 Cámara apagada' : '📹 Cámara encendida');
    } catch (e) {
      print('❌ Error toggle camera: $e');
    }
  }

  /// Cambiar entre cámara frontal y trasera
  Future<void> switchCamera() async {
    try {
      await _engine?.switchCamera();
      print('🔄 Cámara cambiada');
    } catch (e) {
      print('❌ Error cambiando cámara: $e');
    }
  }

  /// Obtener el engine de Agora (para usar en la UI)
  RtcEngine? get engine => _engine;

  /// Estado del micrófono
  bool get isMuted => _isMuted;

  /// Estado de la cámara
  bool get isCameraOff => _isCameraOff;

  /// Resetear estado de inicialización (para reintentos después de error de permisos)
  void resetInitialization() {
    _isInitialized = false;
  }

  /// Liberar recursos
  Future<void> dispose() async {
    try {
      print('🧹 Limpiando recursos de Agora...');
      await _engine?.leaveChannel();
      await _engine?.release();
      _isInitialized = false;
      print('✅ Recursos liberados');
    } catch (e) {
      print('❌ Error liberando recursos: $e');
    }
  }

  // ============================================
  // Señalización de llamadas con Firestore
  // ============================================

  /// Iniciar una videollamada (enviar invitación)
  Future<String> startCall({
    required String callerId,
    required String callerName,
    required String receiverId,
    required String receiverName,
  }) async {
    try {
      print('📞 Iniciando videollamada de $callerName a $receiverName');

      // Crear documento de llamada en Firestore primero para obtener el ID
      final callDoc = await _firestore.collection('video_calls').add({
        'callerId': callerId,
        'callerName': callerName,
        'receiverId': receiverId,
        'receiverName': receiverName,
        'status': 'ringing', // ringing, accepted, rejected, ended
        'createdAt': FieldValue.serverTimestamp(),
        'token': '', // En producción, generar token desde servidor
        'callType': 'video', // Tipo de llamada
      });

      // Usar el ID del documento como nombre del canal (corto y único, ~20 caracteres)
      String channelName = callDoc.id;

      // Actualizar el documento con el nombre del canal
      await callDoc.update({
        'channelName': channelName,
      });

      // Crear notificación para disparar push notification al receptor
      await _firestore.collection('notifications').add({
        'userId': receiverId,
        'type': 'video_call',
        'title': 'Videollamada entrante',
        'body': '$callerName te está llamando',
        'priority': 'high',
        'data': {
          'callId': callDoc.id,
          'callerId': callerId,
          'callerName': callerName,
          'channelName': channelName,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'read': false,
      });

      print('✅ Videollamada creada: ${callDoc.id}, Canal: $channelName');
      print('✅ Notificación de videollamada enviada a $receiverName');
      return callDoc.id;
    } catch (e) {
      print('❌ Error iniciando videollamada: $e');
      rethrow;
    }
  }

  /// Iniciar una llamada de audio (enviar invitación)
  Future<String> startAudioCall({
    required String callerId,
    required String callerName,
    required String receiverId,
    required String receiverName,
  }) async {
    try {
      print('📞 Iniciando llamada de audio de $callerName a $receiverName');

      // Crear documento de llamada en Firestore
      final callDoc = await _firestore.collection('video_calls').add({
        'callerId': callerId,
        'callerName': callerName,
        'receiverId': receiverId,
        'receiverName': receiverName,
        'status': 'ringing',
        'createdAt': FieldValue.serverTimestamp(),
        'token': '',
        'callType': 'audio', // Tipo de llamada: audio
      });

      // Usar el ID del documento como nombre del canal
      String channelName = callDoc.id;

      // Actualizar el documento con el nombre del canal
      await callDoc.update({
        'channelName': channelName,
      });

      // Crear notificación para disparar push notification al receptor
      await _firestore.collection('notifications').add({
        'userId': receiverId,
        'type': 'audio_call',
        'title': 'Llamada entrante',
        'body': '$callerName te está llamando',
        'priority': 'high',
        'data': {
          'callId': callDoc.id,
          'callerId': callerId,
          'callerName': callerName,
          'channelName': channelName,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'read': false,
      });

      print('✅ Llamada de audio creada: ${callDoc.id}, Canal: $channelName');
      print('✅ Notificación de llamada enviada a $receiverName');
      return callDoc.id;
    } catch (e) {
      print('❌ Error iniciando llamada de audio: $e');
      rethrow;
    }
  }

  /// Aceptar una llamada
  Future<void> acceptCall(String callId) async {
    try {
      print('✅ Aceptando llamada: $callId');

      await _firestore.collection('video_calls').doc(callId).update({
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('❌ Error aceptando llamada: $e');
      rethrow;
    }
  }

  /// Rechazar una llamada
  Future<void> rejectCall(String callId) async {
    try {
      print('❌ Rechazando llamada: $callId');

      await _firestore.collection('video_calls').doc(callId).update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('❌ Error rechazando llamada: $e');
      rethrow;
    }
  }

  /// Terminar una llamada
  Future<void> endCall(String callId) async {
    try {
      print('📵 Terminando llamada: $callId');

      await _firestore.collection('video_calls').doc(callId).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
      });

      await leaveChannel();
    } catch (e) {
      print('❌ Error terminando llamada: $e');
    }
  }

  /// Escuchar llamadas entrantes para un usuario
  Stream<QuerySnapshot> watchIncomingCalls(String userId) {
    return _firestore
        .collection('video_calls')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'ringing')
        .snapshots();
  }

  /// Escuchar el estado de una llamada específica
  Stream<DocumentSnapshot> watchCallStatus(String callId) {
    return _firestore.collection('video_calls').doc(callId).snapshots();
  }
}
