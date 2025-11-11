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
  final StreamController<CallStateUpdate> _callStateController = StreamController<CallStateUpdate>.broadcast();
  final StreamController<List<IncomingCall>> _incomingCallsController = StreamController<List<IncomingCall>>.broadcast();

  // Subscripciones activas
  final Map<String, StreamSubscription> _callSubscriptions = {};
  StreamSubscription? _incomingCallsSubscription;

  // Getters para streams públicos
  Stream<CallStateUpdate> get callStateStream => _callStateController.stream;
  Stream<List<IncomingCall>> get incomingCallsStream => _incomingCallsController.stream;

  /// Iniciar monitoreo de una videollamada específica
  void startMonitoringCall(String callId) {
    if (_callSubscriptions.containsKey(callId)) {
      return; // Ya está siendo monitoreada
    }

    final subscription = _videoCallRepo.watchCall(callId).listen(
      (snapshot) {
        if (snapshot.exists) {
          final data = snapshot.data() as Map<String, dynamic>;
          final update = CallStateUpdate(
            callId: callId,
            status: data['status'] as String,
            data: data,
            timestamp: DateTime.now(),
          );
          _callStateController.add(update);
        } else {
          // La llamada fue eliminada
          final update = CallStateUpdate(
            callId: callId,
            status: 'deleted',
            data: {},
            timestamp: DateTime.now(),
          );
          _callStateController.add(update);
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
        _callStateController.add(update);
      },
    );

    _callSubscriptions[callId] = subscription;
  }

  /// Detener monitoreo de una videollamada específica
  void stopMonitoringCall(String callId) {
    final subscription = _callSubscriptions.remove(callId);
    subscription?.cancel();
  }

  /// Iniciar monitoreo de llamadas entrantes para un usuario
  void startMonitoringIncomingCalls(String userId) {
    _incomingCallsSubscription?.cancel();

    _incomingCallsSubscription = _videoCallRepo.watchIncomingCalls(userId).listen(
      (querySnapshot) async {
        final incomingCalls = <IncomingCall>[];

        for (final doc in querySnapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;

          // Verificar que la llamada no esté expirada
          final createdAt = data['createdAt'] as String?;
          if (createdAt != null) {
            final callTime = DateTime.parse(createdAt);
            if (DateTime.now().difference(callTime).inMinutes > 2) {
              // La llamada expiró, marcarla como lost
              await _videoCallRepo.updateStatus(doc.id, 'missed', additionalData: {
                'missedAt': DateTime.now().toIso8601String(),
                'reason': 'timeout',
              });
              continue;
            }
          }

          final incomingCall = IncomingCall(
            callId: doc.id,
            callerId: data['callerId'] as String,
            callerName: data['callerName'] as String,
            isVideo: data['isVideo'] as bool,
            channelName: data['channelName'] as String?,
            token: data['token'] as String?,
            createdAt: createdAt != null ? DateTime.parse(createdAt) : DateTime.now(),
          );
          incomingCalls.add(incomingCall);
        }

        _incomingCallsController.add(incomingCalls);
      },
      onError: (error) {
        ReleaseLogger.error('Error monitoreando llamadas entrantes para $userId: $error', tag: 'CallState');
        _incomingCallsController.add([]);
      },
    );
  }

  /// Detener monitoreo de llamadas entrantes
  void stopMonitoringIncomingCalls() {
    _incomingCallsSubscription?.cancel();
    _incomingCallsSubscription = null;
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

    // Cerrar streams
    _callStateController.close();
    _incomingCallsController.close();
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