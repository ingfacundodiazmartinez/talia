import 'dart:async';
import '../repositories/video_call_repository.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado en gestión de estados de videollamadas
///
/// Responsabilidades:
/// - Monitoreo de estados de llamadas en tiempo real
/// - Detección de cambios de estado (calling → accepted → ended)
/// - Notificaciones de estado a la UI
/// - Cleanup de llamadas expiradas
class CallStateService {
  static final CallStateService _instance = CallStateService._internal();
  factory CallStateService() => _instance;
  CallStateService._internal();

  final VideoCallRepository _videoCallRepo = VideoCallRepository();

  // Controllers para streams de estado
  StreamController<CallStateUpdate>? _callStateController;
  StreamController<List<IncomingCall>>? _incomingCallsController;

  // Subscripciones activas
  final Map<String, StreamSubscription> _callSubscriptions = {};
  StreamSubscription? _incomingCallsSubscription;

  // Getters para streams públicos
  Stream<CallStateUpdate> get callStateStream {
    _callStateController ??= StreamController<CallStateUpdate>.broadcast();
    return _callStateController!.stream;
  }

  Stream<List<IncomingCall>> get incomingCallsStream {
    _incomingCallsController ??= StreamController<List<IncomingCall>>.broadcast();
    return _incomingCallsController!.stream;
  }

  // Track del primer estado para evitar cancelaciones inmediatas
  final Map<String, String> _firstCallStates = {};

