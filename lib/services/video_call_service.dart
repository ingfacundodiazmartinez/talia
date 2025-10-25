import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'app_config_service.dart';
import 'block_service.dart';

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

  /// Inicializar el engine de Agora para videollamadas
  Future<void> initializeAgora() async {
    // Si ya está inicializado, liberar primero para reiniciar en modo video
    if (_isInitialized && _engine != null) {
      print('⚠️ Agora ya está inicializado, liberando para reiniciar en modo video...');
      try {
        // Detener preview y deshabilitar video/audio ANTES de liberar
        await _engine!.stopPreview();
        await _engine!.disableVideo();
        await _engine!.disableAudio();
        await _engine!.leaveChannel();
        await _engine!.release();
        print('✅ Engine anterior liberado completamente');
      } catch (e) {
        print('⚠️ Error liberando engine anterior: $e');
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
      print('🎥 Inicializando Agora...');

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
      try {
        // Detener todo ANTES de liberar
        await _engine!.stopPreview();
        await _engine!.disableVideo();
        await _engine!.disableAudio();
        await _engine!.leaveChannel();
        await _engine!.release();
        print('✅ Engine anterior liberado completamente');
      } catch (e) {
        print('⚠️ Error liberando engine anterior: $e');
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
      print('🎤 Inicializando Agora para audio...');

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

      // Generar un ID único para usar como channelName
      final docRef = _firestore.collection('video_calls').doc();
      final channelName = docRef.id;

      // Obtener photoURL del caller
      final callerDoc = await _firestore.collection('users').doc(callerId).get();
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

      print('✅ Videollamada creada: $channelName');

      // ✅ Enviar VoIP push directamente usando Cloud Function
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'sendInstantPushNotification',
          options: HttpsCallableOptions(
            timeout: const Duration(seconds: 10),
          ),
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

        print('✅ Push notification enviada: ${result.data}');

        if (result.data['sentViaVoIP'] == true) {
          print('✅ Enviado via VoIP push - CallKit se mostrará automáticamente');
        } else {
          print('✅ Enviado via FCM push');
        }
      } catch (pushError) {
        print('⚠️ Error enviando push notification: $pushError');
        // No lanzar error - la llamada ya se creó en Firestore
      }

      return channelName;
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

      // Generar un ID único para usar como channelName
      final docRef = _firestore.collection('video_calls').doc();
      final channelName = docRef.id;

      // Obtener photoURL del caller
      final callerDoc = await _firestore.collection('users').doc(callerId).get();
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

      print('✅ Llamada de audio creada: $channelName');

      // ✅ Enviar VoIP push directamente usando Cloud Function
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'sendInstantPushNotification',
          options: HttpsCallableOptions(
            timeout: const Duration(seconds: 10),
          ),
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

        print('✅ Push notification enviada: ${result.data}');

        if (result.data['sentViaVoIP'] == true) {
          print('✅ Enviado via VoIP push - CallKit se mostrará automáticamente');
        } else {
          print('✅ Enviado via FCM push');
        }
      } catch (pushError) {
        print('⚠️ Error enviando push notification: $pushError');
        // No lanzar error - la llamada ya se creó en Firestore
      }

      return channelName;
    } catch (e) {
      print('❌ Error iniciando llamada de audio: $e');
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
      print('📞 Iniciando videollamada grupal de $callerName');
      print('👥 Participantes: ${participantIds.length}');

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

      print('✅ Videollamada grupal creada: $channelName');

      // Obtener photoURL del caller
      final callerDoc = await _firestore.collection('users').doc(callerId).get();
      final callerPhotoURL = callerDoc.data()?['photoURL'] ?? '';

      // ✅ Enviar VoIP push a todos los participantes usando Cloud Function
      int successCount = 0;
      for (String participantId in participantIds) {
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'sendInstantPushNotification',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: 10),
            ),
          );

          final title = isEmergency ? '🚨 Llamada de emergencia' : 'Videollamada grupal';
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
              'isGroupCall': 'true',
              'isEmergency': isEmergency.toString(),
              'groupId': groupId ?? '',
              'senderPhotoUrl': callerPhotoURL,
            },
          });

          if (result.data['success'] == true) {
            successCount++;
            if (result.data['sentViaVoIP'] == true) {
              print('✅ VoIP push enviado a participante $participantId');
            } else {
              print('✅ FCM push enviado a participante $participantId');
            }
          }
        } catch (pushError) {
          print('⚠️ Error enviando push a participante $participantId: $pushError');
          // Continuar con los demás participantes
        }
      }

      print('✅ Notificaciones enviadas a $successCount/${participantIds.length} participantes');
      return channelName;
    } catch (e) {
      print('❌ Error iniciando videollamada grupal: $e');
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
      print('📞 Iniciando llamada de audio grupal de $callerName');
      print('👥 Participantes: ${participantIds.length}');

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

      print('✅ Llamada de audio grupal creada: $channelName');

      // Obtener photoURL del caller
      final callerDoc = await _firestore.collection('users').doc(callerId).get();
      final callerPhotoURL = callerDoc.data()?['photoURL'] ?? '';

      // ✅ Enviar VoIP push a todos los participantes usando Cloud Function
      int successCount = 0;
      for (String participantId in participantIds) {
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'sendInstantPushNotification',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: 10),
            ),
          );

          final title = isEmergency ? '🚨 Llamada de emergencia' : 'Llamada grupal';
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
              'isGroupCall': 'true',
              'isEmergency': isEmergency.toString(),
              'groupId': groupId ?? '',
              'senderPhotoUrl': callerPhotoURL,
            },
          });

          if (result.data['success'] == true) {
            successCount++;
            if (result.data['sentViaVoIP'] == true) {
              print('✅ VoIP push enviado a participante $participantId');
            } else {
              print('✅ FCM push enviado a participante $participantId');
            }
          }
        } catch (pushError) {
          print('⚠️ Error enviando push a participante $participantId: $pushError');
          // Continuar con los demás participantes
        }
      }

      print('✅ Notificaciones enviadas a $successCount/${participantIds.length} participantes');
      return channelName;
    } catch (e) {
      print('❌ Error iniciando llamada de audio grupal: $e');
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
      print('📝 Actualizando estado de participante $userId a: $status');

      final callDoc = await _firestore.collection('video_calls').doc(callId).get();
      if (!callDoc.exists) {
        print('⚠️ Llamada no encontrada: $callId');
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
        print('⚠️ Participante no encontrado en la llamada');
        return;
      }

      // Actualizar documento
      await _firestore.collection('video_calls').doc(callId).update({
        'participants': participants,
      });

      // Si alguien se unió, cambiar estado de llamada a 'active'
      if (status == 'joined' && callData['status'] == 'ringing') {
        await _firestore.collection('video_calls').doc(callId).update({
          'status': 'active',
        });
      }

      // Si todos salieron, terminar la llamada
      bool allLeft = participants.every((p) => p['status'] == 'left' || p['status'] == 'declined');
      if (allLeft) {
        await _firestore.collection('video_calls').doc(callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });
      }

      print('✅ Estado de participante actualizado');
    } catch (e) {
      print('❌ Error actualizando estado de participante: $e');
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
      print('📞 Invitando a $invitedUserName a la llamada $callId');

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return {
          'success': false,
          'error': 'Usuario no autenticado',
        };
      }

      // 1. Obtener documento de la llamada actual
      final callDoc = await _firestore.collection('video_calls').doc(callId).get();
      if (!callDoc.exists) {
        return {
          'success': false,
          'error': 'Llamada no encontrada',
        };
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
        print('🔄 Convirtiendo llamada 1:1 a grupal...');

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
        print('➕ Agregando participante a llamada grupal existente...');

        List<dynamic> participants = callData['participants'] ?? [];

        // Verificar que no esté ya en la llamada
        bool alreadyInCall = participants.any((p) => p['userId'] == invitedUserId);
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
          options: HttpsCallableOptions(
            timeout: const Duration(seconds: 10),
          ),
        );

        final title = callType == 'video' ? 'Videollamada grupal' : 'Llamada grupal';
        final body = '$inviterName te invitó a unirte a la llamada';

        final result = await callable.call({
          'receiverId': invitedUserId,
          'title': title,
          'body': body,
          'isCall': true,
          'data': {
            'type': callType == 'video' ? 'group_video_call' : 'group_audio_call',
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
          print('✅ VoIP push enviado al usuario invitado');
        } else {
          print('✅ FCM push enviado al usuario invitado');
        }
      } catch (pushError) {
        print('⚠️ Error enviando push al usuario invitado: $pushError');
        // No lanzar error - la invitación ya se agregó a Firestore
      }

      print('✅ Usuario invitado exitosamente a la llamada');

      return {
        'success': true,
      };
    } catch (e) {
      print('❌ Error invitando a usuario a la llamada: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Escuchar llamadas grupales entrantes para un usuario
  Stream<QuerySnapshot> watchIncomingGroupCalls(String userId) {
    return _firestore
        .collection('video_calls')
        .where('participants', arrayContains: {
          'userId': userId,
          'status': 'ringing',
        })
        .snapshots();
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

      // Obtener datos de la llamada antes de terminarla
      final callDoc = await _firestore.collection('video_calls').doc(callId).get();
      final callData = callDoc.data();

      if (callData != null) {
        final startedAt = callData['startedAt'] as Timestamp?;
        final status = callData['status'] as String?;

        // Actualizar status a ended
        await _firestore.collection('video_calls').doc(callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });

        // Si la llamada fue contestada (tiene startedAt), crear mensaje de historial
        if (startedAt != null && status == 'active') {
          final endedAt = DateTime.now();
          final startTime = startedAt.toDate();
          final durationSeconds = endedAt.difference(startTime).inSeconds;

          await _createAnsweredCallMessage(
            callerId: callData['callerId'] ?? '',
            receiverId: callData['receiverId'] ?? '',
            callType: callData['callType'] ?? 'video',
            callId: callId,
            durationSeconds: durationSeconds,
          );
        }
      } else {
        // Si no hay datos, solo actualizar status
        await _firestore.collection('video_calls').doc(callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });
      }

      await leaveChannel();
    } catch (e) {
      print('❌ Error terminando llamada: $e');
    }
  }

  /// Escuchar llamadas entrantes para un usuario
  /// Detecta tanto llamadas 1-a-1 (receiverId) como grupales (participantIds)
  Stream<QuerySnapshot> watchIncomingCalls(String userId) {
    print('🔍 [watchIncomingCalls] Iniciando listener para userId: $userId');

    // Crear un StreamController para combinar ambos streams
    final controller = StreamController<QuerySnapshot>.broadcast();

    // Stream para llamadas directas (1-a-1)
    print('🔍 [watchIncomingCalls] Configurando stream de llamadas directas...');
    final directCallsStream = _firestore
        .collection('video_calls')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'ringing')
        .snapshots();

    // Stream para llamadas grupales (emergencias, grupos)
    print('🔍 [watchIncomingCalls] Configurando stream de llamadas grupales...');
    final groupCallsStream = _firestore
        .collection('video_calls')
        .where('participantIds', arrayContains: userId)
        .where('status', isEqualTo: 'ringing')
        .snapshots();

    // Escuchar ambos streams y emitir cuando cualquiera cambie
    print('🔍 [watchIncomingCalls] Iniciando listen() para directCallsStream...');
    directCallsStream.listen(
      (snapshot) {
        print('📞 [watchIncomingCalls] Llamadas directas: ${snapshot.docs.length}');
        if (snapshot.docs.isNotEmpty) {
          print('📞 [watchIncomingCalls] Documentos directos:');
          for (var doc in snapshot.docs) {
            print('   - ${doc.id}: ${doc.data()}');
          }
        }
        controller.add(snapshot);
      },
      onError: (error) {
        print('❌ [watchIncomingCalls] Error en directCallsStream: $error');
        controller.addError(error);
      },
    );

    print('🔍 [watchIncomingCalls] Iniciando listen() para groupCallsStream...');
    groupCallsStream.listen(
      (snapshot) {
        print('📞 [watchIncomingCalls] Llamadas grupales: ${snapshot.docs.length}');
        if (snapshot.docs.isNotEmpty) {
          print('📞 [watchIncomingCalls] Documentos grupales:');
          for (var doc in snapshot.docs) {
            final data = doc.data();
            print('   - ${doc.id}');
            print('     status: ${data['status']}');
            print('     participantIds: ${data['participantIds']}');
            print('     callerName: ${data['callerName']}');
          }
        }
        controller.add(snapshot);
      },
      onError: (error) {
        print('❌ [watchIncomingCalls] Error en groupCallsStream: $error');
        controller.addError(error);
      },
    );

    print('🔍 [watchIncomingCalls] Listeners configurados, retornando controller.stream');
    return controller.stream;
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
          'error': 'Usuario no autenticado. Por favor, vuelve a iniciar sesión.',
        };
      }

      final currentUserId = currentUser.uid;
      final callType = isVideo ? 'videollamada' : 'llamada de audio';
      print('🚀 Iniciando $callType desde caller: $currentUserId');
      print('🔐 Usuario autenticado: ${currentUser.email ?? currentUser.phoneNumber}');

      // 2. Verificar token de Firebase Auth
      try {
        await currentUser.getIdToken(true); // Force refresh
        print('✅ Firebase Auth token obtenido y actualizado');
      } catch (tokenError) {
        print('⚠️ Error obteniendo Firebase Auth token: $tokenError');
        return {
          'success': false,
          'error': 'Error de autenticación. Por favor, vuelve a iniciar sesión.',
        };
      }

      // 2.5. Verificar si el usuario está bloqueado o bloqueó al receptor
      try {
        final isBlocked = await _blockService.isBlocked(receiverId);
        final isBlockedBy = await _blockService.isBlockedBy(receiverId);

        if (isBlocked) {
          print('🚫 El usuario ha bloqueado a $receiverName');
          return {
            'success': false,
            'error': 'No puedes llamar a este contacto porque lo has bloqueado.',
          };
        }

        if (isBlockedBy) {
          print('🚫 El usuario fue bloqueado por $receiverName');
          return {
            'success': false,
            'error': 'No puedes llamar a este contacto en este momento.',
          };
        }

        print('✅ Verificación de bloqueo pasada');
      } catch (blockError) {
        print('⚠️ Error verificando bloqueo: $blockError');
        // Continuar de todos modos - no es un error crítico
      }

      // 3. Obtener nombre del usuario actual
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';
      print('👤 Nombre del caller: $currentUserName');

      // 4. Crear la llamada y obtener el callId/channelName
      print('📝 Creando $callType en Firestore...');
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

      print('✅ $callType creada: $channelName');

      // 5. Obtener token de App Check
      String? appCheckTokenValue;
      try {
        final appCheckToken = await FirebaseAppCheck.instance.getToken();
        appCheckTokenValue = appCheckToken;
        print('🔐 App Check token obtenido: ${appCheckTokenValue?.substring(0, 20)}...');
      } catch (appCheckError) {
        print('⚠️ Error obteniendo App Check token: $appCheckError');
        print('⚠️ Tipo de error: ${appCheckError.runtimeType}');
        // Continuar de todos modos - el servidor decidirá si rechazar
      }

      // 6. Generar token de Agora usando Cloud Function
      print('🎫 Generando token de Agora para caller...');
      print('☁️ Llamando Cloud Function generateAgoraToken...');

      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('generateAgoraToken');

      try {
        final result = await callable.call({
          'channelName': channelName.toString().trim(),
          'uid': 0, // 0 = Agora asigna automáticamente
        });

        final token = result.data['token'] as String;
        final uid = result.data['uid'] as int;

        print('✅ Token generado para caller exitosamente');
        print('✅ UID asignado: $uid');

        return {
          'success': true,
          'channelName': channelName,
          'token': token,
          'uid': uid,
        };
      } catch (cloudFunctionError) {
        print('❌ Error en Cloud Function generateAgoraToken:');
        print('   Tipo: ${cloudFunctionError.runtimeType}');
        print('   Mensaje: $cloudFunctionError');

        String errorMessage;
        if (cloudFunctionError.toString().contains('unauthenticated')) {
          errorMessage = 'Error de autenticación. Por favor, vuelve a iniciar sesión.';
        } else if (cloudFunctionError.toString().contains('App Check')) {
          errorMessage = 'Error de verificación de App Check. Asegúrate de que la app esté correctamente configurada.';
        } else {
          errorMessage = 'Error generando token de Agora: $cloudFunctionError';
        }

        return {
          'success': false,
          'error': errorMessage,
        };
      }
    } catch (e) {
      print('❌ Error general iniciando ${ isVideo ? 'videollamada' : 'llamada de audio'}:');
      print('   Tipo: ${e.runtimeType}');
      print('   Mensaje: $e');

      return {
        'success': false,
        'error': e.toString(),
      };
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
      print('📵 Creando mensaje de llamada perdida en el chat');

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

      print('✅ Mensaje de llamada perdida creado en el chat');
    } catch (e) {
      print('❌ Error creando mensaje de llamada perdida: $e');
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
      print('📞 Creando mensaje de llamada contestada en el chat (${durationSeconds}s)');

      // Obtener información del chat entre los dos usuarios
      final chatService = await import_chatService();
      final chatId = chatService.getChatId(callerId, receiverId);

      // Formatear duración
      final duration = _formatDuration(durationSeconds);

      // Crear mensaje de llamada contestada en el chat
      await _firestore
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
      });

      // Actualizar último mensaje del chat
      await _firestore.collection('chats').doc(chatId).set({
        'lastMessage': callType == 'video'
            ? '📹 Videollamada • $duration'
            : '📞 Llamada • $duration',
        'lastMessageSender': callerId,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'participants': [callerId, receiverId],
      }, SetOptions(merge: true));

      print('✅ Mensaje de llamada contestada creado en el chat');
    } catch (e) {
      print('❌ Error creando mensaje de llamada contestada: $e');
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
}

// Stub minimal de ChatService para evitar dependencia circular
class _ChatServiceStub {
  String getChatId(String userId1, String userId2) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sortedIds = [userId1, userId2]..sort();
    return '${timestamp}_${sortedIds[0]}_${sortedIds[1]}';
  }
}
