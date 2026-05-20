import 'dart:async';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';
import '../utils/release_logger.dart';

// Method channel para comunicación con AppDelegate nativo (iOS) - removido por no uso

/// Servicio para manejar llamadas entrantes con CallKit (iOS) y ConnectionService (Android)
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
  Function(String)? onCallKitShown;

  /// 🔒 LIFECYCLE MANAGEMENT para prevenir memory leaks
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Inicializar el servicio de CallKit
  Future<void> initialize({
    Function(Map<String, dynamic>)? onCallAccepted,
    Function(String)? onCallDeclined,
    Function(String)? onCallEnded,
    Function(String)? onCallKitShown,
  }) async {
    // 🔒 Prevenir re-inicialización innecesaria
    if (_isInitialized) {
      ReleaseLogger.log('📞 CallKit Service ya estaba inicializado', tag: 'CallKitService');
      return;
    }

    ReleaseLogger.log('📞 Inicializando CallKit Service...', tag: 'CallKitService');

    _onCallAccepted = onCallAccepted;
    _onCallDeclined = onCallDeclined;
    _onCallEnded = onCallEnded;
    this.onCallKitShown = onCallKitShown;

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

      case Event.actionCallIncoming:
        // CallKit se mostró exitosamente
        ReleaseLogger.log('📞 CallKit mostrado - evento incoming', tag: 'CallKitService');
        if (onCallKitShown != null && event.body != null) {
          final callId = event.body!['id'] as String?;
          if (callId != null) {
            onCallKitShown!(callId);
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
      ReleaseLogger.log('📞 [CallKeep] Mostrando llamada entrante: $callId', tag: 'CallKitService');
      ReleaseLogger.log('🔍 [CallKeep Debug] callType: "$callType", caller: $callerName', tag: 'CallKitService');
      ReleaseLogger.log('🖼️ [CallKeep Debug] callerPhotoUrl: ${callerPhotoUrl ?? "Sin foto"}', tag: 'CallKitService');

      // Generar UUID único si no se proporciona
      final uuid = callId.isNotEmpty ? callId : const Uuid().v4();

      // Determinar si es llamada grupal por el tipo de datos extra
      final isGroupCall = extraData?['isGroupCall'] == true ||
                         extraData?['groupName'] != null ||
                         callType.contains('group');

      // Para llamadas individuales: usar foto del caller
      // Para llamadas grupales: usar ícono de la app
      String? avatarUrl;
      if (isGroupCall) {
        // Llamada grupal - usar ícono de app (null para que use el default)
        avatarUrl = null;
        ReleaseLogger.log('👥 [CallKeep] Llamada grupal detectada - usando ícono de app', tag: 'CallKitService');
      } else {
        // Llamada individual - usar foto del caller
        avatarUrl = callerPhotoUrl;
        ReleaseLogger.log('👤 [CallKeep] Llamada individual - usando foto del caller: ${avatarUrl ?? "Sin foto"}', tag: 'CallKitService');
      }

      // ✅ FIX APLICADO: Bug de textAccept resuelto en versión local
      final isAudioCall = (callType == 'audio');
      String displayName = callerName;

      // 🔍 DEBUG: Logging para depurar el problema
      ReleaseLogger.log('🔍 [CallKit DEBUG] callType="$callType", isAudioCall=$isAudioCall', tag: 'CallKitService');

      final params = CallKitParams(
        id: uuid,
        nameCaller: displayName,
        appName: 'Tália',
        avatar: avatarUrl, // Foto del caller o null para grupales
        handle: displayName, // ✅ FIX: Use nombre en lugar de UID para Android ConnectionService
        type: isAudioCall ? 1 : 0, // 1 = audio, 0 = video
        duration: 60000,
        textAccept: isAudioCall ? 'Audio' : 'Video',
        textDecline: 'Rechazar',
        missedCallNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: true,
          subtitle: 'Llamada perdida',
          callbackText: 'Devolver llamada',
        ),
        extra: <String, dynamic>{
          'callType': callType,
          'callerId': callerId,
          'callerName': callerName,
          'isGroupCall': isGroupCall,
        },
        android: AndroidParams(
          isCustomNotification: false, // ✅ FIX: Use solo notificación nativa del sistema (ConnectionService)
          isShowLogo: true,
          ringtonePath: 'default',
          backgroundColor: '#9D7FE8',
          actionColor: '#9D7FE8',
          incomingCallNotificationChannelName: 'Llamadas entrantes',
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
          ringtonePath: '',
        ),
      );

      ReleaseLogger.log('🚀 [CallKit] Mostrando CallKit con: isAudioCall=$isAudioCall, textAccept=${params.textAccept}, displayName=$displayName', tag: 'CallKitService');
      await FlutterCallkitIncoming.showCallkitIncoming(params);

      ReleaseLogger.log('✅ [CallKeep] Llamada mostrada exitosamente: $uuid', tag: 'CallKitService');

      // Notificar que CallKit se mostró
      if (onCallKitShown != null) {
        onCallKitShown!(uuid);
      }

    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ Error mostrando CallKeep: $e', tag: 'CallKitService');
      ReleaseLogger.log('📍 Stack trace: $stackTrace', tag: 'CallKitService');
      ReleaseLogger.log('📦 Call data: callId=$callId, callerName=$callerName, callerId=$callerId', tag: 'CallKitService');
      // NO hacer rethrow para evitar crash de la app
    }
  }

  /// Finalizar llamada activa
  Future<void> endCall(String callId) async {
    try {
      ReleaseLogger.log('🔍 [DEBUG] CallKitService.endCall called for callId: $callId', tag: 'CallKitService');
      await FlutterCallkitIncoming.endCall(callId);
      ReleaseLogger.log('✅ Llamada finalizada: $callId', tag: 'CallKitService');
      ReleaseLogger.log('✅ [DEBUG] CallKitService.endCall completed successfully for $callId', tag: 'CallKitService');
    } catch (e) {
      ReleaseLogger.error('❌ Error finalizando llamada: $e', tag: 'CallKitService');
      ReleaseLogger.error('❌ [DEBUG] CallKitService.endCall failed for $callId: $e', tag: 'CallKitService');
    }
  }

  /// Finalizar todas las llamadas activas
  Future<void> endAllCalls() async {
    try {
      ReleaseLogger.log('🔍 [DEBUG] CallKitService.endAllCalls called', tag: 'CallKitService');
      await FlutterCallkitIncoming.endAllCalls();
      ReleaseLogger.log('✅ Todas las llamadas finalizadas', tag: 'CallKitService');
      ReleaseLogger.log('✅ [DEBUG] CallKitService.endAllCalls completed successfully', tag: 'CallKitService');
    } catch (e) {
      ReleaseLogger.error('❌ Error finalizando todas las llamadas: $e', tag: 'CallKitService');
      ReleaseLogger.error('❌ [DEBUG] CallKitService.endAllCalls failed: $e', tag: 'CallKitService');
    }
  }

  /// Obtener llamadas activas
  Future<List<dynamic>> getActiveCalls() async {
    try {
      ReleaseLogger.log('🔍 [DEBUG] CallKitService.getActiveCalls called', tag: 'CallKitService');
      final calls = await FlutterCallkitIncoming.activeCalls();
      ReleaseLogger.log('🔍 [DEBUG] CallKitService.getActiveCalls result: ${calls?.length ?? 0} calls', tag: 'CallKitService');
      return calls ?? [];
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo llamadas activas: $e', tag: 'CallKitService');
      ReleaseLogger.error('❌ [DEBUG] CallKitService.getActiveCalls failed: $e', tag: 'CallKitService');
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

    // Cancelar subscription de eventos de llamadas
    _callEventSubscription?.cancel();
    _callEventSubscription = null;

    _onCallAccepted = null;
    _onCallDeclined = null;
    _onCallEnded = null;
    onCallKitShown = null;

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

}
