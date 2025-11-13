import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/calls/calls_orchestrator.dart';
import '../services/permission_service.dart';
import '../services/app_config_service.dart';
import '../utils/release_logger.dart';
import '../models/call.dart';

/// Nuevo controller para VideoCallScreen usando la arquitectura de calls unificada
///
/// Este controller adapta la nueva arquitectura CallsOrchestrator para
/// trabajar con VideoCallScreen siguiendo CODING_RULES.md
///
/// ✅ SINGLETON: Evita múltiples instancias que causan AgoraRtcException(-17)
class CallController {
  // ✅ SINGLETON PATTERN: Static instance para evitar múltiples CallControllers
  static CallController? _instance;
  static String? _currentCallId;

  // Dependencies
  final CallsOrchestrator _callsOrchestrator;

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

  // Real Agora state tracking
  RtcEngine? _agoraEngine;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isJoined = false;
  int? _localUid;
  final Set<int> _remoteUids = {};
  String _connectionStatus = 'Inicializando...';
  List<Map<String, dynamic>> _firestoreParticipants = []; // ✅ PROBLEMA 1

  // Callbacks para comunicación con VideoCallScreen
  VoidCallback? onStateChanged;
  Function(String)? onConnectionStatusChanged;
  Function(Set<int>)? onRemoteUsersChanged;
  Function(List<Map<String, dynamic>>)? onParticipantsChanged; // ✅ PROBLEMA 1
  Function(bool)? onLocalUserJoined;
  Function(String)? onError;
  VoidCallback? onCallEnded;

  /// ✅ SINGLETON FACTORY: Retorna instancia existente para el mismo callId
  /// o crea nueva si es diferente callId o no existe
  factory CallController({
    required String callId,
    required String? channelName,
    required String? token,
    required int? uid,
    required bool isCaller,
    required String remoteName,
    required String receiverId,
    required bool isVideo,
    CallsOrchestrator? orchestrator,
  }) {
    // Si hay instancia existente para el mismo callId, la reutilizamos
    if (_instance != null && _currentCallId == callId && !_instance!._disposed) {
      ReleaseLogger.info(
        '🔄 [CallController] Reutilizando instancia existente para call: $callId',
        tag: 'CallController'
      );
      return _instance!;
    }

    // Si hay instancia para diferente callId, la limpiamos primero
    if (_instance != null && _currentCallId != callId) {
      ReleaseLogger.info(
        '🔄 [CallController] Limpiando instancia previa para call: $_currentCallId, nueva call: $callId',
        tag: 'CallController'
      );
      _instance!.dispose();
    }

    // Crear nueva instancia
    ReleaseLogger.info(
      '🆕 [CallController] Creando nueva instancia singleton para call: $callId',
      tag: 'CallController'
    );
    _currentCallId = callId;
    _instance = CallController._internal(
      callId: callId,
      channelName: channelName,
      token: token,
      uid: uid,
      isCaller: isCaller,
      remoteName: remoteName,
      receiverId: receiverId,
      isVideo: isVideo,
      orchestrator: orchestrator,
    );

    return _instance!;
  }

  /// ✅ PRIVATE CONSTRUCTOR: Solo usado por factory
  CallController._internal({
    required this.callId,
    required this.channelName,
    required this.token,
    required this.uid,
    required this.isCaller,
    required this.remoteName,
    required this.receiverId,
    required this.isVideo,
    CallsOrchestrator? orchestrator,
  }) : _callsOrchestrator = orchestrator ?? CallsOrchestrator();

  // Getters para compatibilidad con VideoCallScreen
  bool get isInitialized => _isInitialized;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isJoined => _isJoined;
  bool get isDisposed => _disposed;
  int? get localUid => _localUid;
  Set<int> get remoteUids => _remoteUids;
  String get connectionStatus => _connectionStatus;
  String? get currentCallId => callId;
  RtcEngine? get agoraEngine => _agoraEngine;
  List<Map<String, dynamic>> get firestoreParticipants => _firestoreParticipants; // ✅ PROBLEMA 1
  CallsOrchestrator get callsOrchestrator => _callsOrchestrator; // ✅ PROBLEMA 1