  /// Iniciar monitoreo de una videollamada específica
  void startMonitoringCall(String callId) {
    ReleaseLogger.log(
      '🔧 [CallState] ═══════════════════════════════════════',
      tag: 'CallState',
    );
    ReleaseLogger.log(
      '🔧 [CallState] INICIANDO MONITOREO DE LLAMADA: $callId',
      tag: 'CallState',
    );
    ReleaseLogger.log(
      '🔧 [CallState] ═══════════════════════════════════════',
      tag: 'CallState',
    );

    ReleaseLogger.log(
      '🔍 [CallState] Subscripciones existentes: ${_callSubscriptions.keys.toList()}',
      tag: 'CallState',
    );

    if (_callSubscriptions.containsKey(callId)) {
      ReleaseLogger.log(
        '⚠️ [CallState] LLAMADA YA MONITOREADA - saltando: $callId',
        tag: 'CallState',
      );
      return; // Ya está siendo monitoreada
    }

    ReleaseLogger.log(
      '🧹 [CallState] LIMPIANDO estado inicial para: $callId',
      tag: 'CallState',
    );

    // Resetear estado inicial para esta llamada
    _firstCallStates.remove(callId);

    final subscription = _videoCallRepo.watchCall(callId).listen(
      (snapshot) {
        ReleaseLogger.log(
          '🔍 [CallState] SNAPSHOT UPDATE para $callId - existe: ${snapshot.exists}',
          tag: 'CallState',
        );

        if (snapshot.exists) {
          final data = snapshot.data() as Map<String, dynamic>;
          final status = data['status'] as String;

          // 📊 LOG DETALLADO DE TODOS LOS DATOS
          ReleaseLogger.log(
            '📋 [CallState] DATOS COMPLETOS del documento $callId:',
            tag: 'CallState',
          );
          ReleaseLogger.log(
            '   - status: $status',
            tag: 'CallState',
          );
          ReleaseLogger.log(
            '   - callerId: ${data['callerId']}',
            tag: 'CallState',
          );
          ReleaseLogger.log(
            '   - receiverId: ${data['receiverId']}',
            tag: 'CallState',
          );
          ReleaseLogger.log(
            '   - createdAt: ${data['createdAt']}',
            tag: 'CallState',
          );
          ReleaseLogger.log(
            '   - channelName: ${data['channelName']}',
            tag: 'CallState',
          );

          // Registrar todos los campos disponibles
          final allFields = data.keys.toList()..sort();
          ReleaseLogger.log(
            '   - TODOS LOS CAMPOS: $allFields',
            tag: 'CallState',
          );

          final update = CallStateUpdate(
            callId: callId,
            status: status,
            data: data,
            timestamp: DateTime.now(),
          );

          ReleaseLogger.log(
            '📡 [CallState] EMITIENDO state update: $status para call $callId',
            tag: 'CallState',
          );

          _callStateController ??= StreamController<CallStateUpdate>.broadcast();
          _callStateController!.add(update);

          // ✅ CRÍTICO: Solo cancelar si es un CAMBIO de estado, no el estado inicial
          final previousState = _firstCallStates[callId];

          ReleaseLogger.log(
            '🔄 [CallState] TRANSICIÓN DE ESTADO para $callId: $previousState → $status',
            tag: 'CallState',
          );

          if (previousState == null) {
            // Primer estado - guardarlo pero NO cancelar
            _firstCallStates[callId] = status;
            ReleaseLogger.log(
              '📝 [CallState] PRIMER ESTADO GUARDADO para $callId: $status',
              tag: 'CallState',
            );
          } else {
            ReleaseLogger.log(
              '🔍 [CallState] ANALIZANDO CAMBIO DE ESTADO $callId: $previousState → $status',
              tag: 'CallState',
            );

            // Estado cambió - verificar si debe cancelarse
            // SOLO cancelar CallKit si el caller canceló ANTES de que se acepte
            if (previousState != status && (status == 'missed' || status == 'declined' || status == 'cancelled_by_caller')) {
              ReleaseLogger.log(
                '⚠️ [CallState] DETECTADO ESTADO DE CANCELACIÓN: $status',
                tag: 'CallState',
              );

              // NO cancelar si la llamada fue previamente aceptada
              if (previousState != 'accepted' && previousState != 'connected') {
                ReleaseLogger.log(
                  '🚫 [CallState] CANCELANDO CALLKIT: $callId ($previousState → $status) - llamada no fue aceptada',
                  tag: 'CallState',
                );
                _handleCallCancellation(callId);
              } else {
                ReleaseLogger.log(
                  'ℹ️ [CallState] NO CANCELANDO: $callId ($previousState → $status) - llamada ya fue aceptada',
                  tag: 'CallState',
                );
              }
            } else if (previousState != status && status == 'ended') {
              // ✅ FIXED: NO CANCELAR CallKit para 'ended' - las llamadas que terminan normalmente
              // Las llamadas pueden ir directamente de calling → ended si el receptor las termina
              ReleaseLogger.log(
                '🔚 [CallState] LLAMADA TERMINÓ NORMALMENTE: $callId ($previousState → $status) - NO cancelar CallKit',
                tag: 'CallState',
              );

              // 🕵️ INVESTIGAR: ¿Por qué se marca como ended tan rápido?
              final now = DateTime.now();
              final createdAt = data['createdAt'] as String?;
              if (createdAt != null) {
                final created = DateTime.parse(createdAt);
                final duration = now.difference(created).inSeconds;
                ReleaseLogger.log(
                  '⏱️ [CallState] DURACIÓN DESDE CREACIÓN: ${duration}s - ¿Por qué ended tan rápido?',
                  tag: 'CallState',
                );
              }
            } else if (previousState == status) {
              ReleaseLogger.log(
                '🔄 [CallState] MISMO ESTADO repetido: $status (sin cambios)',
                tag: 'CallState',
              );
            } else {
              ReleaseLogger.log(
                '📋 [CallState] CAMBIO DE ESTADO NORMAL: $previousState → $status',
                tag: 'CallState',
              );
            }
          }
        } else {
          ReleaseLogger.log(
            '🗑️ [CallState] DOCUMENTO ELIMINADO: $callId',
            tag: 'CallState',
          );

          // La llamada fue eliminada
          final update = CallStateUpdate(
            callId: callId,
            status: 'deleted',
            data: {},
            timestamp: DateTime.now(),
          );
          _callStateController ??= StreamController<CallStateUpdate>.broadcast();
          _callStateController!.add(update);

          // También cancelar CallKit si la llamada fue eliminada
          ReleaseLogger.log(
            '🚫 [CallState] CANCELANDO CALLKIT por eliminación: $callId',
            tag: 'CallState',
          );
          _handleCallCancellation(callId);
        }
      },
      onError: (error) {
        ReleaseLogger.error('Error monitoreando llamada $callId: $error', tag: 'CallState');
        final update = CallStateUpdate(
          callId: callId,
          status: 'error',
          data: {'error': error.toString()},
          timestamp: DateTime.now(),
        );
        _callStateController ??= StreamController<CallStateUpdate>.broadcast();
        _callStateController!.add(update);
      },
    );

    _callSubscriptions[callId] = subscription;

    ReleaseLogger.log(
      '✅ [CallState] SUSCRIPCIÓN ESTABLECIDA para callId: $callId',
      tag: 'CallState',
    );
    ReleaseLogger.log(
      '📊 [CallState] Total de suscripciones activas: ${_callSubscriptions.length}',
      tag: 'CallState',
    );
    ReleaseLogger.log(
      '📋 [CallState] Lista de callIds monitoreados: ${_callSubscriptions.keys.toList()}',
      tag: 'CallState',
    );
  }

