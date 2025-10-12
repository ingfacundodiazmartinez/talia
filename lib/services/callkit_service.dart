import 'dart:async';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';

/// Servicio para manejar llamadas entrantes con CallKit (iOS) y Full-Screen Intent (Android)
/// Muestra llamadas en pantalla completa incluso con la app cerrada
class CallKitService {
  // Singleton pattern
  static final CallKitService _instance = CallKitService._internal();
  factory CallKitService() => _instance;
  CallKitService._internal();

  StreamSubscription? _callEventSubscription;
  Function(Map<String, dynamic>)? _onCallAccepted;
  Function(String)? _onCallDeclined;
  Function(String)? _onCallEnded;

  /// Inicializar el servicio de CallKit
  void initialize({
    Function(Map<String, dynamic>)? onCallAccepted,
    Function(String)? onCallDeclined,
    Function(String)? onCallEnded,
  }) {
    _onCallAccepted = onCallAccepted;
    _onCallDeclined = onCallDeclined;
    _onCallEnded = onCallEnded;

    // Escuchar eventos de llamadas
    _callEventSubscription?.cancel();
    _callEventSubscription = FlutterCallkitIncoming.onEvent.listen((event) {
      _handleCallEvent(event!);
    });

    print('✅ CallKitService inicializado');
  }

  /// Manejar eventos de llamadas
  void _handleCallEvent(CallEvent event) {
    print('📞 CallKit event: ${event.event} - ${event.body}');

    switch (event.event) {
      case Event.actionCallAccept:
        // Usuario aceptó la llamada
        print('✅ Llamada aceptada');
        if (_onCallAccepted != null && event.body != null) {
          _onCallAccepted!(event.body!);
        }
        break;

      case Event.actionCallDecline:
        // Usuario rechazó la llamada
        print('❌ Llamada rechazada');
        if (_onCallDeclined != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            _onCallDeclined!(callId);
          }
        }
        break;

      case Event.actionCallEnded:
        // Llamada terminada
        print('🔚 Llamada terminada');
        if (_onCallEnded != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            _onCallEnded!(callId);
          }
        }
        break;

      case Event.actionCallTimeout:
        // Llamada expiró (timeout)
        print('⏱️ Llamada expiró');
        if (_onCallDeclined != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            _onCallDeclined!(callId);
          }
        }
        break;

      default:
        print('ℹ️ Evento no manejado: ${event.event}');
    }
  }

  /// Mostrar llamada entrante en pantalla completa
  Future<void> showIncomingCall({
    required String callId,
    required String callerName,
    required String callerId,
    String? callerPhotoUrl,
    String callType = 'video', // 'video' o 'audio'
    bool isEmergency = false,
    Map<String, dynamic>? extraData,
  }) async {
    try {
      // Generar UUID único si no se proporciona
      final uuid = callId.isNotEmpty ? callId : const Uuid().v4();

      final params = CallKitParams(
        id: uuid,
        nameCaller: callerName,
        appName: 'Talia',
        avatar: callerPhotoUrl,
        handle: callerId,
        type: callType == 'audio' ? 1 : 0, // 0 = video, 1 = audio
        duration: 60000, // 60 segundos timeout
        textAccept: 'Aceptar',
        textDecline: 'Rechazar',
        missedCallNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: true,
          subtitle: 'Llamada perdida',
          callbackText: 'Devolver llamada',
        ),
        extra: <String, dynamic>{
          ...?extraData,
          'callType': callType,
          'callerId': callerId,
          'callerName': callerName,
          'isEmergency': isEmergency,
        },
        headers: <String, dynamic>{
          'apiKey': 'talia_call_key',
          'platform': 'flutter',
        },
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#9D7FE8',
          backgroundUrl: '',
          actionColor: '#9D7FE8',
          incomingCallNotificationChannelName: 'Llamadas entrantes',
          missedCallNotificationChannelName: 'Llamadas perdidas',
        ),
        ios: const IOSParams(
          iconName: 'AppIcon',
          handleType: 'generic',
          supportsVideo: true,
          maximumCallGroups: 1,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'videoChat',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: false,
          supportsHolding: false,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      await FlutterCallkitIncoming.showCallkitIncoming(params);
      print('✅ CallKit mostrado: $uuid');
    } catch (e) {
      print('❌ Error mostrando CallKit: $e');
      rethrow;
    }
  }

  /// Finalizar llamada activa
  Future<void> endCall(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
      print('✅ Llamada finalizada: $callId');
    } catch (e) {
      print('❌ Error finalizando llamada: $e');
    }
  }

  /// Finalizar todas las llamadas activas
  Future<void> endAllCalls() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
      print('✅ Todas las llamadas finalizadas');
    } catch (e) {
      print('❌ Error finalizando todas las llamadas: $e');
    }
  }

  /// Obtener llamadas activas
  Future<List<dynamic>> getActiveCalls() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      return calls ?? [];
    } catch (e) {
      print('❌ Error obteniendo llamadas activas: $e');
      return [];
    }
  }

  /// Verificar si hay una llamada activa
  Future<bool> hasActiveCall() async {
    final calls = await getActiveCalls();
    return calls.isNotEmpty;
  }

  /// Limpiar y disponer recursos
  void dispose() {
    _callEventSubscription?.cancel();
    _callEventSubscription = null;
    print('🛑 CallKitService disposed');
  }
}