  /// Stream de estado de llamada
  Stream<CallStateUpdate> get callStateStream {
    return _callsOrchestrator.watchCall(callId).map((call) {
      if (call == null) {
        return CallStateUpdate(callId: callId, status: 'ended');
      }

      final currentUserId = _getCurrentUserId();
      if (currentUserId == null) {
        return CallStateUpdate(callId: callId, status: 'unknown');
      }

      final userParticipant = call.participants[currentUserId];
      final status = userParticipant?.status ?? 'unknown';

      return CallStateUpdate(callId: callId, status: status);
    });
  }

  /// Inicializar listener para sincronización de terminación de llamada
  void _initializeCallTerminationListener() {
    // Escuchar cambios en el estado de la llamada
    callStateStream.listen((update) {
      if (update.status == 'ended' && !_disposed) {
        ReleaseLogger.log('🔚 [CallController] Llamada terminada remotamente, finalizando localmente', tag: 'CallController');
        // Terminar la llamada local sin actualizar Firestore (ya está terminada)
        _endCallLocally();
      }
    });

    // ✅ CRITICAL FIX: Escuchar el estado general de la llamada para detectar declines
    _callsOrchestrator.watchCall(callId).listen((call) {
      if (call == null && !_disposed) {
        ReleaseLogger.log('🔚 [CallController] Llamada eliminada de Firestore, finalizando localmente', tag: 'CallController');
        _endCallLocally();
      } else if (call != null && call.endedAt != null && !_disposed) {
        ReleaseLogger.log('🔚 [CallController] Llamada marcada como terminada, finalizando localmente', tag: 'CallController');
        _endCallLocally();
      } else if (call != null && !_disposed) {
        // ✅ NUEVA LÓGICA: Detectar cuando otros participantes declinan la llamada
        final currentUserId = _getCurrentUserId();
        if (currentUserId != null) {
          // Verificar si hay algún participante con estado 'declined'
          bool hasDeclinedParticipant = call.participants.values.any((participant) => participant.status == 'declined');

          // Verificar si todos los participantes (excepto el caller) han declinado
          final nonCallerParticipants = call.participants.entries.where((entry) => entry.key != call.createdBy);
          bool allNonCallersDeclined = nonCallerParticipants.isNotEmpty &&
              nonCallerParticipants.every((entry) => entry.value.status == 'declined');

          if (hasDeclinedParticipant && allNonCallersDeclined) {
            ReleaseLogger.log('❌ [CallController] Todos los participantes declinaron la llamada, finalizando localmente', tag: 'CallController');
            _endCallLocally();
          } else if (hasDeclinedParticipant) {
            ReleaseLogger.log('❌ [CallController] Participante declinó la llamada: ${call.participants}', tag: 'CallController');
            // En llamada 1-1, si el otro participante declina, terminar
            if (call.participants.length == 2) {
              ReleaseLogger.log('❌ [CallController] Llamada 1-1 declinada, finalizando localmente', tag: 'CallController');
              _endCallLocally();
            }
          }
        }

        // ✅ PROBLEMA 1: Trackear cambios en participantes para UI reactivo
        _updateParticipantsList(call);
      }
    });
  }

  /// ✅ PROBLEMA 1: Actualizar lista de participantes y notificar UI
  void _updateParticipantsList(Call call) async {
    final newParticipants = call.participants.entries.map((entry) {
      return {
        'userId': entry.key,
        'status': entry.value.status,
        'joinedAt': entry.value.joinedAt,
        'name': 'Cargando...', // Placeholder temporal mientras se obtienen nombres
      };
    }).toList();

    // Solo actualizar si hay cambios
    if (_participantsListChanged(newParticipants)) {
      _firestoreParticipants = newParticipants;

      ReleaseLogger.log(
        '👥 [CallController] Participantes actualizados: ${_firestoreParticipants.length} participantes',
        tag: 'CallController',
      );

      for (final p in _firestoreParticipants) {
        ReleaseLogger.log('  - ${p['name']} (${p['userId']}): ${p['status']}', tag: 'CallController');
      }

      // Notificar a la UI
      onParticipantsChanged?.call(_firestoreParticipants);

      // ✅ FIX: Obtener nombres reales de forma asíncrona
      _fetchParticipantNames(call.participants.keys.toList());
    }
  }

