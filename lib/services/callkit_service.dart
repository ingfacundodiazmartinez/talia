import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';

// Method channel para comunicación con AppDelegate nativo (iOS)
const MethodChannel _nativeCallKitChannel = MethodChannel('com.talia.chat/callkit');

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
      // SOLUCIÓN AL CRASH: En iOS, usar el CXProvider nativo de AppDelegate
      // No usar flutter_callkit_incoming porque crea conflictos con CXProvider
      if (Platform.isIOS) {
        print('📱 [iOS] Usando implementación nativa de CallKit vía Method Channel');

        try {
          // Llamar al AppDelegate nativo para mostrar CallKit UI
          await _nativeCallKitChannel.invokeMethod('showIncomingCall', {
            'callId': callId,
            'callerId': callerId,
            'callerName': callerName,
            'callerPhotoURL': callerPhotoUrl ?? '',
            'callType': callType,
            'isEmergency': isEmergency,
            'channelName': extraData?['channelName'] ?? callId,
          });
          print('✅ [iOS] CallKit UI mostrado desde AppDelegate nativo');
        } catch (e) {
          print('❌ [iOS] Error llamando a método nativo showIncomingCall: $e');
          // Si falla, intentar con VoIP push como fallback
          print('⚠️ [iOS] Esperando VoIP push notification para mostrar llamada');
        }
        return;
      }

      // ANDROID: Continuar con flutter_callkit_incoming
      print('📱 [Android] Usando flutter_callkit_incoming para mostrar llamada');

      // Verificar llamadas activas primero
      List<dynamic> activeCalls = [];
      try {
        activeCalls = await FlutterCallkitIncoming.activeCalls();
        print('📱 Llamadas activas antes de mostrar nueva: ${activeCalls.length}');
      } catch (e) {
        print('⚠️ Error obteniendo llamadas activas: $e');
        // Asumir que no hay llamadas activas si falla
      }

      // Solo finalizar si hay llamadas activas
      if (activeCalls.isNotEmpty) {
        try {
          print('🧹 Finalizando ${activeCalls.length} llamada(s) anterior(es)...');
          await FlutterCallkitIncoming.endAllCalls();
          // Pequeño delay para que el sistema procese el cierre
          await Future.delayed(const Duration(milliseconds: 500));
          print('✅ Llamadas anteriores finalizadas');
        } catch (e) {
          print('⚠️ Error finalizando llamadas anteriores: $e');
          // Continuar de todas formas
        }
      }

      print('📞 Preparando para mostrar llamada en Android...');

      // Generar UUID único si no se proporciona
      final uuid = callId.isNotEmpty ? callId : const Uuid().v4();
      print('🔑 UUID de llamada: $uuid');

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
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
          ringtonePath: 'default',  // Usar tono predeterminado del sistema
          backgroundColor: '#9D7FE8',
          backgroundUrl: '',
          actionColor: '#9D7FE8',
          incomingCallNotificationChannelName: 'Llamadas entrantes',
          missedCallNotificationChannelName: 'Llamadas perdidas',
          isShowCallID: false,  // Evitar conflictos de UI
        ),
        ios: IOSParams(
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
          ringtonePath: '',  // Dejar vacío para evitar banner de audio UNKNOWN_DURATION
        ),
      );

      print('🚀 Llamando a FlutterCallkitIncoming.showCallkitIncoming()...');
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      print('✅ CallKit mostrado exitosamente: $uuid');
    } catch (e, stackTrace) {
      print('❌ Error mostrando CallKit: $e');
      print('📍 Stack trace: $stackTrace');
      print('📦 Call data: callId=$callId, callerName=$callerName, callerId=$callerId');
      // NO hacer rethrow para evitar crash de la app
      // En su lugar, loggear el error y continuar
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
