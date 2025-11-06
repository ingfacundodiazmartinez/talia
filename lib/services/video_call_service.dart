import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'app_config_service.dart';
import 'block_service.dart';
import 'callkit_service.dart';
import '../utils/release_logger.dart';

class VideoCallService {
  static final VideoCallService _instance = VideoCallService._internal();
  factory VideoCallService() => _instance;
  VideoCallService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final AppConfigService _appConfig = AppConfigService();
  final BlockService _blockService = BlockService();

  // Obtener APP_ID de forma segura desde Remote Config
  String get _appId => _appConfig.agoraAppId;

  RtcEngine? _engine;
  bool _isInitialized = false;
  bool _isMuted = false;
  bool _isCameraOff = false;

  // Getters para exponer el estado
  bool get isCameraOff => _isCameraOff;
  bool get isMuted => _isMuted;

  /// Inicializar el engine de Agora para videollamadas o llamadas de audio
  Future<void> initializeAgora({bool isVideo = true}) async {
    // Si ya está inicializado, liberar primero para reiniciar
    if (_isInitialized && _engine != null) {
      ReleaseLogger.log(
        '⚠️ Agora ya está inicializado, liberando para reiniciar en modo ${isVideo ? 'video' : 'audio'}...', tag: 'VideoCallService',
      );
      try {
        // Detener preview y deshabilitar video/audio ANTES de liberar
        await _engine!.stopPreview();
        await _engine!.disableVideo();
        await _engine!.disableAudio();
        await _engine!.leaveChannel();
        await _engine!.release();
        ReleaseLogger.log('✅ Engine anterior liberado completamente', tag: 'VideoCallService');
      } catch (e) {
        ReleaseLogger.error('Error liberando engine anterior: $e', tag: 'VideoCallService');
      }

      // Resetear estado
      _isInitialized = false;
      _engine = null;
      _isMuted = false;
      _isCameraOff = false;

      // Delay breve para asegurar limpieza completa
      await Future.delayed(Duration(milliseconds: 200));
    }

    try {
      ReleaseLogger.log('🎥 Inicializando Agora en modo ${isVideo ? 'video' : 'audio'}...', tag: 'VideoCallService');

      // Crear engine
      _engine = createAgoraRtcEngine();

      // Inicializar engine
      await _engine!.initialize(
        RtcEngineContext(
          appId: _appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );

      // Configurar event handlers
      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            ReleaseLogger.log('✅ Unido al canal: ${connection.channelId}', tag: 'VideoCallService');
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            ReleaseLogger.log('👤 Usuario remoto unido: $remoteUid', tag: 'VideoCallService');
          },
          onUserOffline:
              (
                RtcConnection connection,
                int remoteUid,
                UserOfflineReasonType reason,
              ) {
                ReleaseLogger.log('👋 Usuario remoto desconectado: $remoteUid', tag: 'VideoCallService');
              },
          onError: (ErrorCodeType err, String msg) {
            ReleaseLogger.error('❌ Error de Agora: $err - $msg', tag: 'VideoCallService');
          },
        ),
      );

      // ✅ Solo habilitar video si es una videollamada
      if (isVideo) {
        await _engine!.enableVideo();
        await _engine!.enableLocalVideo(true);
        ReleaseLogger.log('✅ Video habilitado', tag: 'VideoCallService');
      } else {
        ReleaseLogger.log('🎤 Video NO habilitado (modo audio)', tag: 'VideoCallService');
      }

      // Habilitar audio (siempre necesario)
      await _engine!.enableAudio();

      // ✅ NO llamar setupLocalVideo() aquí
      // El widget AgoraVideoView lo llamará automáticamente cuando se monte
      // Si lo llamamos aquí, sobreescribimos el binding del widget y el video no se muestra

      ReleaseLogger.log('✅ Agora engine listo (setupLocalVideo y startPreview serán manejados por los widgets)', tag: 'VideoCallService');