  /// ✅ FIX: Método para obtener nombres reales de usuarios desde Firestore
  Future<void> _fetchParticipantNames(List<String> userIds) async {
    try {
      final futures = userIds.map((userId) async {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .get();

        String userName = 'Usuario';
        if (userDoc.exists) {
          final userData = userDoc.data()!;
          userName = userData['name'] as String? ??
                    userData['email'] as String? ??
                    'Usuario';
        }

        return {'userId': userId, 'name': userName};
      });

      final results = await Future.wait(futures);

      // Actualizar nombres en la lista de participantes
      bool updated = false;
      for (final result in results) {
        final index = _firestoreParticipants.indexWhere(
          (p) => p['userId'] == result['userId']
        );
        if (index != -1) {
          _firestoreParticipants[index]['name'] = result['name'];
          updated = true;
        }
      }

      if (updated) {
        ReleaseLogger.log('✅ [CallController] Nombres de participantes actualizados', tag: 'CallController');
        onParticipantsChanged?.call(_firestoreParticipants);
      }
    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error obteniendo nombres: $e', tag: 'CallController');
    }
  }

  /// Helper para detectar si la lista de participantes cambió
  bool _participantsListChanged(List<Map<String, dynamic>> newParticipants) {
    if (_firestoreParticipants.length != newParticipants.length) return true;

    for (int i = 0; i < newParticipants.length; i++) {
      if (i >= _firestoreParticipants.length ||
          _firestoreParticipants[i]['userId'] != newParticipants[i]['userId'] ||
          _firestoreParticipants[i]['status'] != newParticipants[i]['status']) {
        return true;
      }
    }
    return false;
  }

  /// Finalizar llamada solo localmente (sin actualizar Firestore)
  Future<void> _endCallLocally() async {
    if (_disposed) return;

    try {
      ReleaseLogger.log('📞 [CallController] Finalizando llamada localmente', tag: 'CallController');

      // Actualizar estado local
      _isJoined = false;
      _remoteUids.clear();
      _connectionStatus = 'Desconectado';

      // Salir del canal de Agora
      await _leaveChannel();

      // Notificar a la UI
      onStateChanged?.call();
      onCallEnded?.call();

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error finalizando llamada localmente: $e', tag: 'CallController');
    }
  }

  /// Inicializar controller
  Future<bool> initialize({BuildContext? context}) async {
    if (_disposed) return false;

    // ✅ FIXED: Evitar doble inicialización del controller
    if (_isInitialized) {
      ReleaseLogger.log('✅ [CallController] Controller ya inicializado, reutilizando instancia', tag: 'CallController');
      return true;
    }

    try {
      ReleaseLogger.log('🎧 [CallController] Inicializando controller', tag: 'CallController');

      // ✅ ANDROID: Verificar permisos ANTES de inicializar Agora
      if (context != null) {
        final permissionsGranted = await _checkCallPermissions(context);
        if (!permissionsGranted) {
          ReleaseLogger.error('❌ [CallController] Permisos de llamada no concedidos', tag: 'CallController');
          onError?.call('Permisos de cámara/micrófono requeridos para llamadas');
          return false;
        }
      } else {
        // ✅ VoIP CALL: Context is null, proceed without permission check
        // Los permisos se solicitarán cuando la app esté en foreground
        ReleaseLogger.log('📞 [CallController] Llamada VoIP detectada (context=null), procediendo sin verificación de permisos inmediata', tag: 'CallController');
        ReleaseLogger.log('⚠️ [CallController] Los permisos se verificarán/solicitarán cuando la app esté en foreground', tag: 'CallController');
      }

      // Inicializar Agora Engine directamente
      await _initializeAgoraEngine();

      // ✅ REACTIVATED: Listener para detectar cuando la llamada es declined/ended remotamente
      // ✅ PROBLEMA 1: También incluye tracking de cambios en participantes
      _initializeCallTerminationListener();

      _isInitialized = true;
      _connectionStatus = 'Inicializado';
      onStateChanged?.call();

      ReleaseLogger.log('✅ [CallController] CallController inicializado', tag: 'CallController');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error inicializando: $e', tag: 'CallController');
      onError?.call('Error de inicialización: $e');
      return false;
    }
  }