  /// Detener monitoreo de una videollamada específica
  void stopMonitoringCall(String callId) {
    final subscription = _callSubscriptions.remove(callId);
    subscription?.cancel();

    // Limpiar estado inicial guardado
    _firstCallStates.remove(callId);
  }

  // Track de llamadas entrantes activas para detectar cancelaciones
  final Set<String> _activeIncomingCallIds = {};

  /// Iniciar monitoreo de llamadas entrantes para un usuario
  void startMonitoringIncomingCalls(String userId) {
    _incomingCallsSubscription?.cancel();

    _incomingCallsSubscription = _videoCallRepo.watchIncomingCalls(userId).listen(
      (querySnapshot) async {
        final incomingCalls = <IncomingCall>[];
        final currentCallIds = <String>{};

        for (final doc in querySnapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;
          final callId = doc.id;
          currentCallIds.add(callId);

          // Verificar que la llamada no esté expirada
          final createdAt = data['createdAt'] as String?;
          if (createdAt != null) {
            final callTime = DateTime.parse(createdAt);
            if (DateTime.now().difference(callTime).inMinutes > 2) {
              // La llamada expiró, marcarla como lost
              await _videoCallRepo.updateStatus(callId, 'missed', additionalData: {
                'missedAt': DateTime.now().toIso8601String(),
                'reason': 'timeout',
              });
              continue;
            }
          }

          final incomingCall = IncomingCall(
            callId: callId,
            callerId: data['callerId'] as String,
            callerName: data['callerName'] as String,
            isVideo: data['isVideo'] as bool,
            channelName: data['channelName'] as String?,
            token: data['token'] as String?,
            createdAt: createdAt != null ? DateTime.parse(createdAt) : DateTime.now(),
          );
          incomingCalls.add(incomingCall);
        }

        // ✅ CRÍTICO: Detectar llamadas que desaparecieron del stream
        // Solo cancelar CallKit si la llamada fue realmente cancelada/rechazada/perdida
        final cancelledCallIds = _activeIncomingCallIds.difference(currentCallIds);
        for (final cancelledCallId in cancelledCallIds) {
          try {
            final callData = await _videoCallRepo.getById(cancelledCallId);

            if (callData == null) {
              // La llamada fue eliminada completamente - cancelar CallKit
              ReleaseLogger.log('🚫 [CallState] Llamada eliminada de DB: $cancelledCallId - cancelando CallKit', tag: 'CallState');
              await _handleCallCancellation(cancelledCallId);
              continue;
            }

            final currentStatus = callData['status'] as String;

            // ✅ CANCELAR CallKit solo para estos estados:
            if (currentStatus == 'declined' ||
                currentStatus == 'cancelled' ||
                currentStatus == 'cancelled_by_caller' ||
                currentStatus == 'missed' ||
                currentStatus == 'timeout') {
              ReleaseLogger.log('🚫 [CallState] Llamada cancelada/rechazada: $cancelledCallId (estado: $currentStatus) - cancelando CallKit', tag: 'CallState');
              await _handleCallCancellation(cancelledCallId);
            } else if (currentStatus == 'accepted' || currentStatus == 'connected' || currentStatus == 'ended') {
              // ✅ FIXED: NO CANCELAR CallKit para accepted/connected/ended - son estados válidos
              // Estas llamadas ya no aparecen en watchIncomingCalls pero NO están canceladas
              ReleaseLogger.log('ℹ️ [CallState] Llamada en estado válido: $cancelledCallId (estado: $currentStatus) - NO cancelar CallKit', tag: 'CallState');
            } else {
              // Estado desconocido - log para debugging
              ReleaseLogger.log('⚠️ [CallState] Estado desconocido para llamada: $cancelledCallId (estado: $currentStatus)', tag: 'CallState');
            }
          } catch (e) {
            ReleaseLogger.error('❌ [CallState] Error verificando estado de llamada $cancelledCallId: $e', tag: 'CallState');
            // En caso de error, asumir que fue cancelada para limpiar notificaciones
            await _handleCallCancellation(cancelledCallId);
          }
        }

        // ✅ DEBUG: Logging para entender el problema de acumulación
        ReleaseLogger.log('🔍 [CallState] DEBUG - Current call IDs: ${currentCallIds.toList()}, Previous active: ${_activeIncomingCallIds.toList()}', tag: 'CallState');

        // Actualizar tracking de llamadas activas
        _activeIncomingCallIds.clear();
        _activeIncomingCallIds.addAll(currentCallIds);

        ReleaseLogger.log('📞 [CallState] Procesadas ${incomingCalls.length} llamadas activas válidas', tag: 'CallState');

        _incomingCallsController ??= StreamController<List<IncomingCall>>.broadcast();
        _incomingCallsController!.add(incomingCalls);
      },
      onError: (error) {
        ReleaseLogger.error('Error monitoreando llamadas entrantes para $userId: $error', tag: 'CallState');
        _incomingCallsController ??= StreamController<List<IncomingCall>>.broadcast();
        _incomingCallsController!.add([]);
      },
    );
  }

