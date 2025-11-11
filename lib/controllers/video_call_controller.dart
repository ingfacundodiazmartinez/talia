import 'dart:async';
import 'dart:io';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import '../services/video_call_service.dart';
import '../services/voip_service.dart';
import '../services/callkit_service.dart';
import '../services/app_config_service.dart';
import '../services/permission_service.dart';
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
  String? channelName; // ✅ Mutable: se genera automáticamente si no se proporciona
  String? token;       // ✅ Mutable: se genera automáticamente si no se proporciona
  int? uid;           // ✅ Mutable: se asigna automáticamente si no se proporciona
  final bool isCaller;
  final String remoteName;
  final String receiverId;
  final bool isVideo;

  // Servicios privados
  final VideoCallService _videoCallService;
  final VoIPService _voipService;
  final CallKitService _callKitService;
  final AppConfigService _appConfig;
  final PermissionService _permissionService;
  final firebase_auth.FirebaseAuth _auth;

  // Estado de la llamada
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isJoined = false;
  int? _localUid;
  final Set<int> _remoteUids = {};
  String _connectionStatus = 'Conectando...';
  bool _isEnding = false;
  bool _hasPermissions = false;

  // ✅ CALLID_FIX: Almacenar el callId real de Firestore
  String? _realCallId;

  // Agora Engine
  RtcEngine? _engine;

  // Timers y listeners
  Timer? _connectionTimer;
  Timer? _reconnectionTimer; // ✅ Timer para timeout de reconexión (30s)
  StreamSubscription? _callStateSubscription;

  // Control de terminación de llamadas para evitar race conditions
  DateTime? _callStartTime;

  // Callbacks para comunicación con el screen
  Function(String)? onConnectionStatusChanged;
  Function(Set<int>)? onRemoteUsersChanged;
  Function(bool)? onLocalUserJoined;
  Function(String)? onError;
  Function()? onCallEnded;
  Function()? onStateChanged; // Callback para cambios de estado UI
  // Function()? onPermissionDenied; // ❌ ELIMINADO: Ya no validamos permisos previos

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
    AppConfigService? appConfig,
    PermissionService? permissionService,
    firebase_auth.FirebaseAuth? auth,
  }) : _videoCallService = videoCallService ?? VideoCallService(),
       _voipService = voipService ?? VoIPService(),
       _callKitService = callKitService ?? CallKitService(),
       _appConfig = appConfig ?? AppConfigService(),
       _permissionService = permissionService ?? PermissionService(),
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
  Future<void> initialize({BuildContext? context}) async {
    try {
      // ✅ CALLID_FIX: Inicializar _realCallId con el callId original
      _realCallId ??= callId;

      ReleaseLogger.log('🔧 [CONTROLLER_DEBUG] Inicializando VideoCallController...', tag: 'VideoCall');
      ReleaseLogger.log('🔧 [CONTROLLER_DEBUG] isCaller: $isCaller', tag: 'VideoCall');

      await _appConfig.initialize();
      ReleaseLogger.log('✅ AppConfigService inicializado', tag: 'VideoCall');

      // 🚫 REMOVED: La llamada ya fue creada en ContactProfileScreen/GroupChatScreen
      // No necesitamos crearla de nuevo aquí para evitar notificaciones duplicadas
      if (isCaller) {
        ReleaseLogger.log('📞 [CONTROLLER_DEBUG] Es caller - llamada ya creada previamente', tag: 'VideoCall');
      } else {
        ReleaseLogger.log('📱 [CONTROLLER_DEBUG] Es receiver - conectando a Agora...', tag: 'VideoCall');
      }

      // Generar token si no se proporcionó
      if (token == null || token!.isEmpty) {
        await _generateMissingTokenAndCredentials();
      }

      // ✅ ANDROID CAMERA PERMISSION: Verificar permisos de cámara antes de inicializar
      await _checkCameraPermissions(context);

      await _initializeAgoraEngine();
      _setupCallStateListener();
      await _joinChannel();
    } catch (e) {
      ReleaseLogger.error('Error inicializando VideoCallController: $e', tag: 'VideoCall');
      onError?.call('Error inicializando llamada: $e');
    }
  }

  /// Generar token y credenciales cuando no se proporcionan
  /// Esto permite que VideoCallScreen se abra sin pasar token/uid/channelName
  Future<void> _generateMissingTokenAndCredentials() async {
    try {
      final channelToUse = channelName ?? callId;
      final tokenResult = await _videoCallService.generateAgoraToken(channelToUse, uid: uid ?? 0);

      if (!tokenResult['success']) {
        throw Exception('Error generando token: ${tokenResult['error']}');
      }

      token = tokenResult['token'] as String;
      uid = tokenResult['uid'] as int;
      channelName = channelToUse;
    } catch (e) {
      ReleaseLogger.error('Error generando token automático: $e', tag: 'VideoCall');
      throw Exception('No se pudo generar token automáticamente: $e');
    }
  }

  /// ✅ ANDROID CAMERA PERMISSION: Verificar y solicitar permisos de cámara (solo Android)
  ///
  /// Sigue el mismo patrón que story_camera_controller.dart para consistencia
  /// Solo se ejecuta en Android y solo para videollamadas
  Future<void> _checkCameraPermissions(BuildContext? context) async {
    _hasPermissions = true; // Valor por defecto para iOS y audio calls

    // ✅ SOLO ANDROID: Los permisos se gestionan manualmente
    if (Platform.isAndroid && isVideo) {
      ReleaseLogger.log('🤖 Android: Verificando permisos de cámara para videollamada...', tag: 'VideoCallController');

      try {
        final currentStatus = await _permissionService.checkStatus(AppPermission.camera);
        PermissionResult permissionResult;

        if (currentStatus == PermissionResult.granted || currentStatus == PermissionResult.limited) {
          permissionResult = currentStatus;
        } else if (context != null) {
          // ✅ FIX: Verificar que el context sigue montado después del await
          if (!context.mounted) {
            ReleaseLogger.log('⚠️ Android: Context ya no está montado, usando estado actual de permisos', tag: 'VideoCallController');
            permissionResult = currentStatus;
          } else {
            permissionResult = await _permissionService.request(
              AppPermission.camera,
              context: context,
              showRationale: true, // En Android sí mostrar rationale
            );
          }
        } else {
          // Si no hay context, usar el estado actual sin solicitar
          permissionResult = currentStatus;
          ReleaseLogger.log('⚠️ Android: No se puede solicitar permiso sin BuildContext', tag: 'VideoCallController');
        }

        switch (permissionResult) {
          case PermissionResult.granted:
          case PermissionResult.limited:
            _hasPermissions = true;
            ReleaseLogger.log('✅ Android: Permisos de cámara concedidos para videollamada', tag: 'VideoCallController');
            break;
          case PermissionResult.denied:
          case PermissionResult.permanentlyDenied:
          case PermissionResult.restricted:
            _hasPermissions = false;
            ReleaseLogger.log('❌ Android: Permisos de cámara denegados para videollamada', tag: 'VideoCallController');
            throw Exception('Permisos de cámara requeridos para videollamadas en Android');
          default:
            _hasPermissions = false;
            ReleaseLogger.log('❓ Android: Estado de permisos desconocido: $permissionResult', tag: 'VideoCallController');
            throw Exception('No se pudo verificar permisos de cámara');
        }
      } catch (e) {
        ReleaseLogger.error('❌ Error verificando permisos de cámara en Android: $e', tag: 'VideoCallController');
        _hasPermissions = false;
        throw Exception('Error verificando permisos de cámara: $e');
      }
    } else {
      // ✅ iOS o audio calls: Permisos gestionados automáticamente por el sistema
      if (Platform.isIOS) {
        ReleaseLogger.log('🍎 iOS: Permisos gestionados automáticamente por el sistema', tag: 'VideoCallController');
      } else {
        ReleaseLogger.log('🎤 Audio call: No se requieren permisos de cámara', tag: 'VideoCallController');
      }
    }
  }

  // ❌ MÉTODO ELIMINADO: _checkPermissions()
  //
  // PROBLEMA ANTERIOR: Este método validaba permisos ANTES de abrir la videollamada,
  // mostrando SnackBars de error y cancelando la llamada si no se tenían permisos.
  //
  // ✅ SOLUCIÓN iOS: Abrir directamente la videollamada y dejar que iOS maneje
  // automáticamente los permisos cuando el usuario toque los botones de cámara/micrófono.
  //
  // Beneficios:
  // - Experiencia UX más fluida (no más SnackBars de error)
  // - Comportamiento estándar de iOS (permisos on-demand)
  // - La videollamada siempre se abre, permisos se solicitan cuando sea necesario

  /// Inicializar Agora RTC Engine
  Future<void> _initializeAgoraEngine() async {
    // ✅ CORREGIDO: Usar AppConfigService en lugar de hardcodear App ID
    // Esto asegura que usamos el mismo App ID que VideoCallService
    final appId = _appConfig.agoraAppId;
    ReleaseLogger.log('🎯 App ID obtenido para Agora Engine: "$appId"', tag: 'VideoCall');

    _engine = createAgoraRtcEngine();

    await _engine!.initialize(RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    // Configurar callbacks
    _engine!.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          _localUid = connection.localUid;
          _isJoined = true;
          _callStartTime = DateTime.now(); // ✅ Marcar inicio efectivo de la llamada
          _updateConnectionStatus('Conectado');
          onLocalUserJoined?.call(true);
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          _remoteUids.add(remoteUid);

          // ✅ RECONEXIÓN: Cancelar timer de timeout si alguien vuelve
          if (_reconnectionTimer != null) {
            ReleaseLogger.log('🔄 [RECONNECTION] Usuario $remoteUid se reconectó, cancelando timeout', tag: 'VideoCall');
            _reconnectionTimer?.cancel();
            _reconnectionTimer = null;
          }

          // ✅ REMOTE VIDEO FIX: Configurar vista de video remoto cuando user se une
          if (isVideo) {
            _setupRemoteVideo(remoteUid);
          }

          onRemoteUsersChanged?.call(_remoteUids);
          _updateConnectionStatus('En llamada');
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          // ✅ REMOTE VIDEO CLEANUP: Limpiar configuración de video remoto
          if (isVideo) {
            _cleanupRemoteVideo(remoteUid);
          }

          _remoteUids.remove(remoteUid);

          // ✅ CORRECTO: Solo actualizar UI, NUNCA terminar llamada automáticamente
          onRemoteUsersChanged?.call(_remoteUids);

          // ✅ NUEVA LÓGICA: Manejo inteligente de desconexiones por casos de uso
          if (!_isEnding) {
            final activeParticipants = _remoteUids.length + 1; // +1 por mí mismo
            ReleaseLogger.log('👥 [PARTICIPANTS] Participantes activos restantes: $activeParticipants', tag: 'VideoCall');
            ReleaseLogger.log('🔌 [DISCONNECT] Usuario $remoteUid se desconectó. Razón: $reason', tag: 'VideoCall');

            if (reason == UserOfflineReasonType.userOfflineQuit) {
              // 🚫 TERMINACIÓN INTENCIONAL: Evaluar inmediatamente si terminar llamada
              ReleaseLogger.log('❌ [QUIT] Usuario terminó la llamada intencionalmente', tag: 'VideoCall');
              _evaluateCallTermination(isManualHangup: true); // Es terminación manual del otro usuario
            } else if (reason == UserOfflineReasonType.userOfflineDropped) {
              // 📡 PÉRDIDA DE CONEXIÓN: Dar 30 segundos para reconexión
              ReleaseLogger.log('📡 [DROPPED] Usuario perdió conexión, iniciando timeout de 30s', tag: 'VideoCall');
              _startReconnectionTimeout(remoteUid);
            }

            // Actualizar status de UI
            if (_remoteUids.isEmpty) {
              _updateConnectionStatus('Reconectando...');
            } else {
              _updateConnectionStatus('En llamada');
            }
          }

          // ❌ ELIMINADO: NO terminar llamada por desconexiones temporales
          // Las llamadas SOLO se terminan por:
          // 1. Timeout inicial (nadie responde)
          // 2. Usuario presiona "colgar"
          // 3. Listener Firestore detecta status='ended'
        },
        // ✅ CRÍTICO: Handler para cambios en video remoto
        onRemoteVideoStateChanged: (RtcConnection connection, int remoteUid, RemoteVideoState state, RemoteVideoStateReason reason, int elapsed) {
          // Notificar cambios para forzar rebuild de UI
          onRemoteUsersChanged?.call(_remoteUids);
        },
        // ✅ CRÍTICO: Handler para cambios en audio remoto (para debug completo)
        onRemoteAudioStateChanged: (RtcConnection connection, int remoteUid, RemoteAudioState state, RemoteAudioStateReason reason, int elapsed) {
          // Audio state changes are handled internally by Agora
        },
        onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {

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
              ReleaseLogger.error('❌ [VideoCallController] CONEXIÓN FALLÓ - Razón específica: $reason', tag: 'VideoCall');
              ReleaseLogger.error('📋 [VideoCallController] Detalles del error:', tag: 'VideoCall');
              ReleaseLogger.error('  - Channel: ${connection.channelId}', tag: 'VideoCall');
              ReleaseLogger.error('  - Local UID: ${connection.localUid}', tag: 'VideoCall');
              ReleaseLogger.error('  - App ID usado: ${_appConfig.agoraAppId}', tag: 'VideoCall');
              ReleaseLogger.error('  - Token presente: ${token != null && token!.isNotEmpty}', tag: 'VideoCall');

              // Mensajes de error más específicos basados en la razón
              String errorMessage = 'Error de conexión';
              switch (reason) {
                case ConnectionChangedReasonType.connectionChangedInvalidAppId:
                  errorMessage = 'App ID inválido. Verifica la configuración.';
                  break;
                case ConnectionChangedReasonType.connectionChangedInvalidChannelName:
                  errorMessage = 'Nombre de canal inválido.';
                  break;
                case ConnectionChangedReasonType.connectionChangedInvalidToken:
                  errorMessage = 'Token de acceso inválido o expirado.';
                  break;
                case ConnectionChangedReasonType.connectionChangedTokenExpired:
                  errorMessage = 'Token de acceso expirado.';
                  break;
                case ConnectionChangedReasonType.connectionChangedRejectedByServer:
                  errorMessage = 'Conexión rechazada por el servidor.';
                  break;
                case ConnectionChangedReasonType.connectionChangedSettingProxyServer:
                  errorMessage = 'Error configurando servidor proxy.';
                  break;
                case ConnectionChangedReasonType.connectionChangedRenewToken:
                  errorMessage = 'Es necesario renovar el token.';
                  break;
                case ConnectionChangedReasonType.connectionChangedClientIpAddressChanged:
                  errorMessage = 'Cambio de IP del cliente.';
                  break;
                case ConnectionChangedReasonType.connectionChangedKeepAliveTimeout:
                  errorMessage = 'Timeout de conexión. Verifica tu internet.';
                  break;
                default:
                  errorMessage = 'Error de conexión. Verifica tu internet.';
                  break;
              }

              onError?.call(errorMessage);
              break;
            default:
              break;
          }
        },
        onError: (ErrorCodeType err, String msg) {
          ReleaseLogger.error('❌ [VideoCallController] Error de Agora: $err - $msg', tag: 'VideoCall');
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

  /// ✅ REMOTE VIDEO FIX: Configurar video remoto cuando user se une al canal
  Future<void> _setupRemoteVideo(int remoteUid) async {
    try {
      // ✅ Asegurar que el video remoto esté habilitado
      // Esto es crucial para que se renderice correctamente en AgoraVideoView
      await _engine!.muteRemoteVideoStream(uid: remoteUid, mute: false);

      // ✅ OPCIONAL: Configurar modo de renderizado
      await _engine!.setRemoteVideoStreamType(uid: remoteUid, streamType: VideoStreamType.videoStreamHigh);

    } catch (error) {
      ReleaseLogger.error('Error configurando video remoto para UID $remoteUid: $error', tag: 'VideoCall');
    }
  }

  /// ✅ REMOTE VIDEO CLEANUP: Limpiar video remoto cuando user se desconecta
  Future<void> _cleanupRemoteVideo(int remoteUid) async {
    try {
      // ✅ Opcional: Silenciar video remoto para liberar recursos
      await _engine!.muteRemoteVideoStream(uid: remoteUid, mute: true);

    } catch (error) {
      ReleaseLogger.error('Error limpiando video remoto para UID $remoteUid: $error', tag: 'VideoCall');
    }
  }

  /// Configurar listener del estado de llamada en Firestore
  void _setupCallStateListener() {
    // ✅ CALLID_FIX: Usar el callId real de Firestore si está disponible
    final actualCallId = _realCallId ?? callId;
    ReleaseLogger.log('🎯 [SYNC_DEBUG] Configurando listener de Firestore para callId: $actualCallId', tag: 'VideoCall');

    _callStateSubscription = FirebaseFirestore.instance
        .collection('video_calls')
        .doc(actualCallId)
        .snapshots()
        .listen((snapshot) {
      ReleaseLogger.log('🔍 [SYNC_DEBUG] Listener de Firestore ejecutado', tag: 'VideoCall');
      ReleaseLogger.log('🔍 [SYNC_DEBUG] snapshot.exists: ${snapshot.exists}', tag: 'VideoCall');

      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>;
        final status = data['status'] as String?;

        ReleaseLogger.log('🔍 [SYNC_DEBUG] Estado actual: "$status"', tag: 'VideoCall');
        ReleaseLogger.log('🔍 [SYNC_DEBUG] _isEnding: $_isEnding', tag: 'VideoCall');

        switch (status) {
          case 'ended':
          case 'cancelled':
            ReleaseLogger.log('🚨 [SYNC_DEBUG] Estado ENDED/CANCELLED detectado!', tag: 'VideoCall');

            // ✅ SYNC IMPROVEMENT: Validar que el estado es consistente
            if (!_isEnding && _isJoined) {
              ReleaseLogger.log('✅ [SYNC_DEBUG] Estado válido para terminación - llamando _endCall()', tag: 'VideoCall');
              _endCall();
            } else if (_isEnding) {
              ReleaseLogger.log('⚠️ [SYNC_DEBUG] Ya estamos terminando - ignorando cambio de Firestore', tag: 'VideoCall');
            } else if (!_isJoined) {
              ReleaseLogger.log('🔍 [SYNC_DEBUG] No estamos unidos al canal - posible llamada perdida o cancelada antes de conectar', tag: 'VideoCall');
              _endCall();
            }
            break;
          case 'accepted':
            ReleaseLogger.log('📞 [SYNC_DEBUG] Estado ACCEPTED detectado', tag: 'VideoCall');

            // ✅ SYNC IMPROVEMENT: Solo actualizar status si estamos conectados
            if (_isJoined || _callStartTime != null) {
              _updateConnectionStatus('En llamada');
            } else {
              _updateConnectionStatus('Conectando...');
            }
            break;
          case 'ringing':
            ReleaseLogger.log('📱 [SYNC_DEBUG] Estado RINGING detectado', tag: 'VideoCall');
            if (!_isJoined) {
              _updateConnectionStatus('Llamando...');
            }
            break;
          default:
            ReleaseLogger.log('ℹ️ [SYNC_DEBUG] Estado no manejado: "$status"', tag: 'VideoCall');
            break;
        }
      } else {
        ReleaseLogger.log('❌ [SYNC_DEBUG] Documento no existe - llamada eliminada?', tag: 'VideoCall');
        if (!_isEnding) {
          ReleaseLogger.log('✅ [SYNC_DEBUG] Documento eliminado - terminando llamada', tag: 'VideoCall');
          _endCall();
        }
      }
    });
  }

  /// Unirse al canal de Agora
  Future<void> _joinChannel() async {
    if (_engine == null) {
      throw Exception('Agora Engine no inicializado');
    }

    // ✅ VALIDACIÓN: Evitar doble conexión (Error -17)
    if (_isJoined) {
      ReleaseLogger.log('⚠️ [AGORA_FIX] Ya estamos unidos al canal - evitando doble join', tag: 'VideoCall');
      return;
    }

    final options = ChannelMediaOptions(
      clientRoleType: ClientRoleType.clientRoleBroadcaster,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    );

    try {
      final finalChannelId = channelName ?? callId;
      final finalUid = uid ?? 0;
      final finalToken = token ?? '';

      if (finalToken.isEmpty) {
        throw Exception('Token vacío detectado en VideoCallController - no se puede unir al canal');
      }

      // ✅ AGORA FIX: Limpiar cualquier conexión previa para evitar Error -17
      try {
        await _engine!.leaveChannel();
        ReleaseLogger.log('🧹 [AGORA_FIX] Canal limpiado antes de nueva conexión', tag: 'VideoCall');
      } catch (e) {
        // Ignorar errores de leaveChannel si no estaba conectado
        ReleaseLogger.log('ℹ️ [AGORA_FIX] No había conexión previa que limpiar', tag: 'VideoCall');
      }

      // ✅ ANDROID CAMERA FIX: Habilitar cámara ANTES de unirse al canal
      if (isVideo && Platform.isAndroid) {
        ReleaseLogger.log('📹 [ANDROID_CAMERA_FIX] Habilitando cámara para Android antes de join...', tag: 'VideoCall');
        await _engine!.enableVideo();
        await _engine!.muteLocalVideoStream(false); // Asegurar que la cámara esté activada
        ReleaseLogger.log('✅ [ANDROID_CAMERA_FIX] Cámara habilitada exitosamente', tag: 'VideoCall');
      }

      await _engine!.joinChannel(
        token: finalToken,
        channelId: finalChannelId,
        uid: finalUid,
        options: options,
      );

      _updateConnectionStatus('Conectando...');

      // Timer de timeout para conexión
      _connectionTimer = Timer(const Duration(seconds: 30), () {
        if (!_isJoined) {
          onError?.call('Timeout de conexión. No se pudo establecer la llamada.');
          _endCall();
        }
      });

    } catch (e) {
      ReleaseLogger.error('Error uniéndose al canal: $e', tag: 'VideoCall');
      onError?.call('Error uniéndose a la llamada: $e');
    }
  }

  /// Alternar estado del micrófono
  Future<void> toggleMute() async {
    if (_engine == null) return;

    _isMuted = !_isMuted;
    await _engine!.muteLocalAudioStream(_isMuted);

    // Notificar cambio de estado a la UI
    onStateChanged?.call();
  }

  /// Alternar estado de la cámara
  Future<void> toggleCamera() async {
    if (_engine == null || !isVideo) return;

    _isCameraOff = !_isCameraOff;
    await _engine!.muteLocalVideoStream(_isCameraOff);

    // Notificar cambio de estado a la UI
    onStateChanged?.call();
  }

  /// Cambiar cámara (frontal/trasera)
  Future<void> switchCamera() async {
    if (_engine == null || !isVideo) return;

    await _engine!.switchCamera();
  }

  /// Terminar llamada
  Future<void> endCall() async {
    if (_isEnding) return;
    _isEnding = true;

    // ReleaseLogger.log('📞 [VideoCallController] Terminando llamada...');

    try {
      // Actualizar estado en Firestore
      await _videoCallService.endCall(callId);

      // ✅ CORREGIDO: Notificar al screen ANTES del cleanup
      // El cleanup pone onCallEnded = null, así que hay que llamarlo antes
      onCallEnded?.call();

      // Limpiar recursos locales
      await _cleanup();

    } catch (e) {
      ReleaseLogger.error('Error terminando llamada: $e', tag: 'VideoCall');

      // ✅ CORREGIDO: Notificar al screen ANTES del cleanup (también en catch)
      onCallEnded?.call();

      // Forzar cleanup aunque haya error
      await _cleanup();
    }
  }

  /// Método privado para terminar llamada (llamado por listeners)
  /// ✅ SOLO limpieza local - NO actualiza Firestore para evitar bucle infinito
  Future<void> _endCall() async {
    if (_isEnding) return;
    _isEnding = true;

    ReleaseLogger.log('📞 [SYNC_FIX] Terminando llamada desde listener (solo limpieza local)', tag: 'VideoCall');

    try {
      // ✅ CALL_TERMINATION_FIX: Mostrar inmediatamente status de terminación
      // Esto previene que el usuario vea "Reconectando..." cuando la llamada está terminando
      _updateConnectionStatus('Terminando...');

      // ✅ CORRECTO: Solo notificar al screen y limpiar localmente
      // NO actualizar Firestore - eso ya se hizo en el otro dispositivo
      onCallEnded?.call();
      await _cleanup();
    } catch (e) {
      ReleaseLogger.error('Error en limpieza local de llamada: $e', tag: 'VideoCall');
      onCallEnded?.call();
      await _cleanup();
    }
  }

  /// Actualizar estado de conexión
  void _updateConnectionStatus(String status) {
    _connectionStatus = status;
    onConnectionStatusChanged?.call(status);
  }

  /// Limpiar recursos
  Future<void> _cleanup() async {

    // Cancelar timers y subscriptions
    _connectionTimer?.cancel();
    _reconnectionTimer?.cancel(); // ✅ Limpiar timer de reconexión
    _callStateSubscription?.cancel();

    // Salir del canal y destruir engine
    if (_engine != null) {
      await _engine!.leaveChannel();
      await _engine!.release();
      _engine = null;
    }

    // Limpiar estado de CallKit/VoIP si es necesario
    if (Platform.isIOS) {
      await _voipService.notifyCallEnded(callId);
    } else if (Platform.isAndroid) {
      await _callKitService.endCall(callId);
    }

    // Limpiar callbacks para evitar memory leaks
    onConnectionStatusChanged = null;
    onRemoteUsersChanged = null;
    onLocalUserJoined = null;
    onError = null;
    onCallEnded = null;
    onStateChanged = null;

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
        ReleaseLogger.log('🔧 [CALLID_FIX] CallId original: $callId', tag: 'VideoCall');

        final result = await _videoCallService.initiateCall(
          receiverId: receiverId,
          receiverName: remoteName,
          isVideo: isVideo,
        );

        if (result['success'] == true && result['callId'] != null) {
          final realCallId = result['callId'] as String;
          ReleaseLogger.log('🔧 [CALLID_FIX] CallId real de Firestore: $realCallId', tag: 'VideoCall');

          // ✅ CRÍTICO: Actualizar el callId con el valor real del documento creado
          if (callId != realCallId) {
            ReleaseLogger.log('⚠️ [CALLID_FIX] CallId diferente detectado - actualizando listener', tag: 'VideoCall');

            // Cancelar listener anterior
            _callStateSubscription?.cancel();

            // Actualizar callId real y reconfigurar listener
            _realCallId = realCallId;
            _setupCallStateListener();

            ReleaseLogger.log('✅ [CALLID_FIX] CallId actualizado a: $_realCallId', tag: 'VideoCall');
          }

          // Actualizar también credenciales si vienen en el resultado
          if (result['channelName'] != null) {
            channelName = result['channelName'] as String;
          }
          if (result['token'] != null) {
            token = result['token'] as String;
          }
          if (result['uid'] != null) {
            uid = result['uid'] as int;
          }
        }
      } catch (e) {
        ReleaseLogger.error('Error iniciando llamada: $e', tag: 'VideoCall');
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
        ReleaseLogger.error('Error aceptando llamada: $e', tag: 'VideoCall');
        onError?.call('Error aceptando llamada: $e');
      }
    }
  }

  /// ✅ LÓGICA DE EVALUACIÓN: Determinar si la llamada debe terminar automáticamente
  ///
  /// Casos de uso según especificaciones:
  /// - Caso 1: A-B activos, B llama C (pendiente), A cuelga → Solo B activo → TERMINAR
  /// - Caso 2: A-B activos, B llama C (pendiente), A pierde conexión → Esperar 30s
  /// - Caso 3: A-B-C activos, A cuelga → B-C siguen activos → CONTINUAR
  ///
  /// ✅ ANTI-RACE CONDITION: No permitir auto-terminación en los primeros 15 segundos
  /// de la llamada para evitar terminaciones prematuras durante la sincronización inicial.
  ///
  /// IMPORTANTE: Esta lógica es SOLO para auto-terminación por desconexiones.
  /// Las terminaciones manuales (endCall()) siempre funcionan inmediatamente.
  void _evaluateCallTermination({bool isManualHangup = false}) {
    final activeParticipants = _remoteUids.length + 1; // +1 por mí mismo

    ReleaseLogger.log('🔍 [TERMINATION] Evaluando terminación de llamada...', tag: 'VideoCall');
    ReleaseLogger.log('🔍 [TERMINATION] Es terminación manual: $isManualHangup', tag: 'VideoCall');
    ReleaseLogger.log('🔍 [TERMINATION] Participantes activos: $activeParticipants (${_remoteUids.length} remotos + 1 local)', tag: 'VideoCall');
    ReleaseLogger.log('🔍 [TERMINATION] UIDs remotos: $_remoteUids', tag: 'VideoCall');

    // ✅ RACE CONDITION FIX: Solo aplicar duración mínima para AUTO-TERMINACIÓN
    if (!isManualHangup && _callStartTime != null) {
      final callDuration = DateTime.now().difference(_callStartTime!);
      final minimumCallDuration = Duration(seconds: 15);

      if (callDuration < minimumCallDuration) {
        final remainingTime = minimumCallDuration - callDuration;
        ReleaseLogger.log('⏰ [RACE_FIX] AUTO-TERMINACIÓN bloqueada - llamada muy reciente (${callDuration.inSeconds}s)', tag: 'VideoCall');
        ReleaseLogger.log('⏰ [RACE_FIX] Esperando ${remainingTime.inSeconds}s más para evaluar auto-terminación', tag: 'VideoCall');
        ReleaseLogger.log('⏰ [RACE_FIX] (Las terminaciones manuales siempre funcionan inmediatamente)', tag: 'VideoCall');
        return;
      }
    }

    // ✅ REGLA CRÍTICA: Si solo queda 1 participante activo (yo), terminar llamada
    if (activeParticipants <= 1) {
      ReleaseLogger.log('❌ [TERMINATION] Solo 1 participante activo restante → TERMINANDO LLAMADA', tag: 'VideoCall');
      ReleaseLogger.log('❌ [TERMINATION] Llamada no puede continuar con un solo participante', tag: 'VideoCall');

      // Terminar llamada localmente (esto también actualizará Firestore)
      endCall();
    } else {
      ReleaseLogger.log('✅ [TERMINATION] $activeParticipants participantes activos → LLAMADA CONTINÚA', tag: 'VideoCall');
      ReleaseLogger.log('✅ [TERMINATION] Suficientes participantes para mantener la llamada', tag: 'VideoCall');
    }
  }

  /// ✅ TIMEOUT DE RECONEXIÓN: Iniciar timer de 30 segundos para usuarios desconectados
  ///
  /// Si el usuario no se reconecta en 30 segundos, tratarlo como desconexión intencional
  /// y evaluar si terminar la llamada.
  void _startReconnectionTimeout(int remoteUid) {
    ReleaseLogger.log('⏰ [RECONNECTION] Iniciando timeout de 30s para UID $remoteUid', tag: 'VideoCall');

    // ✅ PREVENCIÓN: Cancelar timer anterior si existe
    if (_reconnectionTimer != null) {
      ReleaseLogger.log('🔄 [RECONNECTION] Cancelando timer anterior...', tag: 'VideoCall');
      _reconnectionTimer!.cancel();
    }

    // ✅ NUEVO TIMER: 30 segundos para reconexión
    _reconnectionTimer = Timer(Duration(seconds: 30), () {
      ReleaseLogger.log('⏰ [RECONNECTION] Timeout de 30s alcanzado para UID $remoteUid', tag: 'VideoCall');
      ReleaseLogger.log('❌ [RECONNECTION] Usuario no se reconectó → Tratando como desconexión intencional', tag: 'VideoCall');

      // ✅ EVALUACIÓN TARDÍA: Evaluar terminación después del timeout
      if (!_isEnding) {
        final activeParticipants = _remoteUids.length + 1;
        ReleaseLogger.log('🔍 [RECONNECTION] Participantes activos tras timeout: $activeParticipants', tag: 'VideoCall');

        // Aplicar la misma lógica que una desconexión intencional
        _evaluateCallTermination(isManualHangup: false); // Es auto-terminación por timeout
      } else {
        ReleaseLogger.log('⚠️ [RECONNECTION] Llamada ya terminando → Ignorando timeout', tag: 'VideoCall');
      }

      // ✅ LIMPIEZA: Resetear timer
      _reconnectionTimer = null;
    });

    ReleaseLogger.log('✅ [RECONNECTION] Timer de reconexión iniciado exitosamente', tag: 'VideoCall');
  }

  /// Dispose del controller
  void dispose() {
    // ReleaseLogger.log('🧹 [VideoCallController] Disposing controller');
    _cleanup();
  }
}