  /// Inicializar Agora Engine
  Future<void> _initializeAgoraEngine() async {
    try {
      ReleaseLogger.log('🎥 [CallController] Inicializando Agora Engine', tag: 'CallController');

      // ✅ FIXED: Verificar si Agora Engine ya existe antes de crear uno nuevo
      // Esto evita el error AgoraRtcException(-7) "Engine already exists"
      if (_agoraEngine != null) {
        ReleaseLogger.log('✅ [CallController] Agora Engine ya existe, reutilizando instancia', tag: 'CallController');
        return; // No crear otra instancia
      }

      // Crear engine solo si no existe
      _agoraEngine = createAgoraRtcEngine();

      // Obtener App ID desde configuración
      final appConfigService = AppConfigService();
      final appId = appConfigService.agoraAppId;

      ReleaseLogger.log('🔑 [CallController] Inicializando con App ID: ${appId.substring(0, 8)}...', tag: 'CallController');

      // Inicializar con App ID real
      await _agoraEngine!.initialize(RtcEngineContext(
        appId: appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      // Configurar callbacks
      _agoraEngine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            ReleaseLogger.log('✅ [CallController] Usuario local se unió al canal', tag: 'CallController');
            _isJoined = true;
            _localUid = connection.localUid;
            _connectionStatus = 'Conectado';
            onLocalUserJoined?.call(true);
            onConnectionStatusChanged?.call(_connectionStatus);
            onStateChanged?.call();
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            ReleaseLogger.log('👤 [CallController] Usuario remoto se unió: $remoteUid', tag: 'CallController');
            _remoteUids.add(remoteUid);
            onRemoteUsersChanged?.call(_remoteUids);
            onStateChanged?.call();
          },
          onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
            ReleaseLogger.log('🚶 [CallController] Usuario remoto se fue: $remoteUid (reason: $reason)', tag: 'CallController');
            _remoteUids.remove(remoteUid);
            onRemoteUsersChanged?.call(_remoteUids);
            onStateChanged?.call();

            // ✅ NUEVO: En llamada 1-1, si el otro usuario se va, terminar la llamada
            if (_remoteUids.isEmpty && _isJoined) {
              ReleaseLogger.log('🔚 [CallController] Todos los usuarios remotos se fueron, terminando llamada automáticamente', tag: 'CallController');
              // Terminar llamada local y actualizar Firestore
              endCall().catchError((error) {
                ReleaseLogger.error('❌ [CallController] Error terminando llamada automáticamente: $error', tag: 'CallController');
                return false;
              });
            }
          },
          onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {
            final statusText = _getConnectionStatusText(state);
            ReleaseLogger.log('🔄 [CallController] Estado de conexión: $statusText (isJoined: $_isJoined)', tag: 'CallController');

            // ✅ FIX: No sobreescribir si ya estamos joined y conectado
            if (_isJoined && state == ConnectionStateType.connectionStateConnecting) {
              ReleaseLogger.log('⚠️ [CallController] Evitando sobreescribir estado Conectado con Conectando (ya joined)', tag: 'CallController');
              return; // Mantener estado actual
            }

            _connectionStatus = statusText;
            onConnectionStatusChanged?.call(_connectionStatus);
            onStateChanged?.call();
          },
          onError: (ErrorCodeType err, String msg) {
            ReleaseLogger.error('❌ [CallController] Error Agora: $err - $msg', tag: 'CallController');
            onError?.call('Error de conexión: $msg');
          },
        ),
      );

      // Configurar modo de audio/video
      if (isVideo) {
        await _agoraEngine!.enableVideo();
        await _agoraEngine!.enableLocalVideo(true);
      } else {
        await _agoraEngine!.enableAudio();
        await _agoraEngine!.disableVideo();
      }

