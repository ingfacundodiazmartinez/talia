import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';
import '../utils/release_logger.dart';
import 'video_calls/services/call_state_service.dart';

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

  /// 🔒 LIFECYCLE MANAGEMENT para prevenir memory leaks
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Inicializar el servicio de CallKit
  void initialize({
    Function(Map<String, dynamic>)? onCallAccepted,
    Function(String)? onCallDeclined,
    Function(String)? onCallEnded,
  }) {
    // 🔒 Prevenir re-inicialización innecesaria
    if (_isInitialized) {
      ReleaseLogger.log('📞 CallKit Service ya estaba inicializado', tag: 'CallKitService');
      return;
    }

    ReleaseLogger.log('📞 Inicializando CallKit Service...', tag: 'CallKitService');

    _onCallAccepted = onCallAccepted;
    _onCallDeclined = onCallDeclined;
    _onCallEnded = onCallEnded;

    // Escuchar eventos de llamadas (con cleanup previo por seguridad)
    _callEventSubscription?.cancel();
    _callEventSubscription = FlutterCallkitIncoming.onEvent.listen((event) {
      _handleCallEvent(event!);
    });

    _isInitialized = true;
    ReleaseLogger.log('✅ CallKit Service inicializado exitosamente', tag: 'CallKitService');
  }

  /// Manejar eventos de llamadas
  void _handleCallEvent(CallEvent event) {
    ReleaseLogger.log('📞 CallKit event: ${event.event} - ${event.body}', tag: 'CallKitService');

    switch (event.event) {
      case Event.actionCallAccept:
        // Usuario aceptó la llamada
        ReleaseLogger.log('✅ Llamada aceptada', tag: 'CallKitService');
        if (_onCallAccepted != null && event.body != null) {
          _onCallAccepted!(event.body!);
        }
        break;

      case Event.actionCallDecline:
        // Usuario rechazó la llamada
        ReleaseLogger.log('❌ Llamada rechazada', tag: 'CallKitService');
        if (_onCallDeclined != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            _onCallDeclined!(callId);
          }
        }
        break;

      case Event.actionCallEnded:
        // Llamada terminada
        ReleaseLogger.log('🔚 Llamada terminada', tag: 'CallKitService');
        if (_onCallEnded != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            _onCallEnded!(callId);
          }
        }
        break;

      case Event.actionCallTimeout:
        // Llamada expiró (timeout)
        ReleaseLogger.log('⏱️ Llamada expiró', tag: 'CallKitService');
        if (_onCallDeclined != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            _onCallDeclined!(callId);
          }
        }
        break;

      default:
        ReleaseLogger.log('ℹ️ Evento no manejado: ${event.event}', tag: 'CallKitService');
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
        ReleaseLogger.log('📱 [iOS] Usando implementación nativa de CallKit vía Method Channel', tag: 'CallKitService');

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
          ReleaseLogger.log('✅ [iOS] CallKit UI mostrado desde AppDelegate nativo', tag: 'CallKitService');
        } catch (e) {
          ReleaseLogger.error('❌ [iOS] Error llamando a método nativo showIncomingCall: $e', tag: 'CallKitService');
          // Si falla, intentar con VoIP push como fallback
          ReleaseLogger.log('⚠️ [iOS] Esperando VoIP push notification para mostrar llamada', tag: 'CallKitService');
        }
        return;
      }

      // ANDROID: Continuar con flutter_callkit_incoming
      ReleaseLogger.log('📱 [Android] Usando flutter_callkit_incoming para mostrar llamada', tag: 'CallKitService');

      // Verificar llamadas activas primero
      List<dynamic> activeCalls = [];
      try {
        activeCalls = await FlutterCallkitIncoming.activeCalls();
        ReleaseLogger.log('📱 Llamadas activas antes de mostrar nueva: ${activeCalls.length}', tag: 'CallKitService');
      } catch (e) {
        ReleaseLogger.log('⚠️ Error obteniendo llamadas activas: $e', tag: 'CallKitService');
        // Asumir que no hay llamadas activas si falla
      }

      // Solo finalizar si hay llamadas activas
      if (activeCalls.isNotEmpty) {
        try {
          ReleaseLogger.log('🧹 Finalizando ${activeCalls.length} llamada(s) anterior(es)...', tag: 'CallKitService');
          await FlutterCallkitIncoming.endAllCalls();
          // Pequeño delay para que el sistema procese el cierre
          await Future.delayed(const Duration(milliseconds: 500));
          ReleaseLogger.log('✅ Llamadas anteriores finalizadas', tag: 'CallKitService');
        } catch (e) {
          ReleaseLogger.log('⚠️ Error finalizando llamadas anteriores: $e', tag: 'CallKitService');
          // Continuar de todas formas
        }
      }

      ReleaseLogger.log('📞 Preparando para mostrar llamada en Android...', tag: 'CallKitService');

      // Generar UUID único si no se proporciona
      final uuid = callId.isNotEmpty ? callId : const Uuid().v4();
      ReleaseLogger.log('🔑 UUID de llamada: $uuid', tag: 'CallKitService');

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

      ReleaseLogger.log('🚀 Llamando a FlutterCallkitIncoming.showCallkitIncoming()...', tag: 'CallKitService');
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      ReleaseLogger.log('✅ CallKit mostrado exitosamente: $uuid', tag: 'CallKitService');
    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ Error mostrando CallKit: $e', tag: 'CallKitService');
      ReleaseLogger.log('📍 Stack trace: $stackTrace', tag: 'CallKitService');
      ReleaseLogger.log('📦 Call data: callId=$callId, callerName=$callerName, callerId=$callerId', tag: 'CallKitService');
      // NO hacer rethrow para evitar crash de la app
      // En su lugar, loggear el error y continuar
    }
  }

  /// Finalizar llamada activa
  Future<void> endCall(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
      ReleaseLogger.log('✅ Llamada finalizada: $callId', tag: 'CallKitService');
    } catch (e) {
      ReleaseLogger.error('❌ Error finalizando llamada: $e', tag: 'CallKitService');
    }
  }

  /// Finalizar todas las llamadas activas
  Future<void> endAllCalls() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
      ReleaseLogger.log('✅ Todas las llamadas finalizadas', tag: 'CallKitService');
    } catch (e) {
      ReleaseLogger.error('❌ Error finalizando todas las llamadas: $e', tag: 'CallKitService');
    }
  }

  /// Obtener llamadas activas
  Future<List<dynamic>> getActiveCalls() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      return calls ?? [];
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo llamadas activas: $e', tag: 'CallKitService');
      return [];
    }
  }

  /// Verificar si hay una llamada activa
  Future<bool> hasActiveCall() async {
    final calls = await getActiveCalls();
    return calls.isNotEmpty;
  }

  /// Limpiar y disponer recursos
  /// 🔒 LIFECYCLE MANAGEMENT: Limpiar recursos y permitir re-inicialización
  void dispose() {
    ReleaseLogger.log('🗑️ Limpiando recursos CallKit Service...', tag: 'CallKitService');

    _callEventSubscription?.cancel();
    _callEventSubscription = null;

    _onCallAccepted = null;
    _onCallDeclined = null;
    _onCallEnded = null;

    _isInitialized = false;

    ReleaseLogger.log('✅ CallKit Service resources disposed', tag: 'CallKitService');
  }

  /// 🔒 BACKGROUND LIFECYCLE: Limpiar recursos cuando la app va a background
  void onAppPaused() {
    ReleaseLogger.log('⏸️ CallKit Service: App pausada, manteniendo CallKit activo para llamadas', tag: 'CallKitService');
    // CallKit debe seguir funcionando en background para recibir llamadas
  }

  /// 🔒 FOREGROUND LIFECYCLE: Re-conectar cuando la app vuelve de background
  Future<void> onAppResumed() async {
    ReleaseLogger.log('▶️ CallKit Service: App resumida', tag: 'CallKitService');

    // Re-inicializar si es necesario (callbacks podrían haberse perdido)
    if (!_isInitialized) {
      ReleaseLogger.log('⚠️ CallKit Service requiere re-inicialización manual', tag: 'CallKitService');
    }
  }

  /// Iniciar monitoreo de cancelación para una llamada específica
  void _startCallCancellationMonitoring(String callId) {
    try {
      ReleaseLogger.log('🔍 [CallKit] Iniciando monitoreo de cancelación para: $callId', tag: 'CallKitService');

      // Importar CallStateService dinámicamente para evitar dependencia circular
      final callStateService = _getCallStateService();
      if (callStateService != null) {
        callStateService.startMonitoringCall(callId);
        ReleaseLogger.log('✅ [CallKit] Monitoreo de cancelación iniciado para: $callId', tag: 'CallKitService');
      } else {
        ReleaseLogger.log('⚠️ [CallKit] CallStateService no disponible - no se puede monitorear cancelación', tag: 'CallKitService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error iniciando monitoreo de cancelación: $e', tag: 'CallKitService');
    }
  }

  /// Helper para obtener CallStateService sin dependencia circular
  dynamic _getCallStateService() {
    try {
      // Crear instancia directa de CallStateService (singleton)
      return CallStateService();
    } catch (e) {
      ReleaseLogger.log('⚠️ [CallKit] Error obteniendo CallStateService: $e', tag: 'CallKitService');
      return null;
    }
  }
}
