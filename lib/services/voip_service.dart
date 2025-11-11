import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'video_call_service.dart';
import 'app_state_service.dart';
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
  StreamController<Map<String, dynamic>>? _pendingCallNotifier;
  Stream<Map<String, dynamic>> get pendingCallStream {
    _pendingCallNotifier ??= StreamController<Map<String, dynamic>>.broadcast();
    return _pendingCallNotifier!.stream;
  }

  // 🔄 COORDINACIÓN: Track de llamadas activas desde VoIP/CallKit
  final Set<String> _voipActiveCallIds = <String>{};

  /// Verificar si una llamada está siendo manejada por VoIP/CallKit
  bool isCallHandledByVoIP(String callId) {
    return _voipActiveCallIds.contains(callId);
  }

  /// Marcar llamada como manejada por VoIP (para evitar IncomingCallScreen)
  void markCallAsVoIPHandled(String callId) {
    _voipActiveCallIds.add(callId);
    ReleaseLogger.log('📞 [VOIP COORDINATION] Llamada $callId marcada como manejada por VoIP', tag: 'VoIPService');
  }

  /// Desmarcar llamada cuando termine
  void unmarkVoIPCall(String callId) {
    _voipActiveCallIds.remove(callId);
    ReleaseLogger.log('📞 [VOIP COORDINATION] Llamada $callId desmarcada de VoIP', tag: 'VoIPService');
  }

  // 🔒 LIFECYCLE MANAGEMENT para prevenir memory leaks
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Inicializar VoIP Push y CallKit
  Future<void> initialize() async {
    try {
      // 🔒 Prevenir re-inicialización innecesaria
      if (_isInitialized) {
        ReleaseLogger.log('📱 VoIP Service ya estaba inicializado', tag: 'VoIPService');
        // ✅ CRÍTICO: Aún verificar estado del token en reinicializaciones
        await _validateExistingVoIPToken();
        return;
      }

      ReleaseLogger.log('📱 Inicializando VoIP Service...', tag: 'VoIPService');

      // Configurar listener para el token VoIP desde iOS
      _voipChannel.setMethodCallHandler(_handleVoIPMethodCall);

      // Escuchar eventos de CallKit (con cleanup previo por seguridad)
      _callEventSubscription?.cancel();
      _callEventSubscription = FlutterCallkitIncoming.onEvent.listen(_handleCallKitEvent);

      // ✅ INTELIGENTE: Solo validar token existente, no forzar refresh inmediato
      await _validateExistingVoIPToken();

      _isInitialized = true;

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
      _pendingCallNotifier?.add(_pendingCallData!);

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
      ReleaseLogger.log('📱[VoIP] Verificando token VoIP pendiente después del login...', tag: 'VoIPService');

      if (_auth.currentUser == null) {
        ReleaseLogger.log('⚠️ [VoIP] Usuario no autenticado, no se puede procesar token', tag: 'VoIPService');
        return;
      }

      // En iOS, el token se maneja automáticamente por el AppDelegate
      // Este método está aquí para mantener consistencia con el FCM token
      // y por si necesitamos agregar lógica adicional en el futuro
      ReleaseLogger.log('✅ [VoIP] Usuario autenticado - el token VoIP se procesará automáticamente cuando iOS lo envíe', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error procesando token: $e', tag: 'VoIPService');
    }
  }

  /// Guardar token VoIP en Firestore
  Future<void> _saveVoIPToken(String token) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        ReleaseLogger.log('⚠️ [VoIP] Usuario no autenticado, no se puede guardar token', tag: 'VoIPService');
        return;
      }

      // Limpiar tokens VoIP duplicados antes de guardar el nuevo
      await _cleanupDuplicateVoIPTokens(token);

      await _firestore.collection('users').doc(userId).update({
        'voipToken': token,
        'voipTokenUpdatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('✅ [VoIP] Token guardado en Firestore', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error guardando token: $e', tag: 'VoIPService');
    }
  }

  /// Limpiar tokens VoIP duplicados de otros usuarios
  /// Esto previene que las notificaciones VoIP lleguen a usuarios anteriores del mismo dispositivo
  Future<void> _cleanupDuplicateVoIPTokens(String newToken) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      ReleaseLogger.log('🧹 [VoIP] Verificando tokens VoIP duplicados para: ${newToken.substring(0, 20)}...', tag: 'VoIPService');

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
        ReleaseLogger.log('🗑️ [VoIP] Token VoIP limpiado del usuario anterior: $userId', tag: 'VoIPService');
      }

      if (cleanedCount > 0) {
        ReleaseLogger.log('✅ [VoIP] Se limpiaron $cleanedCount tokens VoIP duplicados', tag: 'VoIPService');
      } else {
        ReleaseLogger.log('✅ [VoIP] No se encontraron tokens VoIP duplicados', tag: 'VoIPService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error limpiando tokens duplicados: $e', tag: 'VoIPService');
    }
  }

  /// Manejar eventos de CallKit (aceptar, rechazar, colgar)
  Future<void> _handleCallKitEvent(CallEvent? event) async {
    if (event == null) return;

    ReleaseLogger.log('📱[CallKit] Evento recibido: ${event.event}');
    ReleaseLogger.log('📱[CallKit] Datos: ${event.body}');

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
        ReleaseLogger.log('⏰ [CallKit] Llamada timeout', tag: 'VoIPService');
        break;

      default:
        ReleaseLogger.log('⚠️ [CallKit] Evento desconocido: ${event.event}', tag: 'VoIPService');
    }
  }

  /// Cuando el usuario acepta la llamada desde CallKit
  Future<void> _handleCallAccepted(Map<String, dynamic>? data) async {
    try {
      ReleaseLogger.log('✅ [CallKit] Llamada aceptada', tag: 'VoIPService');

      if (data == null || data['extra'] == null) {
        ReleaseLogger.error('❌ [CallKit] Datos de llamada inválidos', tag: 'VoIPService');
        return;
      }

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;
      final callerId = extra['callerId'] as String;
      final callerName = extra['callerName'] as String;
      final channelName = extra['channelName'] as String;
      final callType = extra['callType'] as String?;
      final isEmergency = extra['isEmergency'] == 'true';

      // 📞 CRÍTICO: Marcar como manejada por VoIP para evitar conflictos
      markCallAsVoIPHandled(callId);

      ReleaseLogger.log('📞 [CallKit] Procesando llamada aceptada:', tag: 'VoIPService');
      ReleaseLogger.log('   - Call ID: $callId', tag: 'VoIPService');
      ReleaseLogger.log('   - Channel: $channelName', tag: 'VoIPService');
      ReleaseLogger.log('   - Type: $callType', tag: 'VoIPService');
      ReleaseLogger.log('   - Emergency: $isEmergency', tag: 'VoIPService');

      // Actualizar estado en Firestore
      await VideoCallService().acceptCall(callId);

      // Obtener token de Agora directamente (sin crear nueva llamada)
      ReleaseLogger.log('🎫 [CallKit] Generando token de Agora para unirse al canal: $channelName', tag: 'VoIPService');
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('generateAgoraToken').call({
        'channelName': channelName,
        'uid': 0, // Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      ReleaseLogger.log('✅ [CallKit] Token generado - UID: $uid', tag: 'VoIPService');

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

      ReleaseLogger.log('✅ [CallKit] Datos de llamada guardados para navegación', tag: 'VoIPService');
      ReleaseLogger.log('   - Caller ID: $callerId', tag: 'VoIPService');

      // Notificar inmediatamente que hay datos pendientes
      _pendingCallNotifier?.add(_pendingCallData!);

      // Limpiar inmediatamente para evitar navegación duplicada
      _pendingCallData = null;
    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error manejando aceptación: $e', tag: 'VoIPService');
    }
  }

  /// Cuando el usuario rechaza la llamada desde CallKit
  Future<void> _handleCallDeclined(Map<String, dynamic>? data) async {
    try {
      ReleaseLogger.log('❌ [CallKit] Llamada rechazada', tag: 'VoIPService');

      if (data == null || data['extra'] == null) return;

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;

      // ✅ CRÍTICO: Rechazar en Firestore
      await VideoCallService().rejectCall(callId);
      ReleaseLogger.log('✅ [CallKit] Llamada rechazada en Firestore', tag: 'VoIPService');

      // ✅ FIX: Cerrar CallKit UI inmediatamente después del rechazo
      await notifyCallEnded(callId);
      ReleaseLogger.log('✅ [CallKit] CallKit UI cerrado tras rechazo', tag: 'VoIPService');

    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error manejando rechazo: $e', tag: 'VoIPService');

      // ✅ FALLBACK: Incluso si hay error, intentar cerrar CallKit
      if (data?['extra']?['callId'] != null) {
        try {
          await notifyCallEnded(data!['extra']['callId']);
          ReleaseLogger.log('✅ [CallKit] CallKit cerrado en fallback tras error', tag: 'VoIPService');
        } catch (fallbackError) {
          ReleaseLogger.error('❌ [CallKit] Error en fallback: $fallbackError', tag: 'VoIPService');
        }
      }
    }
  }

  /// Cuando la llamada termina desde CallKit
  Future<void> _handleCallEnded(Map<String, dynamic>? data) async {
    try {
      ReleaseLogger.log('📵 [CallKit] Llamada terminada', tag: 'VoIPService');

      if (data == null || data['extra'] == null) return;

      final extra = data['extra'] as Map<String, dynamic>;
      final callId = extra['callId'] as String;

      // NO llamar a endCall() - solo cerrar CallKit localmente
      // VoIP maneja el cierre automáticamente cuando detecta cambios en Firestore
      ReleaseLogger.log('ℹ️ [CallKit] CallKit cerrado localmente para: $callId', tag: 'VoIPService');
      ReleaseLogger.log('ℹ️ [CallKit] Si la llamada fue cancelada, el listener ya lo detectó', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [CallKit] Error manejando fin de llamada: $e', tag: 'VoIPService');
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

      // 🔄 CLEANUP: Desmarcar llamada del tracking VoIP
      unmarkVoIPCall(callId);

      ReleaseLogger.log('✅ [VoIP] Notificado a iOS que la llamada terminó: $callId', tag: 'VoIPService');
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP] Error notificando fin de llamada a iOS: $e', tag: 'VoIPService');
    }
  }

  /// ✅ CRÍTICO: Validar estado del token VoIP existente
  /// Verifica si el token actual en Firestore está funcionando correctamente
  Future<void> _validateExistingVoIPToken() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      ReleaseLogger.log('🔍 [VoIP_TOKEN_DEBUG] Validando token VoIP existente...', tag: 'VoIPService');

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (userDoc.exists) {
        final data = userDoc.data() as Map<String, dynamic>;
        final voipToken = data['voipToken'] as String?;
        final tokenUpdatedAt = data['voipTokenUpdatedAt'] as Timestamp?;
        final refreshNeeded = data['voipTokenRefreshNeeded'] as bool?;

        if (voipToken != null && voipToken.isNotEmpty) {
          // ✅ SIMPLE: Token existe → mantenerlo (Apple dice que no expiran por tiempo)
          ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Token existente encontrado: ${voipToken.substring(0, 20)}...', tag: 'VoIPService');
          ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Manteniendo token existente - no expira por tiempo según Apple', tag: 'VoIPService');
        } else {
          ReleaseLogger.log('❌ [VoIP_TOKEN_DEBUG] No hay token VoIP - solicitando uno nuevo', tag: 'VoIPService');
          await _requestFreshVoIPToken();
        }
      } else {
        ReleaseLogger.log('❌ [VoIP_TOKEN_DEBUG] Documento de usuario no existe', tag: 'VoIPService');
        await _requestFreshVoIPToken();
      }
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP_TOKEN_DEBUG] Error validando token: $e', tag: 'VoIPService');
      // En caso de error, intentar obtener un token fresco
      await _requestFreshVoIPToken();
    }
  }

  /// ✅ CRÍTICO: Solicitar token VoIP fresco desde iOS
  /// Fuerza al lado nativo a re-registrarse para VoIP y generar un nuevo token
  Future<void> _requestFreshVoIPToken() async {
    try {
      ReleaseLogger.log('🔄 [VoIP_TOKEN_DEBUG] Solicitando token VoIP fresco desde iOS...', tag: 'VoIPService');

      // ✅ ROBUST TOKEN REFRESH: Almacenar token anterior para comparación
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        ReleaseLogger.log('❌ [VoIP_TOKEN_DEBUG] Usuario no autenticado - no se puede solicitar token', tag: 'VoIPService');
        return;
      }

      String? previousToken;
      try {
        final userDoc = await _firestore.collection('users').doc(userId).get();
        if (userDoc.exists) {
          final data = userDoc.data() as Map<String, dynamic>;
          previousToken = data['voipToken'] as String?;
        }
      } catch (e) {
        ReleaseLogger.log('⚠️ [VoIP_TOKEN_DEBUG] No se pudo obtener token anterior: $e', tag: 'VoIPService');
      }

      // Llamar al método nativo para re-registrar VoIP push notifications
      await _voipChannel.invokeMethod('requestVoIPToken');
      ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Solicitud enviada a iOS - esperando callback...', tag: 'VoIPService');

      // ✅ ROBUST WAIT: Esperar con verificación de token actualizado
      const maxRetries = 5;
      const retryDelay = Duration(seconds: 2);

      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        ReleaseLogger.log('🔍 [VoIP_TOKEN_DEBUG] Intento $attempt/$maxRetries - verificando nuevo token...', tag: 'VoIPService');

        await Future.delayed(retryDelay);

        try {
          final userDoc = await _firestore.collection('users').doc(userId).get();
          if (userDoc.exists) {
            final data = userDoc.data() as Map<String, dynamic>;
            final currentToken = data['voipToken'] as String?;
            final tokenUpdatedAt = data['voipTokenUpdatedAt'] as Timestamp?;

            // Verificar si hay un nuevo token (diferente al anterior)
            if (currentToken != null &&
                currentToken != previousToken &&
                tokenUpdatedAt != null) {

              // Verificar que el token sea reciente (menos de 30 segundos)
              final tokenAge = DateTime.now().difference(tokenUpdatedAt.toDate());
              if (tokenAge.inSeconds < 30) {
                ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Nuevo token recibido exitosamente en intento $attempt', tag: 'VoIPService');
                ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Token: ${currentToken.substring(0, 20)}... (edad: ${tokenAge.inSeconds}s)', tag: 'VoIPService');
                return; // ¡Éxito!
              }
            }
          }
        } catch (e) {
          ReleaseLogger.log('⚠️ [VoIP_TOKEN_DEBUG] Error verificando token en intento $attempt: $e', tag: 'VoIPService');
        }

        // Si no es el último intento, intentar solicitar token de nuevo
        if (attempt < maxRetries) {
          ReleaseLogger.log('🔄 [VoIP_TOKEN_DEBUG] Token no recibido, reintentando solicitud...', tag: 'VoIPService');
          try {
            await _voipChannel.invokeMethod('requestVoIPToken');
          } catch (e) {
            ReleaseLogger.log('❌ [VoIP_TOKEN_DEBUG] Error en reintento $attempt: $e', tag: 'VoIPService');
          }
        }
      }

      // Si llegamos aquí, no se recibió un token válido
      ReleaseLogger.error('❌ [VoIP_TOKEN_DEBUG] FAILED: No se recibió token válido después de $maxRetries intentos', tag: 'VoIPService');

      // ✅ FALLBACK: Marcar que necesitamos reintentarlo en la próxima inicialización
      await _markTokenRefreshNeeded();

    } catch (e) {
      ReleaseLogger.error('❌ [VoIP_TOKEN_DEBUG] Error solicitando token fresco: $e', tag: 'VoIPService');

      // ⚠️ CRÍTICO: Si el método nativo falla, significa que el lado iOS no está implementado
      // o hay un problema en la comunicación Flutter-iOS
      ReleaseLogger.error('🚨 [VoIP_TOKEN_DEBUG] PROBLEMA CRÍTICO: Método requestVoIPToken no disponible en iOS', tag: 'VoIPService');
      ReleaseLogger.error('🚨 [VoIP_TOKEN_DEBUG] Esto puede explicar por qué los tokens se invalidan', tag: 'VoIPService');

      // ✅ FALLBACK: Marcar para reintento
      await _markTokenRefreshNeeded();
    }
  }

  /// ✅ FALLBACK: Marcar que se necesita refrescar el token en la próxima inicialización
  Future<void> _markTokenRefreshNeeded() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId != null) {
        await _firestore.collection('users').doc(userId).update({
          'voipTokenRefreshNeeded': true,
          'lastTokenRefreshAttempt': FieldValue.serverTimestamp(),
        });
        ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Marcado para refresh en próxima inicialización', tag: 'VoIPService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP_TOKEN_DEBUG] Error marcando token para refresh: $e', tag: 'VoIPService');
    }
  }

  /// ✅ HELPER: Limpiar flag de refresh después de intentar
  Future<void> _clearTokenRefreshFlag() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId != null) {
        await _firestore.collection('users').doc(userId).update({
          'voipTokenRefreshNeeded': FieldValue.delete(),
        });
        ReleaseLogger.log('✅ [VoIP_TOKEN_DEBUG] Flag de refresh limpiado', tag: 'VoIPService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ [VoIP_TOKEN_DEBUG] Error limpiando flag: $e', tag: 'VoIPService');
    }
  }

  /// 🔒 LIFECYCLE MANAGEMENT: Limpiar recursos y permitir re-inicialización
  void dispose() {
    ReleaseLogger.log('🗑️ Limpiando recursos VoIP Service...', tag: 'VoIPService');

    _callEventSubscription?.cancel();
    _callEventSubscription = null;

    _pendingCallNotifier?.close();
    _pendingCallNotifier = null;

    _isInitialized = false;

    ReleaseLogger.log('✅ VoIP Service resources disposed', tag: 'VoIPService');
  }

  /// 🔒 BACKGROUND LIFECYCLE: Limpiar recursos cuando la app va a background
  void onAppPaused() {
    ReleaseLogger.log('⏸️ VoIP Service: App pausada, manteniendo conexiones esenciales', tag: 'VoIPService');
    // No disposar completamente en pausa, VoIP debe seguir funcionando en background
  }

  /// 🔒 FOREGROUND LIFECYCLE: Re-conectar cuando la app vuelve de background
  Future<void> onAppResumed() async {
    ReleaseLogger.log('▶️ VoIP Service: App resumida', tag: 'VoIPService');

    // Verificar estado de conexiones y re-inicializar si es necesario
    if (!_isInitialized) {
      await initialize();
    }
  }
}