  /// Detener monitoreo de llamadas entrantes
  void stopMonitoringIncomingCalls() {
    _incomingCallsSubscription?.cancel();
    _incomingCallsSubscription = null;
    _activeIncomingCallIds.clear();
  }

  /// Manejar cancelación de llamada entrante
  /// Cancela notificaciones CallKit, VoIP y cierra IncomingCallScreen si está abierta
  Future<void> _handleCallCancellation(String callId) async {
    try {
      ReleaseLogger.log('🚫 [CallState] Procesando cancelación de llamada: $callId', tag: 'CallState');

      // 1. Cancelar CallKit/Android notifications
      await _cancelNativeNotifications(callId);

      // 2. Emitir evento de cancelación para que IncomingCallScreen se cierre
      final cancelUpdate = CallStateUpdate(
        callId: callId,
        status: 'cancelled_by_caller',
        data: {
          'reason': 'caller_cancelled',
          'cancelledAt': DateTime.now().toIso8601String(),
        },
        timestamp: DateTime.now(),
      );

      _callStateController ??= StreamController<CallStateUpdate>.broadcast();
      _callStateController!.add(cancelUpdate);

      ReleaseLogger.log('✅ [CallState] Cancelación procesada: $callId', tag: 'CallState');
    } catch (e) {
      ReleaseLogger.error('❌ [CallState] Error procesando cancelación de $callId: $e', tag: 'CallState');
    }
  }

  /// Cancelar notificaciones nativas (CallKit iOS y Android)
  Future<void> _cancelNativeNotifications(String callId) async {
    try {
      // Importar servicios necesarios dinámicamente para evitar dependencias circulares
      final voipService = _getVoIPService();
      final callKitService = _getCallKitService();

      ReleaseLogger.log('🔍 [CallState] DEBUG - voipService: ${voipService != null ? "FOUND" : "NULL"}', tag: 'CallState');
      ReleaseLogger.log('🔍 [CallState] DEBUG - callKitService: ${callKitService != null ? "FOUND" : "NULL"}', tag: 'CallState');

      // iOS: Cancelar CallKit y VoIP notifications
      if (voipService != null) {
        ReleaseLogger.log('📱 [CallState] Cancelando CallKit iOS para: $callId', tag: 'CallState');
        await voipService.notifyCallEnded(callId);
      } else {
        ReleaseLogger.log('⚠️ [CallState] VoIPService es NULL - no se puede cancelar iOS CallKit', tag: 'CallState');
      }

      // Android: Cancelar flutter_callkit_incoming notifications
      if (callKitService != null) {
        ReleaseLogger.log('🤖 [CallState] Cancelando notificación Android para: $callId', tag: 'CallState');
        await callKitService.endCall(callId);
      } else {
        ReleaseLogger.log('⚠️ [CallState] CallKitService es NULL - no se puede cancelar Android CallKit', tag: 'CallState');
      }

      ReleaseLogger.log('✅ [CallState] Notificaciones nativas canceladas para: $callId', tag: 'CallState');
    } catch (e) {
      ReleaseLogger.error('❌ [CallState] Error cancelando notificaciones nativas: $e', tag: 'CallState');
    }
  }

  /// Helper para obtener VoIPService sin dependencia circular
  dynamic _getVoIPService() {
    try {
      // Usar reflection-like approach para evitar import circular
      return _voipServiceInstance;
    } catch (e) {
      ReleaseLogger.log('⚠️ [CallState] VoIPService no disponible: $e', tag: 'CallState');
      return null;
    }
  }

  /// Helper para obtener CallKitService sin dependencia circular
  dynamic _getCallKitService() {
    try {
      // Usar reflection-like approach para evitar import circular
      return _callKitServiceInstance;
    } catch (e) {
      ReleaseLogger.log('⚠️ [CallState] CallKitService no disponible: $e', tag: 'CallState');
      return null;
    }
  }

  // Instancias de servicios externos (inyectadas dinámicamente)
  dynamic _voipServiceInstance;
  dynamic _callKitServiceInstance;