      _isInitialized = true;
      ReleaseLogger.log('✅ Agora inicializado correctamente en modo ${isVideo ? 'video' : 'audio'}', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('Error inicializando Agora: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Inicializar el engine de Agora para llamadas de audio únicamente
  Future<void> initializeAgoraAudio() async {
    // Si ya está inicializado, liberar primero para reiniciar en modo audio
    if (_isInitialized && _engine != null) {
      ReleaseLogger.log(
        '⚠️ Agora ya está inicializado, liberando para reiniciar en modo audio...', tag: 'VideoCallService',
      );
      try {
        // Detener todo ANTES de liberar
        await _engine!.stopPreview();
        await _engine!.disableVideo();
        await _engine!.disableAudio();
        await _engine!.leaveChannel();
        await _engine!.release();
        ReleaseLogger.log('✅ Engine anterior liberado completamente', tag: 'VideoCallService');
      } catch (e) {
        ReleaseLogger.error('Error liberando engine anterior: $e', tag: 'VideoCallService');
      }

      // Resetear estado
      _isInitialized = false;
      _engine = null;
      _isMuted = false;
      _isCameraOff = false;

      // Delay breve para asegurar limpieza completa
      await Future.delayed(Duration(milliseconds: 200));
    }

    try {
      ReleaseLogger.log('🎤 Inicializando Agora para audio...', tag: 'VideoCallService');

      // Crear engine
      _engine = createAgoraRtcEngine();

      // Inicializar engine
      await _engine!.initialize(
        RtcEngineContext(
          appId: _appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );

      // Configurar event handlers
      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            ReleaseLogger.log('✅ Unido al canal de audio: ${connection.channelId}', tag: 'VideoCallService');
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            ReleaseLogger.log('👤 Usuario remoto unido: $remoteUid', tag: 'VideoCallService');
          },
          onUserOffline:
              (
                RtcConnection connection,
                int remoteUid,
                UserOfflineReasonType reason,
              ) {
                ReleaseLogger.log('👋 Usuario remoto desconectado: $remoteUid', tag: 'VideoCallService');
              },
          onError: (ErrorCodeType err, String msg) {
            ReleaseLogger.error('❌ Error de Agora: $err - $msg', tag: 'VideoCallService');
          },
        ),
      );

      // Habilitar SOLO audio (sin video)
      await _engine!.enableAudio();

      _isInitialized = true;
      ReleaseLogger.log('✅ Agora audio inicializado correctamente', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('Error inicializando Agora audio: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Solicitar permisos de cámara y micrófono
  Future<Map<String, dynamic>> requestPermissions() async {
    try {
      ReleaseLogger.log('🔒 Solicitando permisos de cámara y micrófono...', tag: 'VideoCallService');

      // Solicitar permisos directamente - esto mostrará el diálogo del sistema
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = await Permission.microphone.request();

      ReleaseLogger.log('📹 Estado cámara después de request: $cameraStatus', tag: 'VideoCallService');
      ReleaseLogger.log('🎤 Estado micrófono después de request: $microphoneStatus', tag: 'VideoCallService');

      // Verificar si fueron concedidos
      bool allGranted = cameraStatus.isGranted && microphoneStatus.isGranted;

      if (allGranted) {
        ReleaseLogger.log('✅ Permisos concedidos', tag: 'VideoCallService');
        return {'granted': true, 'permanentlyDenied': false};
      }

      // Verificar si fueron permanentemente denegados
      bool isPermanentlyDenied =
          cameraStatus.isPermanentlyDenied ||
          microphoneStatus.isPermanentlyDenied;

      if (isPermanentlyDenied) {
        ReleaseLogger.log('⚠️ Permisos permanentemente denegados', tag: 'VideoCallService');
        return {'granted': false, 'permanentlyDenied': true};
      }

      ReleaseLogger.error('Permisos denegados', tag: 'VideoCallService');
      return {'granted': false, 'permanentlyDenied': false};
    } catch (e) {
      ReleaseLogger.error('❌ Error solicitando permisos: $e', tag: 'VideoCallService');
      return {'granted': false, 'permanentlyDenied': false};
    }
  }

  /// Unirse a un canal de video
  Future<void> joinChannel({
    required String channelName,
    required String token,
    required int uid,
    bool isVideo = true, // Por defecto video para compatibilidad
  }) async {
    if (!_isInitialized) {
      // ✅ Pasar el parámetro isVideo a initializeAgora
      await initializeAgora(isVideo: isVideo);
    }

    try {
      ReleaseLogger.log(
        '🚀 Uniéndose al canal: $channelName con UID: $uid (isVideo: $isVideo)', tag: 'VideoCallService',
      );

      // Configurar opciones del canal según tipo de llamada
      ChannelMediaOptions options = ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        publishCameraTrack: isVideo, // ✅ Solo publicar cámara si es video
        publishMicrophoneTrack: true,
        autoSubscribeVideo: isVideo, // ✅ Solo suscribirse a video si es video
        autoSubscribeAudio: true,
      );

      // Unirse al canal
      await _engine!.joinChannel(
        token: token,
        channelId: channelName,
        uid: uid,
        options: options,
      );

      ReleaseLogger.log('✅ Unido al canal exitosamente', tag: 'VideoCallService');

      // NO iniciar preview aquí - se hará en el callback onJoinChannelSuccess
      // después de que el UI se haya actualizado y los widgets de video estén creados
    } catch (e) {
      ReleaseLogger.error('❌ Error uniéndose al canal: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Salir del canal
  Future<void> leaveChannel() async {
    try {
      ReleaseLogger.log('👋 Saliendo del canal...', tag: 'VideoCallService');

      await _engine?.leaveChannel();
      await _engine?.stopPreview();

      ReleaseLogger.log('✅ Canal abandonado', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error saliendo del canal: $e', tag: 'VideoCallService');
    }
  }

  /// Toggle micrófono (mute/unmute)
  Future<void> toggleMute() async {
    try {
      _isMuted = !_isMuted;
      await _engine?.muteLocalAudioStream(_isMuted);
      ReleaseLogger.log(_isMuted ? '🔇 Micrófono silenciado' : '🎤 Micrófono activado', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error toggle mute: $e', tag: 'VideoCallService');
    }
  }

  /// Toggle cámara (on/off)
  Future<void> toggleCamera() async {
    try {
      _isCameraOff = !_isCameraOff;

      if (_isCameraOff) {
        // Deshabilitar captura de video completamente
        await _engine?.enableLocalVideo(false);
        await _engine?.stopPreview();
        ReleaseLogger.log('📷 Cámara apagada - captura de video deshabilitada', tag: 'VideoCallService');
      } else {
        // Habilitar captura de video y preview
        await _engine?.enableLocalVideo(true);
        await _engine?.startPreview();
        ReleaseLogger.log('📹 Cámara encendida - captura de video habilitada', tag: 'VideoCallService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error toggle camera: $e', tag: 'VideoCallService');
    }
  }

  /// Cambiar entre cámara frontal y trasera
  Future<void> switchCamera() async {
    try {
      await _engine?.switchCamera();
      ReleaseLogger.log('🔄 Cámara cambiada', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error cambiando cámara: $e', tag: 'VideoCallService');
    }
  }

  /// Obtener el engine de Agora (para usar en la UI)
  RtcEngine? get engine => _engine;


  /// Resetear estado de inicialización (para reintentos después de error de permisos)
  void resetInitialization() {
    _isInitialized = false;
  }

  /// Liberar recursos
  Future<void> dispose() async {
    try {
      ReleaseLogger.log('🧹 Limpiando recursos de Agora...', tag: 'VideoCallService');
      await _engine?.leaveChannel();
      await _engine?.release();
      _isInitialized = false;
      ReleaseLogger.log('✅ Recursos liberados', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error liberando recursos: $e', tag: 'VideoCallService');
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
      ReleaseLogger.log('📞 Iniciando videollamada de $callerName a $receiverName', tag: 'VideoCallService');

      // Generar un ID único para usar como channelName
      final docRef = _firestore.collection('video_calls').doc();
      final channelName = docRef.id;

      // Obtener photoURL del caller
      final callerDoc = await _firestore
          .collection('users')
          .doc(callerId)
          .get();
      final callerPhotoURL = callerDoc.data()?['photoURL'] ?? '';

      // Crear documento con TODOS los campos de una vez (incluyendo channelName)
      await docRef.set({
        'callerId': callerId,
        'callerName': callerName,
        'receiverId': receiverId,
        'receiverName': receiverName,
        'channelName': channelName, // ← INCLUIR DESDE EL INICIO
        'status': 'ringing', // ringing, accepted, rejected, ended
        'createdAt': FieldValue.serverTimestamp(),
        'token': '', // En producción, generar token desde servidor
        'callType': 'video', // Tipo de llamada
      });

      ReleaseLogger.log('✅ Videollamada creada: $channelName', tag: 'VideoCallService');

      // ✅ Enviar VoIP push directamente usando Cloud Function
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'sendInstantPushNotification',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 10)),
        );

        final result = await callable.call({
          'receiverId': receiverId,
          'title': 'Videollamada entrante',
          'body': '$callerName te está llamando',
          'isCall': true,
          'data': {
            'type': 'video_call',
            'callId': channelName,
            'callerId': callerId,
            'callerName': callerName,
            'channelName': channelName,
            'callType': 'video',
            'senderPhotoUrl': callerPhotoURL,
          },
        });

        ReleaseLogger.log('✅ Push notification enviada: ${result.data}', tag: 'VideoCallService');

        if (result.data['sentViaVoIP'] == true) {
          ReleaseLogger.log(
            '✅ Enviado via VoIP push - CallKit se mostrará automáticamente', tag: 'VideoCallService',
          );
        } else {
          ReleaseLogger.log('✅ Enviado via FCM push', tag: 'VideoCallService');
        }
      } catch (pushError) {
        ReleaseLogger.error('⚠️ Error enviando push notification: $pushError', tag: 'VideoCallService');
        // No lanzar error - la llamada ya se creó en Firestore
      }

      return channelName;
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando videollamada: $e', tag: 'VideoCallService');
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
      ReleaseLogger.log('📞 Iniciando llamada de audio de $callerName a $receiverName', tag: 'VideoCallService');

      // Generar un ID único para usar como channelName
      final docRef = _firestore.collection('video_calls').doc();
      final channelName = docRef.id;

      // Obtener photoURL del caller
      final callerDoc = await _firestore
          .collection('users')
          .doc(callerId)
          .get();
      final callerPhotoURL = callerDoc.data()?['photoURL'] ?? '';

      // Crear documento con TODOS los campos de una vez (incluyendo channelName)
      await docRef.set({
        'callerId': callerId,
        'callerName': callerName,
        'receiverId': receiverId,
        'receiverName': receiverName,
        'channelName': channelName, // ← INCLUIR DESDE EL INICIO
        'status': 'ringing',
        'createdAt': FieldValue.serverTimestamp(),
        'token': '',
        'callType': 'audio', // Tipo de llamada: audio
      });

      ReleaseLogger.log('✅ Llamada de audio creada: $channelName', tag: 'VideoCallService');

      // ✅ Enviar VoIP push directamente usando Cloud Function
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'sendInstantPushNotification',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 10)),
        );

        final result = await callable.call({
          'receiverId': receiverId,
          'title': 'Llamada entrante',
          'body': '$callerName te está llamando',
          'isCall': true,
          'data': {
            'type': 'audio_call',
            'callId': channelName,
            'callerId': callerId,
            'callerName': callerName,
            'channelName': channelName,
            'callType': 'audio',
            'senderPhotoUrl': callerPhotoURL,
          },
        });

        ReleaseLogger.log('✅ Push notification enviada: ${result.data}', tag: 'VideoCallService');

        if (result.data['sentViaVoIP'] == true) {
          ReleaseLogger.log(
            '✅ Enviado via VoIP push - CallKit se mostrará automáticamente',
            tag: 'VideoCallService',
          );
        } else {
          ReleaseLogger.log('✅ Enviado via FCM push', tag: 'VideoCallService');
        }
      } catch (pushError) {
        ReleaseLogger.error('⚠️ Error enviando push notification: $pushError', tag: 'VideoCallService');
        // No lanzar error - la llamada ya se creó en Firestore
      }

      return channelName;
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando llamada de audio: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  // ============================================
  // Videollamadas Grupales
  // ============================================

  /// Iniciar una videollamada grupal
  ///
  /// [participantIds]: Lista de userIds que serán invitados (sin incluir al caller)
  /// [participantNames]: Mapa de userId -> userName
  /// [groupId]: ID del grupo (null para llamadas de emergencia)
  /// [isEmergency]: true si es una llamada de emergencia
  Future<String> startGroupCall({
    required String callerId,
    required String callerName,
    required List<String> participantIds,
    required Map<String, String> participantNames,
    String? groupId,
    bool isEmergency = false,
  }) async {
    try {
      ReleaseLogger.log('📞 Iniciando videollamada grupal de $callerName', tag: 'VideoCallService');
      ReleaseLogger.log('👥 Participantes: ${participantIds.length}', tag: 'VideoCallService');

      // Generar un ID único para usar como channelName
      final docRef = _firestore.collection('video_calls').doc();
      final channelName = docRef.id;

      // Construir array de participantes
      List<Map<String, dynamic>> participants = [];

      // Usar Timestamp.now() en lugar de FieldValue.serverTimestamp()
      // dentro de arrays para evitar crashes en Android
      final now = Timestamp.now();

      // Agregar caller como primer participante (ya unido)
      participants.add({
        'userId': callerId,
        'userName': callerName,
        'status': 'joined',
        'joinedAt': now,
        'leftAt': null,
      });

      // Agregar resto de participantes (en estado ringing)
      for (String participantId in participantIds) {
        participants.add({
          'userId': participantId,
          'userName': participantNames[participantId] ?? 'Usuario',
          'status': 'ringing',
          'joinedAt': null,
          'leftAt': null,
        });
      }

      // Crear documento de llamada grupal
      await docRef.set({
        'callId': channelName,
        'callerId': callerId,
        'callerName': callerName,
        'channelName': channelName,
        'isGroupCall': true,
        'isEmergency': isEmergency,
        'groupId': groupId,
        'participants': participants,
        'status': 'ringing', // ringing, active, ended
        'createdAt': FieldValue.serverTimestamp(),
        'endedAt': null,
        'token': '',
        'callType': 'video',
      });

      ReleaseLogger.log('✅ Videollamada grupal creada: $channelName', tag: 'VideoCallService');

      // Obtener photoURL del caller
      final callerDoc = await _firestore
          .collection('users')
          .doc(callerId)
          .get();
      final callerPhotoURL = callerDoc.data()?['photoURL'] ?? '';

      // ✅ Enviar VoIP push a todos los participantes usando Cloud Function
      int successCount = 0;
      for (String participantId in participantIds) {
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'sendInstantPushNotification',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 10)),
          );

          final title = isEmergency
              ? '🚨 Llamada de emergencia'
              : 'Videollamada grupal';
          final body = isEmergency
              ? '$callerName necesita ayuda urgente'
              : '$callerName te invitó a una videollamada grupal';

          final result = await callable.call({
            'receiverId': participantId,
            'title': title,
            'body': body,
            'isCall': true,
            'data': {
              'type': isEmergency ? 'emergency_call' : 'group_video_call',
              'callId': channelName,
              'callerId': callerId,
              'callerName': callerName,
              'channelName': channelName,
              'callType': 'video',
              'isGroupCall': true, // Boolean en lugar de string
              'isEmergency': isEmergency, // Boolean en lugar de string
              'groupId': groupId ?? '',
              'senderPhotoUrl': callerPhotoURL, // Consistente con llamadas 1-1
            },
          });

          if (result.data['success'] == true) {
            successCount++;
            if (result.data['sentViaVoIP'] == true) {
              ReleaseLogger.log('✅ VoIP push enviado a participante $participantId', tag: 'VideoCallService');
            } else {
              ReleaseLogger.log('✅ FCM push enviado a participante $participantId', tag: 'VideoCallService');
            }
          }
        } catch (pushError) {
          ReleaseLogger.error('⚠️ Error enviando push a participante $participantId: $pushError', tag: 'VideoCallService');
          // Continuar con los demás participantes
        }
      }

      ReleaseLogger.log(
        '✅ Notificaciones enviadas a $successCount/${participantIds.length} participantes',
        tag: 'VideoCallService',
      );
      return channelName;
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando videollamada grupal: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Iniciar una llamada de audio grupal
  Future<String> startGroupAudioCall({
    required String callerId,
    required String callerName,
    required List<String> participantIds,
    required Map<String, String> participantNames,
    String? groupId,
    bool isEmergency = false,
  }) async {
    try {
      ReleaseLogger.log('📞 Iniciando llamada de audio grupal de $callerName', tag: 'VideoCallService');
      ReleaseLogger.log('👥 Participantes: ${participantIds.length}', tag: 'VideoCallService');

      // Generar un ID único para usar como channelName
      final docRef = _firestore.collection('video_calls').doc();
      final channelName = docRef.id;

      // Construir array de participantes
      List<Map<String, dynamic>> participants = [];

      // Agregar caller como primer participante (ya unido)
      participants.add({
        'userId': callerId,
        'userName': callerName,
        'status': 'joined',
        'joinedAt': FieldValue.serverTimestamp(),
        'leftAt': null,
      });

      // Agregar resto de participantes (en estado ringing)
      for (String participantId in participantIds) {
        participants.add({
          'userId': participantId,
          'userName': participantNames[participantId] ?? 'Usuario',
          'status': 'ringing',
          'joinedAt': null,
          'leftAt': null,
        });
      }

      // Crear documento de llamada grupal
      await docRef.set({
        'callId': channelName,
        'callerId': callerId,
        'callerName': callerName,
        'channelName': channelName,
        'isGroupCall': true,
        'isEmergency': isEmergency,
        'groupId': groupId,
        'participants': participants,
        'status': 'ringing',
        'createdAt': FieldValue.serverTimestamp(),
        'endedAt': null,
        'token': '',
        'callType': 'audio',
      });

      ReleaseLogger.log('✅ Llamada de audio grupal creada: $channelName', tag: 'VideoCallService');

      // Obtener photoURL del caller
      final callerDoc = await _firestore
          .collection('users')
          .doc(callerId)
          .get();
      final callerPhotoURL = callerDoc.data()?['photoURL'] ?? '';

      // ✅ Enviar VoIP push a todos los participantes usando Cloud Function
      int successCount = 0;
      for (String participantId in participantIds) {
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'sendInstantPushNotification',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 10)),
          );

          final title = isEmergency
              ? '🚨 Llamada de emergencia'
              : 'Llamada grupal';
          final body = isEmergency
              ? '$callerName necesita ayuda urgente'
              : '$callerName te invitó a una llamada grupal';

          final result = await callable.call({
            'receiverId': participantId,
            'title': title,
            'body': body,
            'isCall': true,
            'data': {
              'type': isEmergency ? 'emergency_call' : 'group_audio_call',
              'callId': channelName,
              'callerId': callerId,
              'callerName': callerName,
              'channelName': channelName,
              'callType': 'audio',
              'isGroupCall': true, // Boolean en lugar de string
              'isEmergency': isEmergency, // Boolean en lugar de string
              'groupId': groupId ?? '',
              'senderPhotoUrl': callerPhotoURL, // Consistente con llamadas 1-1
            },
          });

          if (result.data['success'] == true) {
            successCount++;
            if (result.data['sentViaVoIP'] == true) {
              ReleaseLogger.log('✅ VoIP push enviado a participante $participantId', tag: 'VideoCallService');
            } else {
              ReleaseLogger.log('✅ FCM push enviado a participante $participantId', tag: 'VideoCallService');
            }
          }
        } catch (pushError) {
          ReleaseLogger.error('⚠️ Error enviando push a participante $participantId: $pushError', tag: 'VideoCallService');
          // Continuar con los demás participantes
        }
      }

      ReleaseLogger.log(
        '✅ Notificaciones enviadas a $successCount/${participantIds.length} participantes',
        tag: 'VideoCallService',
      );
      return channelName;
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando llamada de audio grupal: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Actualizar estado de un participante en llamada grupal
  Future<void> updateParticipantStatus({
    required String callId,
    required String userId,
    required String status, // joined, declined, left
  }) async {
    try {
      ReleaseLogger.log('📝 Actualizando estado de participante $userId a: $status', tag: 'VideoCallService');

      final callDoc = await _firestore
          .collection('video_calls')
          .doc(callId)
          .get();
      if (!callDoc.exists) {
        ReleaseLogger.log('⚠️ Llamada no encontrada: $callId', tag: 'VideoCallService');
        return;
      }

      final callData = callDoc.data()!;
      List<dynamic> participants = callData['participants'] ?? [];

      // Encontrar y actualizar el participante
      bool updated = false;
      for (int i = 0; i < participants.length; i++) {
        if (participants[i]['userId'] == userId) {
          participants[i]['status'] = status;

          if (status == 'joined') {
            participants[i]['joinedAt'] = FieldValue.serverTimestamp();
          } else if (status == 'left') {
            participants[i]['leftAt'] = FieldValue.serverTimestamp();
          }

          updated = true;
          break;
        }
      }

      if (!updated) {
        ReleaseLogger.log('⚠️ Participante no encontrado en la llamada', tag: 'VideoCallService');
        return;
      }

      // Actualizar documento
      await _firestore.collection('video_calls').doc(callId).update({
        'participants': participants,
      });

      // Si alguien se unió, cambiar estado de llamada a 'active'
      if (status == 'joined' && (callData['status'] == 'ringing' || callData['status'] == 'accepted')) {
        final updateData = <String, dynamic>{
          'status': 'active',
        };

        // Solo establecer startedAt si no existe aún
        if (callData['startedAt'] == null) {
          updateData['startedAt'] = FieldValue.serverTimestamp();
        }

        await _firestore.collection('video_calls').doc(callId).update(updateData);
      }

      // Si todos salieron, terminar la llamada
      bool allLeft = participants.every(
        (p) => p['status'] == 'left' || p['status'] == 'declined',
      );
      if (allLeft) {
        await _firestore.collection('video_calls').doc(callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });
      }

      ReleaseLogger.log('✅ Estado de participante actualizado', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error actualizando estado de participante: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Invitar a un usuario a una llamada en curso (convertir 1:1 a grupal)
  ///
  /// Este método permite añadir participantes a una llamada existente,
  /// convirtiendo automáticamente una llamada 1:1 en grupal.
  Future<Map<String, dynamic>> inviteToOngoingCall({
    required String callId,
    required String channelName,
    required String invitedUserId,
    required String invitedUserName,
  }) async {
    try {
      ReleaseLogger.log('📞 Invitando a $invitedUserName a la llamada $callId', tag: 'VideoCallService');

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return {'success': false, 'error': 'Usuario no autenticado'};
      }

      // 1. Obtener documento de la llamada actual
      final callDoc = await _firestore
          .collection('video_calls')
          .doc(callId)
          .get();
      if (!callDoc.exists) {
        return {'success': false, 'error': 'Llamada no encontrada'};
      }

      final callData = callDoc.data()!;
      final isGroupCall = callData['isGroupCall'] ?? false;
      final callType = callData['callType'] ?? 'video';

      // 2. Preparar datos del nuevo participante
      final newParticipant = {
        'userId': invitedUserId,
        'userName': invitedUserName,
        'status': 'ringing',
        'joinedAt': null,
        'leftAt': null,
      };

      // 3. Si no es llamada grupal, convertirla a grupal
      if (!isGroupCall) {
        ReleaseLogger.log('🔄 Convirtiendo llamada 1:1 a grupal...', tag: 'VideoCallService');

        // Obtener información de participantes actuales
        final callerId = callData['callerId'];
        final callerName = callData['callerName'];
        final receiverId = callData['receiverId'];
        final receiverName = callData['receiverName'];

        // Crear array de participantes con los dos originales + el nuevo
        final participants = [
          {
            'userId': callerId,
            'userName': callerName,
            'status': 'joined',
            'joinedAt': Timestamp.now(),
            'leftAt': null,
          },
          {
            'userId': receiverId,
            'userName': receiverName,
            'status': 'joined',
            'joinedAt': Timestamp.now(),
            'leftAt': null,
          },
          newParticipant,
        ];

        // Actualizar llamada a formato grupal
        await _firestore.collection('video_calls').doc(callId).update({
          'isGroupCall': true,
          'participants': participants,
          'status': 'active',
        });
      } else {
        // 4. Si ya es grupal, agregar el nuevo participante
        ReleaseLogger.log('➕ Agregando participante a llamada grupal existente...', tag: 'VideoCallService');

        List<dynamic> participants = callData['participants'] ?? [];

        // Verificar que no esté ya en la llamada
        bool alreadyInCall = participants.any(
          (p) => p['userId'] == invitedUserId,
        );
        if (alreadyInCall) {
          return {
            'success': false,
            'error': 'El usuario ya está en la llamada',
          };
        }

        // Agregar nuevo participante
        participants.add(newParticipant);

        await _firestore.collection('video_calls').doc(callId).update({
          'participants': participants,
        });
      }

      // 5. Enviar VoIP push notification al usuario invitado
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUser.uid)
          .get();
      final inviterName = currentUserDoc.data()?['name'] ?? 'Usuario';
      final inviterPhotoURL = currentUserDoc.data()?['photoURL'] ?? '';

      // ✅ Enviar VoIP push usando Cloud Function
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'sendInstantPushNotification',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 10)),
        );

