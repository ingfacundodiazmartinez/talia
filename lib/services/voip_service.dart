import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'video_call_service.dart';
import 'package:flutter/material.dart';
import '../screens/video_call_screen.dart';
import '../screens/audio_call_screen.dart';
import '../utils/release_logger.dart';

class VoIPService {
  static final VoIPService _instance = VoIPService._internal();
  factory VoIPService() => _instance;
  VoIPService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const MethodChannel _voipChannel = MethodChannel('com.talia.chat/voip');
  StreamSubscription<CallEvent?>? _callEventSubscription;

  // Stream para notificar cuando hay llamadas pendientes
  final StreamController<Map<String, dynamic>> _pendingCallNotifier = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get pendingCallStream => _pendingCallNotifier.stream;

  /// Inicializar VoIP Push y CallKit
  Future<void> initialize() async {
    try {
      ReleaseLogger.log('📱 Inicializando VoIP Service...', tag: 'VoIPService');

      // Configurar listener para el token VoIP desde iOS
      _voipChannel.setMethodCallHandler(_handleVoIPMethodCall);

      // Escuchar eventos de CallKit
      _callEventSubscription = FlutterCallkitIncoming.onEvent.listen(_handleCallKitEvent);

      ReleaseLogger.log('✅ VoIP Service inicializado', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ Error inicializando VoIP Service: $e', tag: 'VoIPService');
    }
  }

  /// Manejar llamadas de método desde iOS (ej: token VoIP)
  Future<dynamic> _handleVoIPMethodCall(MethodCall call) async {
    ReleaseLogger.log('📱 [VoIP] Método recibido: ${call.method}', tag: 'VoIPService');

    switch (call.method) {
      case 'onVoipToken':
        final String token = call.arguments as String;
        ReleaseLogger.log('📱 [VoIP] Token recibido: ${token.substring(0, 20)}...', tag: 'VoIPService');
        await _saveVoIPToken(token);
        break;

      case 'onIncomingCall':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        ReleaseLogger.log('📞 [VoIP] Llamada entrante desde CallKit nativo', tag: 'VoIPService');
        ReleaseLogger.log('📞 [VoIP] Datos: $data', tag: 'VoIPService');
        // Los datos ya están siendo manejados por el listener de Firestore
        break;

      case 'onCallAccepted':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('✅ [VoIP] Llamada aceptada desde CallKit nativo: $callId', tag: 'VoIPService');

        // Buscar la llamada en Firestore para obtener los datos completos
        await _handleNativeCallAccepted(callId);
        break;

      case 'onCallEnded':
        final Map<dynamic, dynamic> data = call.arguments as Map<dynamic, dynamic>;
        final String callId = data['callId'] as String;
        ReleaseLogger.log('📵 [VoIP] Llamada terminada desde CallKit nativo: $callId', tag: 'VoIPService');

        // NO llamar a endCall() - solo cerrar CallKit localmente
        // Si la llamada fue cancelada por el caller, el listener ya cerró el CallKit
        // Si el receptor presiona "rechazar", debe usar rejectCall() en lugar de endCall()
        ReleaseLogger.log('ℹ️ [VoIP] CallKit cerrado localmente, sin modificar Firestore', tag: 'VoIPService');
        break;

      default:
        ReleaseLogger.log('⚠️ [VoIP] Método desconocido: ${call.method}', tag: 'VoIPService');
    }
  }

  /// Manejar aceptación de llamada desde CallKit nativo
  Future<void> _handleNativeCallAccepted(String callId) async {
    try {
      ReleaseLogger.log('🔍 [VoIP] Buscando datos de llamada: $callId', tag: 'VoIPService');

      // Buscar la llamada en Firestore
      final callDoc = await _firestore.collection('video_calls').doc(callId).get();

      if (!callDoc.exists) {
        ReleaseLogger.error('❌ [VoIP] Llamada no encontrada en Firestore', tag: 'VoIPService');
        return;
      }

      final callData = callDoc.data()!;
      final callerId = callData['callerId'] as String;
      final callerName = callData['callerName'] as String;
      final channelName = callData['channelName'] as String;
      final callType = callData['callType'] as String?;

      ReleaseLogger.log('📞 [VoIP] Procesando llamada aceptada:', tag: 'VoIPService');
      ReleaseLogger.log('   - Call ID: $callId', tag: 'VoIPService');
      ReleaseLogger.log('   - Channel: $channelName', tag: 'VoIPService');
      ReleaseLogger.log('   - Type: $callType', tag: 'VoIPService');

      // Actualizar estado en Firestore
      await VideoCallService().acceptCall(callId);

      // Obtener token de Agora directamente (sin crear nueva llamada)
      ReleaseLogger.log('🎫 [VoIP] Generando token de Agora para unirse al canal: $channelName', tag: 'VoIPService');
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('generateAgoraToken').call({
        'channelName': channelName,
        'uid': 0, // Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      ReleaseLogger.log('✅ [VoIP] Token generado - UID: $uid', tag: 'VoIPService');

      // Guardar datos para navegación
      _pendingCallData = {
        'callId': callId,
        'channelName': channelName,
        'token': token,
        'uid': uid,
        'callType': callType,
        'callerName': callerName,
        'callerId': callerId, // Agregar callerId para la navegación
      };

      ReleaseLogger.log('✅ [VoIP] Datos de llamada guardados para navegación', tag: 'VoIPService');
      ReleaseLogger.log('   - Caller ID: $callerId', tag: 'VoIPService');

      // Notificar inmediatamente que hay datos pendientes
      _pendingCallNotifier.add(_pendingCallData!);

      // Limpiar inmediatamente para evitar navegación duplicada
      _pendingCallData = null;
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error manejando aceptación nativa: $e', tag: 'VoIPService');
    }
  }

  /// Verificar y procesar token VoIP pendiente después del login exitoso
  /// En iOS, el token VoIP se recibe automáticamente pero solo se puede guardar cuando el usuario está autenticado
  Future<void> processVoIPTokenAfterLogin() async {
    try {
      print('📱 [VoIP] Verificando token VoIP pendiente después del login...');

      if (_auth.currentUser == null) {
        print('⚠️ [VoIP] Usuario no autenticado, no se puede procesar token');
        return;
      }

      // En iOS, el token se maneja automáticamente por el AppDelegate
      // Este método está aquí para mantener consistencia con el FCM token
      // y por si necesitamos agregar lógica adicional en el futuro
      print('✅ [VoIP] Usuario autenticado - el token VoIP se procesará automáticamente cuando iOS lo envíe');
    } catch (e) {
      print('❌ [VoIP] Error procesando token: $e');
    }
  }

  /// Guardar token VoIP en Firestore
  Future<void> _saveVoIPToken(String token) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        print('⚠️ [VoIP] Usuario no autenticado, no se puede guardar token');
        return;
      }

      // Limpiar tokens VoIP duplicados antes de guardar el nuevo
      await _cleanupDuplicateVoIPTokens(token);

      await _firestore.collection('users').doc(userId).update({
        'voipToken': token,
        'voipTokenUpdatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ [VoIP] Token guardado en Firestore');
    } catch (e) {
      print('❌ [VoIP] Error guardando token: $e');
    }
  }

  /// Limpiar tokens VoIP duplicados de otros usuarios
  /// Esto previene que las notificaciones VoIP lleguen a usuarios anteriores del mismo dispositivo
  Future<void> _cleanupDuplicateVoIPTokens(String newToken) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      print('🧹 [VoIP] Verificando tokens VoIP duplicados para: ${newToken.substring(0, 20)}...');

      // Buscar otros usuarios que tengan el mismo token VoIP
      final duplicateUsersQuery = await _firestore
          .collection('users')
          .where('voipToken', isEqualTo: newToken)
          .get();

      int cleanedCount = 0;
      for (final doc in duplicateUsersQuery.docs) {
        final userId = doc.id;
        // No limpiar el token del usuario actual
        if (userId == currentUserId) continue;

        // Limpiar token del usuario anterior
        await _firestore.collection('users').doc(userId).update({
          'voipToken': FieldValue.delete(),
          'voipTokenClearedAt': FieldValue.serverTimestamp(),
          'voipTokenClearedReason': 'duplicate_token_cleanup',
        });
        cleanedCount++;
        print('🗑️ [VoIP] Token VoIP limpiado del usuario anterior: $userId');
      }

      if (cleanedCount > 0) {
        print('✅ [VoIP] Se limpiaron $cleanedCount tokens VoIP duplicados');
      } else {
        print('✅ [VoIP] No se encontraron tokens VoIP duplicados');
      }
    } catch (e) {
      print('❌ [VoIP] Error limpiando tokens duplicados: $e');
    }
  }

  /// Manejar eventos de CallKit (aceptar, rechazar, colgar)
  Future<void> _handleCallKitEvent(CallEvent? event) async {
    if (event == null) return;

    print('📱 [CallKit] Evento recibido: ${event.event}');
    print('📱 [CallKit] Datos: ${event.body}');

    switch (event.event) {
      case Event.actionCallAccept:
        await _handleCallAccepted(event.body);
        break;

      case Event.actionCallDecline:
        await _handleCallDeclined(event.body);
        break;

      case Event.actionCallEnded:
        await _handleCallEnded(event.body);
        break;

      case Event.actionCallTimeout:
        print('⏰ [CallKit] Llamada timeout');
        break;

      default:
        print('⚠️ [CallKit] Evento desconocido: ${event.event}');
    }
  }

  /// Cuando el usuario acepta la llamada desde CallKit
  Future<void> _handleCallAccepted(Map<String, dynamic>? data) async {
    try {
      print('✅ [CallKit] Llamada aceptada');

      if (data == null || data['extra'] == null) {
        print('❌ [CallKit] Datos de llamada inválidos');
        return;
      }

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;
      final callerId = extra['callerId'] as String;
      final callerName = extra['callerName'] as String;
      final channelName = extra['channelName'] as String;
      final callType = extra['callType'] as String?;
      final isEmergency = extra['isEmergency'] == 'true';

      print('📞 [CallKit] Procesando llamada aceptada:');
      print('   - Call ID: $callId');
      print('   - Channel: $channelName');
      print('   - Type: $callType');
      print('   - Emergency: $isEmergency');

      // Actualizar estado en Firestore
      await VideoCallService().acceptCall(callId);

      // Obtener token de Agora directamente (sin crear nueva llamada)
      print('🎫 [CallKit] Generando token de Agora para unirse al canal: $channelName');
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('generateAgoraToken').call({
        'channelName': channelName,
        'uid': 0, // Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      print('✅ [CallKit] Token generado - UID: $uid');

      // Navegar a pantalla de llamada
      // Nota: Necesitamos acceso al BuildContext, lo manejaremos desde main.dart
      // Por ahora solo guardamos los datos para que main.dart los procese
      _pendingCallData = {
        'callId': callId,
        'channelName': channelName,
        'token': token,
        'uid': uid,
        'callType': callType,
        'callerName': callerName,
        'callerId': callerId, // Agregar callerId para la navegación
      };

      print('✅ [CallKit] Datos de llamada guardados para navegación');
      print('   - Caller ID: $callerId');

      // Notificar inmediatamente que hay datos pendientes
      _pendingCallNotifier.add(_pendingCallData!);

      // Limpiar inmediatamente para evitar navegación duplicada
      _pendingCallData = null;
    } catch (e) {
      print('❌ [CallKit] Error manejando aceptación: $e');
    }
  }

  /// Cuando el usuario rechaza la llamada desde CallKit
  Future<void> _handleCallDeclined(Map<String, dynamic>? data) async {
    try {
      print('❌ [CallKit] Llamada rechazada');

      if (data == null || data['extra'] == null) return;

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;

      await VideoCallService().rejectCall(callId);
      print('✅ [CallKit] Llamada rechazada en Firestore');
    } catch (e) {
      print('❌ [CallKit] Error manejando rechazo: $e');
    }
  }

  /// Cuando la llamada termina desde CallKit
  Future<void> _handleCallEnded(Map<String, dynamic>? data) async {
    try {
      print('📵 [CallKit] Llamada terminada');

      if (data == null || data['extra'] == null) return;

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;

      // NO llamar a endCall() - solo cerrar CallKit localmente
      // VoIP maneja el cierre automáticamente cuando detecta cambios en Firestore
      print('ℹ️ [CallKit] CallKit cerrado localmente para: $callId');
      print('ℹ️ [CallKit] Si la llamada fue cancelada, el listener ya lo detectó');
    } catch (e) {
      print('❌ [CallKit] Error manejando fin de llamada: $e');
    }
  }

  // Datos de llamada pendiente para navegación
  Map<String, dynamic>? _pendingCallData;

  /// Obtener y limpiar datos de llamada pendiente
  Map<String, dynamic>? getPendingCallData() {
    final data = _pendingCallData;
    _pendingCallData = null;
    return data;
  }

  /// Notificar a iOS nativo que la llamada terminó (para cerrar CallKit UI)
  Future<void> notifyCallEnded(String callId) async {
    try {
      await _voipChannel.invokeMethod('endCallKit', {'callId': callId});
      print('✅ [VoIP] Notificado a iOS que la llamada terminó: $callId');
    } catch (e) {
      print('❌ [VoIP] Error notificando fin de llamada a iOS: $e');
    }
  }

  /// Limpiar recursos
  void dispose() {
    _callEventSubscription?.cancel();
    _pendingCallNotifier.close();
  }
}