  /// Registrar servicios externos para evitar dependencias circulares
  void registerExternalServices({
    dynamic voipService,
    dynamic callKitService,
  }) {
    _voipServiceInstance = voipService;
    _callKitServiceInstance = callKitService;
    ReleaseLogger.log('📋 [CallState] Servicios externos registrados', tag: 'CallState');
  }

  /// Obtener estado actual de una videollamada
  Future<CallStateUpdate?> getCurrentCallState(String callId) async {
    try {
      final data = await _videoCallRepo.getById(callId);
      if (data == null) {
        return null;
      }

      return CallStateUpdate(
        callId: callId,
        status: data['status'] as String,
        data: data,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      ReleaseLogger.error('Error obteniendo estado de llamada $callId: $e', tag: 'CallState');
      return null;
    }
  }

  /// Obtener todas las llamadas activas para un usuario
  Future<List<ActiveCall>> getActiveCalls(String userId) async {
    try {
      final activeCalls = await _videoCallRepo.getActiveCalls(userId);
      return activeCalls.map((data) {
        return ActiveCall(
          callId: data['id'] as String,
          isIncoming: data['receiverId'] == userId,
          otherUserId: data['receiverId'] == userId ? data['callerId'] as String : data['receiverId'] as String,
          otherUserName: data['receiverId'] == userId ? data['callerName'] as String : data['receiverName'] as String,
          status: data['status'] as String,
          isVideo: data['isVideo'] as bool,
          channelName: data['channelName'] as String?,
          createdAt: data['createdAt'] != null ? DateTime.parse(data['createdAt']) : DateTime.now(),
        );
      }).toList();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo llamadas activas para $userId: $e', tag: 'CallState');
      return [];
    }
  }

  /// Verificar si un usuario tiene llamadas activas
  Future<bool> hasActiveCalls(String userId) async {
    final activeCalls = await getActiveCalls(userId);
    return activeCalls.isNotEmpty;
  }

  /// Limpiar llamadas expiradas (usar desde un timer periódico)
  Future<void> cleanupExpiredCalls() async {
    try {
      // Esta función se debería llamar periódicamente para limpiar llamadas old
      // En una implementación real, esto requeriría una consulta más compleja
      // Por ahora, lo delegamos al backend o se puede ejecutar como Cloud Function

    } catch (e) {
      ReleaseLogger.error('Error limpiando llamadas expiradas: $e', tag: 'CallState');
    }
  }

  /// Limpiar recursos del servicio
  void dispose() {
    // Cancelar todas las subscripciones
    for (final subscription in _callSubscriptions.values) {
      subscription.cancel();
    }
    _callSubscriptions.clear();

    _incomingCallsSubscription?.cancel();
    _incomingCallsSubscription = null;

    // ✅ CORREGIDO: No cerrar controllers sino resetearlos para permitir reutilización
    //
    // PROBLEMA ANTERIOR: Una vez cerrados los StreamControllers, no pueden emitir más eventos
    // en llamadas subsecuentes, causando que el listener no reciba notificaciones.
    //
    // SOLUCIÓN: Cerrar y resetear a null para que se recreen en la próxima llamada
    _callStateController?.close();
    _callStateController = null;

    _incomingCallsController?.close();
    _incomingCallsController = null;
  }
}

/// Modelo para actualizaciones de estado de llamada
class CallStateUpdate {
  final String callId;
  final String status;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  CallStateUpdate({
    required this.callId,
    required this.status,
    required this.data,
    required this.timestamp,
  });

  @override
  String toString() => 'CallStateUpdate(callId: $callId, status: $status, timestamp: $timestamp)';
}

/// Modelo para llamadas entrantes
class IncomingCall {
  final String callId;
  final String callerId;
  final String callerName;
  final bool isVideo;
  final String? channelName;
  final String? token;
  final DateTime createdAt;

  IncomingCall({
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.isVideo,
    this.channelName,
    this.token,
    required this.createdAt,
  });

  @override
  String toString() => 'IncomingCall(callId: $callId, caller: $callerName, isVideo: $isVideo)';
}

/// Modelo para llamadas activas
class ActiveCall {
  final String callId;
  final bool isIncoming;
  final String otherUserId;
  final String otherUserName;
  final String status;
  final bool isVideo;
  final String? channelName;
  final DateTime createdAt;

  ActiveCall({
    required this.callId,
    required this.isIncoming,
    required this.otherUserId,
    required this.otherUserName,
    required this.status,
    required this.isVideo,
    this.channelName,
    required this.createdAt,
  });

  @override
  String toString() => 'ActiveCall(callId: $callId, other: $otherUserName, status: $status)';
}