        final title = callType == 'video'
            ? 'Videollamada grupal'
            : 'Llamada grupal';
        final body = '$inviterName te invitó a unirte a la llamada';

        final result = await callable.call({
          'receiverId': invitedUserId,
          'title': title,
          'body': body,
          'isCall': true,
          'data': {
            'type': callType == 'video'
                ? 'group_video_call'
                : 'group_audio_call',
            'callId': callId,
            'callerId': currentUser.uid,
            'callerName': inviterName,
            'channelName': channelName,
            'callType': callType,
            'isGroupCall': 'true',
            'senderPhotoUrl': inviterPhotoURL,
          },
        });

        if (result.data['sentViaVoIP'] == true) {
          ReleaseLogger.log('✅ VoIP push enviado al usuario invitado', tag: 'VideoCallService');
        } else {
          ReleaseLogger.log('✅ FCM push enviado al usuario invitado', tag: 'VideoCallService');
        }
      } catch (pushError) {
        ReleaseLogger.error('⚠️ Error enviando push al usuario invitado: $pushError', tag: 'VideoCallService');
        // No lanzar error - la invitación ya se agregó a Firestore
      }

      ReleaseLogger.log('✅ Usuario invitado exitosamente a la llamada', tag: 'VideoCallService');

      return {'success': true};
    } catch (e) {
      ReleaseLogger.error('❌ Error invitando a usuario a la llamada: $e', tag: 'VideoCallService');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Escuchar llamadas grupales entrantes para un usuario
  Stream<QuerySnapshot> watchIncomingGroupCalls(String userId) {
    return _firestore
        .collection('video_calls')
        .where(
          'participants',
          arrayContains: {'userId': userId, 'status': 'ringing'},
        )
        .snapshots();
  }

  /// Aceptar una llamada
  Future<void> acceptCall(String callId) async {
    try {
      ReleaseLogger.log('✅ Aceptando llamada: $callId', tag: 'VideoCallService');

      // Primero verificar si el documento existe
      final docSnapshot = await _firestore.collection('video_calls').doc(callId).get();
      if (!docSnapshot.exists) {
        ReleaseLogger.error('❌ ERROR: El documento $callId NO EXISTE antes de aceptar', tag: 'VideoCallService');
        throw 'El documento de la llamada no existe';
      }

      ReleaseLogger.log('📄 Documento existe, status actual: ${docSnapshot.data()?['status']}', tag: 'VideoCallService');

      await _firestore.collection('video_calls').doc(callId).update({
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
        'startedAt': FieldValue.serverTimestamp(), // Marcar inicio cuando se acepta
      });

      ReleaseLogger.log('✅ Llamada actualizada a status: accepted', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error aceptando llamada: $e', tag: 'VideoCallService');
      ReleaseLogger.error('❌ Stack trace: ${StackTrace.current}', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Rechazar una llamada
  Future<void> rejectCall(String callId) async {
    try {
      ReleaseLogger.log('❌ Rechazando llamada: $callId', tag: 'VideoCallService');

      // Obtener datos de la llamada antes de rechazarla
      final callDoc = await _firestore
          .collection('video_calls')
          .doc(callId)
          .get();
      final callData = callDoc.data();

      await _firestore.collection('video_calls').doc(callId).update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
      });

      // Crear mensaje de llamada perdida en el chat
      if (callData != null) {
        await _createMissedCallMessage(
          callerId: callData['callerId'] ?? '',
          receiverId: callData['receiverId'] ?? '',
          callType: callData['callType'] ?? 'video',
          callId: callId,
        );
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error rechazando llamada: $e', tag: 'VideoCallService');
      rethrow;
    }
  }

  /// Terminar una llamada
  Future<void> endCall(String callId) async {
    try {
      ReleaseLogger.log('📵 Terminando llamada: $callId', tag: 'VideoCallService');

      // Obtener datos de la llamada antes de terminarla
      final callDoc = await _firestore
          .collection('video_calls')
          .doc(callId)
          .get();
      final callData = callDoc.data();

      if (callData != null) {
        final startedAt = callData['startedAt'] as Timestamp?;
        final status = callData['status'] as String?;

        ReleaseLogger.log('📊 [endCall] Datos de la llamada:', tag: 'VideoCallService');
        ReleaseLogger.log('   - Status: $status', tag: 'VideoCallService');
        ReleaseLogger.log('   - StartedAt: $startedAt', tag: 'VideoCallService');
        ReleaseLogger.log('   - CallerId: ${callData['callerId']}', tag: 'VideoCallService');
        ReleaseLogger.log('   - ReceiverId: ${callData['receiverId']}', tag: 'VideoCallService');

        // Si la llamada nunca fue contestada (status: ringing), cambiar a 'cancelled'
        // El receptor detectará el cambio via listener y cerrará su CallKit
        if (status == 'ringing') {
          ReleaseLogger.log('📞 Llamada nunca fue contestada, cancelando...', tag: 'VideoCallService');

          // ✅ ESCRITURA DIRECTA desde el cliente (permitida por Firestore Rules)
          // El receiver tiene un listener activo que detectará este cambio inmediatamente
          await _firestore.collection('video_calls').doc(callId).update({
            'status': 'cancelled',
            'cancelledAt': FieldValue.serverTimestamp(),
          });
          ReleaseLogger.log('✅ Llamada marcada como cancelada en Firestore', tag: 'VideoCallService');

          // Crear mensaje de llamada perdida en el chat
          await _createMissedCallMessage(
            callerId: callData['callerId'] ?? '',
            receiverId: callData['receiverId'] ?? '',
            callType: callData['callType'] ?? 'video',
            callId: callId,
          );

          // NO cerramos CallKit aquí - VideoCallScreen._endCall() ya lo hace
          // Cerrar CallKit dos veces causa crashes
        } else {
          // Si fue contestada o está activa, actualizar status a ended
          await _firestore.collection('video_calls').doc(callId).update({
            'status': 'ended',
            'endedAt': FieldValue.serverTimestamp(),
          });

          // Si la llamada fue contestada (tiene startedAt), crear mensaje de historial
          // Verificamos que fue 'accepted' o 'active' (cualquiera de los dos significa que fue contestada)
          if (startedAt != null && (status == 'active' || status == 'accepted')) {
            final endedAt = DateTime.now();
            final startTime = startedAt.toDate();
            final durationSeconds = endedAt.difference(startTime).inSeconds;

            ReleaseLogger.log('📞 Creando mensaje de llamada contestada - duración: ${durationSeconds}s', tag: 'VideoCallService');

            await _createAnsweredCallMessage(
              callerId: callData['callerId'] ?? '',
              receiverId: callData['receiverId'] ?? '',
              callType: callData['callType'] ?? 'video',
              callId: callId,
              durationSeconds: durationSeconds,
            );
          } else {
            ReleaseLogger.log('⏭️ No se crea mensaje de llamada - startedAt: $startedAt, status: $status', tag: 'VideoCallService');
          }
        }
      } else {
        ReleaseLogger.log('⚠️ No se encontró documento de llamada', tag: 'VideoCallService');

        // Si el documento no existe, podría ser una race condition
        // (se está creando pero aún no está disponible para lectura)
        // Crear el documento con status cancelled para que el receiver lo detecte
        ReleaseLogger.log('🔄 Creando documento cancelled para evitar que el receiver suene', tag: 'VideoCallService');
        try {
          await _firestore.collection('video_calls').doc(callId).set({
            'status': 'cancelled',
            'cancelledAt': FieldValue.serverTimestamp(),
            'callId': callId,
          }, SetOptions(merge: true)); // merge: true para no sobreescribir si ya existe
          ReleaseLogger.log('✅ Documento cancelled creado/actualizado', tag: 'VideoCallService');
        } catch (e) {
          ReleaseLogger.error('⚠️ Error creando documento cancelled: $e', tag: 'VideoCallService');
        }
      }

      await leaveChannel();
    } catch (e) {
      ReleaseLogger.error('❌ Error terminando llamada: $e', tag: 'VideoCallService');
    }
  }

  /// Escuchar llamadas entrantes para un usuario
  /// Detecta tanto llamadas 1-a-1 (receiverId) como grupales (participants array)
  Stream<QuerySnapshot> watchIncomingCalls(String userId) {
    ReleaseLogger.log('🔍 [watchIncomingCalls] Iniciando listener para userId: $userId', tag: 'VideoCallService');

    // Para llamadas grupales, necesitamos buscar en el array participants
    // donde cada elemento es un objeto con userId y status
    // Usamos un query compuesto para buscar llamadas grupales donde el usuario esté en estado 'ringing'

    return _firestore
        .collection('video_calls')
        .where(Filter.or(
          // Llamadas directas (1-a-1)
          Filter.and(
            Filter('receiverId', isEqualTo: userId),
            Filter('status', isEqualTo: 'ringing'),
          ),
          // Llamadas grupales (buscar en participants)
          Filter.and(
            Filter('isGroupCall', isEqualTo: true),
            Filter('status', isEqualTo: 'ringing'),
            // Note: No podemos filtrar directamente por participants.userId en Firestore
            // Tendremos que filtrar en el cliente
          ),
        ))
        .snapshots()
        .map((snapshot) {
          // Filtrar llamadas grupales en el cliente para verificar si el usuario está en participants
          final filteredDocs = snapshot.docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;

            // Si es llamada directa, ya está filtrada por el query
            if (data['isGroupCall'] != true) {
              return true;
            }

            // Si es llamada grupal, verificar si el usuario está en participants con status ringing
            final participants = data['participants'] as List<dynamic>?;
            if (participants == null) return false;

            return participants.any((participant) {
              if (participant is Map<String, dynamic>) {
                return participant['userId'] == userId && participant['status'] == 'ringing';
              }
              return false;
            });
          }).toList();

          // Crear un nuevo QuerySnapshot simulado con los documentos filtrados
          return _MockQuerySnapshot(filteredDocs);
        });
  }

  /// Escuchar el estado de una llamada específica
  Stream<DocumentSnapshot> watchCallStatus(String callId) {
    return _firestore.collection('video_calls').doc(callId).snapshots();
  }

  // ============================================
  // Método consolidado para iniciar llamadas
  // ============================================

  /// Iniciar llamada (video o audio) con autenticación, tokens y manejo de errores
  ///
  /// Retorna un Map con:
  /// - 'success': bool
  /// - 'channelName': String (si success = true)
  /// - 'token': String (si success = true)
  /// - 'uid': int (si success = true)
  /// - 'error': String (si success = false)
  Future<Map<String, dynamic>> initiateCall({
    required String receiverId,
    required String receiverName,
    required bool isVideo,
  }) async {
    try {
      // 1. Verificar autenticación
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return {
          'success': false,
          'error':
              'Usuario no autenticado. Por favor, vuelve a iniciar sesión.',
        };
      }

      final currentUserId = currentUser.uid;
      final callType = isVideo ? 'videollamada' : 'llamada de audio';
      ReleaseLogger.log('🚀 Iniciando $callType desde caller: $currentUserId', tag: 'VideoCallService');
      ReleaseLogger.log('🔐 Usuario autenticado: ${currentUser.email ?? currentUser.phoneNumber}', tag: 'VideoCallService');

      // 2. Verificar token de Firebase Auth
      try {
        await currentUser.getIdToken(true); // Force refresh
        ReleaseLogger.log('✅ Firebase Auth token obtenido y actualizado', tag: 'VideoCallService');
      } catch (tokenError) {
        ReleaseLogger.error('⚠️ Error obteniendo Firebase Auth token: $tokenError', tag: 'VideoCallService');
        return {
          'success': false,
          'error':
              'Error de autenticación. Por favor, vuelve a iniciar sesión.',
        };
      }

      // 2.5. Verificar si el usuario está bloqueado o bloqueó al receptor
      try {
        final isBlocked = await _blockService.isBlocked(receiverId);
        final isBlockedBy = await _blockService.isBlockedBy(receiverId);

        if (isBlocked) {
          ReleaseLogger.log('🚫 El usuario ha bloqueado a $receiverName', tag: 'VideoCallService');
          return {
            'success': false,
            'error':
                'No puedes llamar a este contacto porque lo has bloqueado.',
          };
        }

        if (isBlockedBy) {
          ReleaseLogger.log('🚫 El usuario fue bloqueado por $receiverName', tag: 'VideoCallService');
          return {
            'success': false,
            'error': 'No puedes llamar a este contacto en este momento.',
          };
        }

        ReleaseLogger.log('✅ Verificación de bloqueo pasada', tag: 'VideoCallService');
      } catch (blockError) {
        ReleaseLogger.error('⚠️ Error verificando bloqueo: $blockError', tag: 'VideoCallService');
        // Continuar de todos modos - no es un error crítico
      }

      // 3. Obtener nombre del usuario actual
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';
      ReleaseLogger.log('👤 Nombre del caller: $currentUserName', tag: 'VideoCallService');

      // 4. Crear la llamada y obtener el callId/channelName
      ReleaseLogger.log('📝 Creando $callType en Firestore...', tag: 'VideoCallService');
      final channelName = isVideo
          ? await startCall(
              callerId: currentUserId,
              callerName: currentUserName,
              receiverId: receiverId,
              receiverName: receiverName,
            )
          : await startAudioCall(
              callerId: currentUserId,
              callerName: currentUserName,
              receiverId: receiverId,
              receiverName: receiverName,
            );

      ReleaseLogger.log('✅ $callType creada: $channelName', tag: 'VideoCallService');

      // 5. Obtener token de App Check
      String? appCheckTokenValue;
      try {
        final appCheckToken = await FirebaseAppCheck.instance.getToken();
        appCheckTokenValue = appCheckToken;
        ReleaseLogger.log('🔐 App Check token obtenido: ${appCheckTokenValue?.substring(0, 20)}...', tag: 'VideoCallService');
      } catch (appCheckError) {
        ReleaseLogger.error('⚠️ Error obteniendo App Check token: $appCheckError', tag: 'VideoCallService');
        ReleaseLogger.error('⚠️ Tipo de error: ${appCheckError.runtimeType}', tag: 'VideoCallService');
        // Continuar de todos modos - el servidor decidirá si rechazar
      }

      // 6. Generar token de Agora usando Cloud Function
      ReleaseLogger.log('🎫 Generando token de Agora para caller...', tag: 'VideoCallService');
      ReleaseLogger.log('☁️ Llamando Cloud Function generateAgoraToken...', tag: 'VideoCallService');

      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('generateAgoraToken');

      try {
        final result = await callable.call({
          'channelName': channelName.toString().trim(),
          'uid': 0, // 0 = Agora asigna automáticamente
        });

        final token = result.data['token'] as String;
        final uid = result.data['uid'] as int;

        ReleaseLogger.log('✅ Token generado para caller exitosamente', tag: 'VideoCallService');
        ReleaseLogger.log('✅ UID asignado: $uid', tag: 'VideoCallService');

        return {
          'success': true,
          'callId': channelName, // ✅ El channelName ES el callId (doc ID de Firestore)
          'channelName': channelName,
          'token': token,
          'uid': uid,
        };
      } catch (cloudFunctionError) {
        ReleaseLogger.error('❌ Error en Cloud Function generateAgoraToken:', tag: 'VideoCallService');
        ReleaseLogger.error('   Tipo: ${cloudFunctionError.runtimeType}', tag: 'VideoCallService');
        ReleaseLogger.error('   Mensaje: $cloudFunctionError', tag: 'VideoCallService');

        String errorMessage;
        if (cloudFunctionError.toString().contains('unauthenticated')) {
          errorMessage =
              'Error de autenticación. Por favor, vuelve a iniciar sesión.';
        } else if (cloudFunctionError.toString().contains('App Check')) {
          errorMessage =
              'Error de verificación de App Check. Asegúrate de que la app esté correctamente configurada.';
        } else {
          errorMessage = 'Error generando token de Agora: $cloudFunctionError';
        }

        return {'success': false, 'error': errorMessage};
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error general iniciando ${isVideo ? 'videollamada' : 'llamada de audio'}:', tag: 'VideoCallService');
      ReleaseLogger.error('   Tipo: ${e.runtimeType}', tag: 'VideoCallService');
      ReleaseLogger.error('   Mensaje: $e', tag: 'VideoCallService');

      return {'success': false, 'error': e.toString()};
    }
  }

  // ============================================
  // Llamadas perdidas en el chat
  // ============================================

  /// Registrar una llamada perdida como mensaje en el chat
  ///
  /// Este método crea un mensaje especial en el chat entre dos usuarios
  /// para indicar que hubo una llamada perdida.
  Future<void> createMissedCallMessage({
    required String callerId,
    required String receiverId,
    required String callType, // 'video' o 'audio'
    required String callId,
  }) async {
    try {
      ReleaseLogger.log('📵 Creando mensaje de llamada perdida en el chat', tag: 'VideoCallService');

      // Obtener información del chat entre los dos usuarios
      final chatService = await import_chatService();
      final chatId = chatService.getChatId(callerId, receiverId);

      // Crear mensaje de llamada perdida en el chat
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': callerId,
            'type': 'missed_call',
            'callType': callType,
            'callId': callId,
            'text': callType == 'video'
                ? '📹 Llamada de video perdida'
                : '📞 Llamada de audio perdida',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      // Actualizar último mensaje del chat
      await _firestore.collection('chats').doc(chatId).set({
        'lastMessage': callType == 'video'
            ? '📹 Llamada de video perdida'
            : '📞 Llamada de audio perdida',
        'lastMessageSender': callerId,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'participants': [callerId, receiverId],
      }, SetOptions(merge: true));

      ReleaseLogger.log('✅ Mensaje de llamada perdida creado en el chat', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error creando mensaje de llamada perdida: $e', tag: 'VideoCallService');
      // No relanzar el error, es una operación secundaria
    }
  }

  /// Crear un mensaje de llamada contestada con duración en el chat
  Future<void> _createAnsweredCallMessage({
    required String callerId,
    required String receiverId,
    required String callType, // 'video' o 'audio'
    required String callId,
    required int durationSeconds,
  }) async {
    try {
      ReleaseLogger.log('📞 [_createAnsweredCallMessage] INICIANDO creación de mensaje', tag: 'VideoCallService');
      ReleaseLogger.log('   - CallerId: $callerId', tag: 'VideoCallService');
      ReleaseLogger.log('   - ReceiverId: $receiverId', tag: 'VideoCallService');
      ReleaseLogger.log('   - CallType: $callType', tag: 'VideoCallService');
      ReleaseLogger.log('   - Duración: ${durationSeconds}s', tag: 'VideoCallService');

      // Obtener información del chat entre los dos usuarios
      final chatService = await import_chatService();
      final chatId = chatService.getChatId(callerId, receiverId);

      ReleaseLogger.log('   - ChatId generado: $chatId', tag: 'VideoCallService');

      // Formatear duración
      final duration = _formatDuration(durationSeconds);

      // Crear mensaje de llamada contestada en el chat
      ReleaseLogger.log('   - Creando documento en chats/$chatId/messages...', tag: 'VideoCallService');
      final messageRef = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': callerId,
            'type': 'answered_call',
            'callType': callType,
            'callId': callId,
            'callDuration': durationSeconds,
            'text': callType == 'video'
                ? '📹 Videollamada • $duration'
                : '📞 Llamada • $duration',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
            'readBy': [], // Agregar campo readBy
          });

      ReleaseLogger.log('   - Mensaje creado con ID: ${messageRef.id}', tag: 'VideoCallService');

      // Actualizar último mensaje del chat
      ReleaseLogger.log('   - Actualizando último mensaje del chat...', tag: 'VideoCallService');
      await _firestore.collection('chats').doc(chatId).set({
        'lastMessage': callType == 'video'
            ? '📹 Videollamada • $duration'
            : '📞 Llamada • $duration',
        'lastMessageSender': callerId,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'participants': [callerId, receiverId],
      }, SetOptions(merge: true));

      ReleaseLogger.log('✅ Mensaje de llamada contestada creado en el chat', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error creando mensaje de llamada contestada: $e', tag: 'VideoCallService');
      // No relanzar el error, es una operación secundaria
    }
  }

  /// Crear mensaje de llamada perdida en el chat
  Future<void> _createMissedCallMessage({
    required String callerId,
    required String receiverId,
    required String callType, // 'video' o 'audio'
    required String callId,
  }) async {
    try {
      ReleaseLogger.log('📵 Creando mensaje de llamada perdida en el chat', tag: 'VideoCallService');

      // Obtener información del chat entre los dos usuarios
      final chatService = await import_chatService();
      final chatId = chatService.getChatId(callerId, receiverId);

      // Crear mensaje de llamada perdida en el chat
      ReleaseLogger.log('   - Creando mensaje de llamada perdida en chats/$chatId/messages...', tag: 'VideoCallService');
      final messageRef = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': callerId,
            'type': 'missed_call',
            'callType': callType,
            'callId': callId,
            'text': callType == 'video'
                ? '📹 Videollamada perdida'
                : '📞 Llamada perdida',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
            'readBy': [], // Agregar campo readBy
          });

      ReleaseLogger.log('   - Mensaje de llamada perdida creado con ID: ${messageRef.id}', tag: 'VideoCallService');

      // Actualizar último mensaje del chat
      await _firestore.collection('chats').doc(chatId).set({
        'lastMessage': callType == 'video'
            ? '📹 Videollamada perdida'
            : '📞 Llamada perdida',
        'lastMessageSender': callerId,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'participants': [callerId, receiverId],
      }, SetOptions(merge: true));

      ReleaseLogger.log('✅ Mensaje de llamada perdida creado en el chat', tag: 'VideoCallService');
    } catch (e) {
      ReleaseLogger.error('❌ Error creando mensaje de llamada perdida: $e', tag: 'VideoCallService');
      // No relanzar el error, es una operación secundaria
    }
  }

  /// Formatear duración en formato legible
  String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '${seconds}s';
    } else if (seconds < 3600) {
      final minutes = seconds ~/ 60;
      final secs = seconds % 60;
      return secs > 0 ? '${minutes}m ${secs}s' : '${minutes}m';
    } else {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
    }
  }

  // Helper privado para importar ChatService
  // (evita dependencia circular)
  Future<dynamic> import_chatService() async {
    // Retornar una versión inline mínima del método getChatId
    return _ChatServiceStub();
  }

  // Helper privado para importar CallKitService
  // (evita dependencia circular)
  Future<dynamic> import_callKitService() async {
    // Importar dinámicamente para evitar dependencia circular
    return CallKitService();
  }
}

// Stub minimal de ChatService para evitar dependencia circular
class _ChatServiceStub {
  String getChatId(String userId1, String userId2) {
    final sortedIds = [userId1, userId2]..sort();
    return '${sortedIds[0]}_${sortedIds[1]}';
  }
}

// Mock QuerySnapshot para manejar filtrado en cliente
class _MockQuerySnapshot implements QuerySnapshot {
  final List<QueryDocumentSnapshot> _docs;

  _MockQuerySnapshot(this._docs);

  @override
  List<QueryDocumentSnapshot> get docs => _docs;

  @override
  List<DocumentChange> get docChanges => [];

  @override
  SnapshotMetadata get metadata => MockSnapshotMetadata();

  @override
  int get size => _docs.length;
}

class MockSnapshotMetadata implements SnapshotMetadata {
  @override
  bool get hasPendingWrites => false;

  @override
  bool get isFromCache => false;
}