      ReleaseLogger.log('✅ [CallController] Agora Engine configurado', tag: 'CallController');

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error inicializando Agora: $e', tag: 'CallController');
      throw Exception('Error inicializando motor de llamadas: $e');
    }
  }

  /// Aceptar llamada entrante
  Future<Map<String, dynamic>> acceptCall(String callId) async {
    if (_disposed || _agoraEngine == null) return {'success': false, 'error': 'Controller disposed'};

    try {
      ReleaseLogger.log('📞 [CallController] Aceptando llamada: $callId', tag: 'CallController');

      // 1. Aceptar la llamada en Firestore
      final success = await _callsOrchestrator.acceptCall(callId);

      if (success) {
        // 2. Obtener credenciales reales de la llamada desde CallsOrchestrator
        if (channelName != null && token != null) {
          // 3. Unirse al canal real de Agora
          final joinSuccess = await joinExistingCall(
            channelName: channelName!,
            token: token!,
            uid: uid ?? 0,
            isVideo: isVideo,
          );

          if (joinSuccess) {
            return {
              'success': true,
              'callId': callId,
              'channelName': channelName,
              'token': token,
              'uid': uid,
            };
          } else {
            return {'success': false, 'error': 'Error uniéndose al canal'};
          }
        } else {
          return {'success': false, 'error': 'Credenciales de llamada faltantes'};
        }
      } else {
        return {'success': false, 'error': 'Error aceptando llamada en Firestore'};
      }

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error aceptando llamada: $e', tag: 'CallController');
      onError?.call('Error aceptando llamada: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Rechazar llamada entrante
  Future<bool> rejectCall(String callId, {String reason = 'declined'}) async {
    if (_disposed) return false;

    try {
      ReleaseLogger.log('❌ [CallsVideoController] Rechazando llamada: $callId', tag: 'CallsVideoController');
      return await _callsOrchestrator.declineCall(callId, reason: reason);
    } catch (e) {
      ReleaseLogger.error('❌ [CallsVideoController] Error rechazando llamada: $e', tag: 'CallsVideoController');
      onError?.call('Error rechazando llamada: $e');
      return false;
    }
  }

  /// Terminar llamada actual
  Future<bool> endCall() async {
    if (_disposed) return false;

    try {
      ReleaseLogger.log('📞 [CallsVideoController] Terminando llamada: $callId', tag: 'CallsVideoController');
      final success = await _callsOrchestrator.endCall(callId);

      if (success) {
        _isJoined = false;
        _remoteUids.clear();
        onStateChanged?.call();
        onCallEnded?.call();
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsVideoController] Error terminando llamada: $e', tag: 'CallsVideoController');
      onError?.call('Error terminando llamada: $e');
      return false;
    }
  }

  /// Alternar micrófono
  Future<bool> toggleMute() async {
    if (_disposed || _agoraEngine == null) return false;

    try {
      _isMuted = !_isMuted;
      await _agoraEngine!.muteLocalAudioStream(_isMuted);
      onStateChanged?.call();
      ReleaseLogger.log('🎤 [CallController] Micrófono ${_isMuted ? 'silenciado' : 'activado'}', tag: 'CallController');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error alternando mute: $e', tag: 'CallController');
      onError?.call('Error alternando micrófono: $e');
      return false;
    }
  }

  /// Alternar cámara
  Future<bool> toggleCamera() async {
    if (_disposed || _agoraEngine == null) return false;

    try {
      _isCameraOff = !_isCameraOff;
      await _agoraEngine!.enableLocalVideo(!_isCameraOff);
      onStateChanged?.call();
      ReleaseLogger.log('📹 [CallController] Cámara ${_isCameraOff ? 'desactivada' : 'activada'}', tag: 'CallController');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error alternando cámara: $e', tag: 'CallController');
      onError?.call('Error alternando cámara: $e');
      return false;
    }
  }

  /// Cambiar cámara (frontal/trasera)
  Future<bool> switchCamera() async {
    if (_disposed || _agoraEngine == null) return false;

    try {
      await _agoraEngine!.switchCamera();
      ReleaseLogger.log('🔄 [CallController] Cámara cambiada', tag: 'CallController');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error cambiando cámara: $e', tag: 'CallController');
      onError?.call('Error cambiando cámara: $e');
      return false;
    }
  }

  /// Unirse a una llamada existente usando credenciales ya obtenidas
  Future<bool> joinExistingCall({
    required String channelName,
    required String token,
    required int uid,
    required bool isVideo,
  }) async {
    // ✅ CRITICAL: Logging INMEDIATO para debuggear
    ReleaseLogger.log('🚀 [CallController] ===== INICIO joinExistingCall =====', tag: 'CallController');
    ReleaseLogger.log('🚀 [CallController] Parámetros: channelName=$channelName, uid=$uid, isVideo=$isVideo', tag: 'CallController');
    ReleaseLogger.log('🚀 [CallController] Estado: _disposed=$_disposed, _agoraEngine=${_agoraEngine != null ? "EXISTS" : "NULL"}', tag: 'CallController');

    if (_disposed || _agoraEngine == null) {
      ReleaseLogger.error('❌ [CallController] EARLY RETURN: disposed=$_disposed o agoraEngine=null', tag: 'CallController');
      return false;
    }

    try {
      ReleaseLogger.log('📞 [CallController] Uniéndose a llamada existente: $channelName', tag: 'CallController');
      ReleaseLogger.log('🔑 [CallController] Token: ${token.length > 20 ? '${token.substring(0, 20)}...' : token}', tag: 'CallController');
      ReleaseLogger.log('👤 [CallController] UID: $uid', tag: 'CallController');
      ReleaseLogger.log('📺 [CallController] Is Video: $isVideo', tag: 'CallController');

      // Verificar que Agora Engine esté disponible
      if (_agoraEngine == null) {
        ReleaseLogger.error('❌ [CallController] Agora Engine es null!', tag: 'CallController');
        return false;
      }

      // ✅ NUEVO: Verificar si ya estamos en un canal y salir primero
      try {
        await _agoraEngine!.leaveChannel();
        ReleaseLogger.log('🚪 [CallController] Salido de canal previo (si existía)', tag: 'CallController');
      } catch (leaveError) {
        ReleaseLogger.log('ℹ️ [CallController] No había canal previo: $leaveError', tag: 'CallController');
      }

      // Configurar el canal antes de unirse
      final channelMediaOptions = ChannelMediaOptions(
        autoSubscribeAudio: true,
        autoSubscribeVideo: isVideo,
        publishCameraTrack: isVideo,
        publishMicrophoneTrack: true,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
      );

      ReleaseLogger.log('🎯 [CallController] Intentando joinChannel...', tag: 'CallController');

      // Unirse al canal real de Agora
      await _agoraEngine!.joinChannel(
        token: token,
        channelId: channelName,
        uid: uid,
        options: channelMediaOptions,
      );

      ReleaseLogger.log('✅ [CallController] Unido al canal exitosamente', tag: 'CallController');
      ReleaseLogger.log('🚀 [CallController] ===== FIN joinExistingCall: SUCCESS =====', tag: 'CallController');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error uniéndose a llamada existente: $e', tag: 'CallController');
      ReleaseLogger.error('🔍 [CallController] Error type: ${e.runtimeType}', tag: 'CallController');
      ReleaseLogger.error('🔍 [CallController] Error details: $e', tag: 'CallController');
      ReleaseLogger.error('🚀 [CallController] ===== FIN joinExistingCall: ERROR =====', tag: 'CallController');
      onError?.call('Error uniéndose a llamada existente: $e');
      return false;
    }
  }

  /// Obtener llamadas activas (adaptado para compatibilidad)
  Future<List<ActiveCall>> getActiveCalls() async {
    if (_disposed) return [];

    try {
      final activeCalls = _callsOrchestrator.activeCalls;
      return activeCalls.map((call) => ActiveCall(
        callId: call.id,
        status: 'active', // Simplificado
      )).toList();
    } catch (e) {
      ReleaseLogger.error('❌ [CallsVideoController] Error obteniendo calls activas: $e', tag: 'CallsVideoController');
      return [];
    }
  }

  /// Obtener contactos disponibles para agregar
  Future<List<Map<String, dynamic>>> getAvailableContacts() async {
    if (_disposed) return [];

    try {
      ReleaseLogger.log('🔍 [CallController] Solicitando contactos disponibles al orchestrator', tag: 'CallController');

      // ✅ CORRECTO: Delegar al orchestrator siguiendo CODING_RULES.md
      return await _callsOrchestrator.getAvailableContactsForCall(
        currentCallId: callId,
        currentReceiverId: receiverId,
      );

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error obteniendo contactos: $e', tag: 'CallController');
      return [];
    }
  }

  /// Agregar participantes a la llamada actual (sin crear llamada nueva)
  Future<Map<String, dynamic>> addParticipantsToCurrentCall({
    required List<String> selectedContactIds,
  }) async {
    if (_disposed) return {'success': false, 'error': 'Controller disposed'};

    try {
      // Validar máximo 6 participantes totales
      final currentParticipants = 2; // A + B ya están en la llamada
      final totalParticipants = currentParticipants + selectedContactIds.length;
      if (totalParticipants > 6) {
        return {
          'success': false,
          'error': 'Máximo 6 participantes por llamada (actualmente $currentParticipants, intentando agregar ${selectedContactIds.length})'
        };
      }

      ReleaseLogger.log(
        '➕ [CallController] Agregando ${selectedContactIds.length} participantes a llamada actual: $callId',
        tag: 'CallController'
      );

      // ✅ NUEVO ENFOQUE: Agregar participantes a la llamada existente
      final result = await _callsOrchestrator.addParticipants(
        callId: callId,
        newParticipantIds: selectedContactIds,
      );

      if (result['success'] == true) {
        ReleaseLogger.log(
          '✅ [CallController] Participantes agregados exitosamente. Layout se adaptará automáticamente.',
          tag: 'CallController'
        );
        return {
          'success': true,
          'callId': callId, // Mismo callId, no hay nueva llamada
          'participantsAdded': selectedContactIds.length,
          'totalParticipants': totalParticipants,
        };
      } else {
        return result;
      }

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error agregando participantes: $e', tag: 'CallController');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Verificar permisos de llamada (cámara y micrófono)
  Future<bool> _checkCallPermissions(BuildContext context) async {
    try {
      ReleaseLogger.log('🔒 [CallController] Verificando permisos para llamada', tag: 'CallController');
      ReleaseLogger.log('🔍 [CallController] DEBUG - Context disponible: ${context != null}, esVideo: $isVideo', tag: 'CallController');

      final permissionService = PermissionService();
      final requiredPermissions = [AppPermission.microphone];

      if (isVideo) {
        requiredPermissions.add(AppPermission.camera);
      }

      final results = <AppPermission, PermissionResult>{};

      // ✅ FIXED: Primero verificar si ya tenemos los permisos sin hacer request
      // Esto evita el error "A request for permissions is already running"
      final currentStatuses = <AppPermission, PermissionResult>{};
      bool needsRequest = false;

      for (final permission in requiredPermissions) {
        final currentStatus = await permissionService.checkStatus(permission);
        currentStatuses[permission] = currentStatus;

        if (currentStatus != PermissionResult.granted && currentStatus != PermissionResult.limited) {
          needsRequest = true;
        }
      }

      ReleaseLogger.log('🔍 [CallController] Estado actual de permisos: $currentStatuses', tag: 'CallController');

      // ✅ iOS VoIP EXCEPTION: Si todos los permisos están "denied" en iOS,
      // esto probablemente significa que es una llamada VoIP aceptada desde CallKit
      final allDenied = currentStatuses.values.every((status) => status == PermissionResult.denied);
      if (allDenied && Platform.isIOS) {
        ReleaseLogger.log('📞 [CallController] iOS VoIP: Todos los permisos denegados en iOS', tag: 'CallController');
        ReleaseLogger.log('⚠️ [CallController] Permitiendo continuar - permisos se solicitarán cuando sea posible', tag: 'CallController');
        // Devolver true para permitir continuar, pero marcar que necesitamos permisos
        return true; // ✅ ALLOW iOS VoIP TO PROCEED
      }

      // Solo hacer request si realmente necesitamos permisos
      if (needsRequest) {
        ReleaseLogger.log('🙋 [CallController] Solicitando permisos faltantes...', tag: 'CallController');

        // ✅ IMPROVED: Usar try-catch específico para race conditions de permisos
        try {
          final requestResults = await permissionService.requestMultiple(
            requiredPermissions,
            context: context,
          );

          // Combinar resultados actuales con nuevos resultados
          for (final entry in requestResults.entries) {
            results[entry.key] = entry.value;
          }
        } catch (permissionError) {
          ReleaseLogger.log('⚠️ [CallController] Error en solicitud de permisos (probablemente race condition): $permissionError', tag: 'CallController');
          // Si hay error, usar los estados actuales - es probable que ya tengamos los permisos
          for (final entry in currentStatuses.entries) {
            results[entry.key] = entry.value;
          }
        }
      } else {
        // Ya tenemos todos los permisos
        ReleaseLogger.log('✅ [CallController] Ya tenemos todos los permisos necesarios', tag: 'CallController');
        for (final entry in currentStatuses.entries) {
          results[entry.key] = entry.value;
        }
      }

      bool allPermissionsGranted = true;
      for (final entry in results.entries) {
        final result = entry.value;
        if (result != PermissionResult.granted && result != PermissionResult.limited) {
          allPermissionsGranted = false;
          break;
        }
      }

      ReleaseLogger.log(
        allPermissionsGranted
          ? '✅ [CallController] Todos los permisos concedidos'
          : '❌ [CallController] Permisos insuficientes',
        tag: 'CallController'
      );

      return allPermissionsGranted;

    } catch (e) {
      ReleaseLogger.error('❌ [CallController] Error verificando permisos: $e', tag: 'CallController');
      return false;
    }
  }

  /// Obtener texto del estado de conexión
  String _getConnectionStatusText(ConnectionStateType state) {
    // ✅ FIX: Si ya estamos joined, priorizar ese estado sobre el raw connection state
    if (_isJoined) {
      switch (state) {
        case ConnectionStateType.connectionStateConnected:
          return 'Conectado';
        case ConnectionStateType.connectionStateConnecting:
          return 'Conectado'; // ✅ FIX: Ya joined, mostrar como conectado
        case ConnectionStateType.connectionStateReconnecting:
          return 'Reconectando...';
        case ConnectionStateType.connectionStateDisconnected:
        case ConnectionStateType.connectionStateFailed:
          return 'Desconectado';
      }
    }

    // Estado normal si no estamos joined aún
    switch (state) {
      case ConnectionStateType.connectionStateDisconnected:
        return 'Desconectado';
      case ConnectionStateType.connectionStateConnecting:
        return 'Conectando...';
      case ConnectionStateType.connectionStateConnected:
        return 'Conectado';
      case ConnectionStateType.connectionStateReconnecting:
        return 'Reconectando...';
      case ConnectionStateType.connectionStateFailed:
        return 'Conexión fallida';
    }
  }

  /// Salir del canal de Agora
  Future<void> _leaveChannel() async {
    if (_agoraEngine != null && _isJoined) {
      try {
        await _agoraEngine!.leaveChannel();
        _isJoined = false;
        _remoteUids.clear();
        _localUid = null;
        ReleaseLogger.log('📤 [CallController] Canal abandonado exitosamente', tag: 'CallController');
      } catch (e) {
        ReleaseLogger.error('❌ [CallController] Error abandonando canal: $e', tag: 'CallController');
      }
    }
  }

  /// Obtener ID del usuario actual (helper)
  String? _getCurrentUserId() {
    return FirebaseAuth.instance.currentUser?.uid;
  }

  /// Dispose del controller
  Future<void> dispose() async {
    if (_disposed) return;

    ReleaseLogger.log('🧹 [CallController] Disposing singleton instance for call: $callId', tag: 'CallController');

    _disposed = true;

    // Limpiar callbacks
    onStateChanged = null;
    onConnectionStatusChanged = null;
    onRemoteUsersChanged = null;
    onParticipantsChanged = null; // ✅ PROBLEMA 1
    onLocalUserJoined = null;
    onError = null;
    onCallEnded = null;

    // Salir del canal y limpiar Agora
    await _leaveChannel();
    await _agoraEngine?.release();
    _agoraEngine = null;

    _isInitialized = false;

    // ✅ SINGLETON CLEANUP: Limpiar instancia singleton si es la actual
    if (_instance == this) {
      ReleaseLogger.log('🧹 [CallController] Limpiando instancia singleton', tag: 'CallController');
      _instance = null;
      _currentCallId = null;
    }
  }
}

/// Modelos de compatibilidad para VideoCallScreen
class CallStateUpdate {
  final String callId;
  final String status;

  CallStateUpdate({required this.callId, required this.status});
}

class ActiveCall {
  final String callId;
  final String status;

  ActiveCall({required this.callId, required this.status});
}