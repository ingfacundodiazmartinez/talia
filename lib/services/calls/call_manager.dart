import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/call.dart';
import '../../utils/release_logger.dart';
import '../callkit_service.dart';
import '../voip_service.dart';
import 'calls_service.dart';

/// Gestor unificado de llamadas - EXPERIMENTAL
///
/// ⚠️ EN DESARROLLO: Este servicio está diseñado para reemplazar CallsOrchestrator +
/// CallListenerService en el futuro, pero requiere migración completa de CallsService.
///
/// ✅ SIMPLIFICACIÓN PROPUESTA:
/// - Gestión de estado de llamadas (única fuente de verdad)
/// - Navegación centralizada
/// - Listeners unificados (1 listener por llamada en lugar de 3)
/// - Integración con CallKit/VoIP (iOS)
/// - Reducción de ~2,200 líneas de código cuando se complete la migración
///
/// TODO: Migrar CallsService para usar interfaz compatible con CallManager
/// TODO: Actualizar CallController para usar CallManager
/// TODO: Actualizar main.dart para inicializar CallManager
///
/// Por ahora, el sistema sigue usando CallsOrchestrator que funciona correctamente.
class CallManager extends ChangeNotifier {
  static CallManager? _instance;

  factory CallManager() {
    _instance ??= CallManager._internal();
    return _instance!;
  }

  CallManager._internal();

  // ═══════════════════════════════════════════
  // DEPENDENCIES
  // ═══════════════════════════════════════════

  final CallsService _callsService = CallsService();
  CallKitService? _callKitService;
  VoIPService? _voipService;

  // ═══════════════════════════════════════════
  // STATE MANAGEMENT
  // ═══════════════════════════════════════════

  /// ✅ ÚNICA FUENTE DE VERDAD: Llamadas activas en memoria
  final Map<String, Call> _activeCalls = {};

  /// ✅ LISTENERS UNIFICADOS: Un listener por llamada
  final Map<String, StreamSubscription> _callListeners = {};

  /// Navigation tracking para evitar duplicación
  final Set<String> _navigatingCallIds = <String>{};

  /// CallKit/VoIP tracking
  final Set<String> _callKitActiveCallIds = <String>{};

  // Navigation context
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _isInitialized = false;

  // ═══════════════════════════════════════════
  // CALLBACKS (para main.dart)
  // ═══════════════════════════════════════════

  Function(String callId, {bool replaceTemporary})? onNavigateToCall;
  Function(Call call)? onIncomingCall;
  Function(String error)? onError;

  // ═══════════════════════════════════════════
  // GETTERS
  // ═══════════════════════════════════════════

  List<Call> get activeCalls => _activeCalls.values.toList();
  Call? getCallFromCache(String callId) => _activeCalls[callId];
  bool get isInitialized => _isInitialized;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance?._dispose();
    _instance = null;
  }

  // ═══════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════

  Future<void> initialize({
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    if (_isInitialized) return;

    _navigatorKey = navigatorKey;

    ReleaseLogger.log(
      '🎧 [CallManager] Inicializando gestor unificado de llamadas',
      tag: 'CallManager',
    );

    // Inicializar CallsService
    _callsService.onIncomingCall = _handleIncomingCall;
    _callsService.onCallStatusChanged = _handleCallStatusChanged;
    // ✅ FIX: CallsService.onCallEnded espera Function(String), no Map
    _callsService.onCallEnded = _handleCallEnded;
    _callsService.onError = _handleError;
    _callsService.initialize();

    // Inicializar CallKit (iOS)
    if (Platform.isIOS) {
      _callKitService = CallKitService();
      await _callKitService!.initialize(
        onCallAccepted: (data) {
          final callId = data['callId'] as String? ?? '';
          if (callId.isNotEmpty) _handleCallAccepted(callId);
        },
        onCallDeclined: _handleCallDeclined,
        onCallEnded: _handleCallEnded,
        onCallKitShown: _handleCallKitShown,
      );

      _voipService = VoIPService();
      ReleaseLogger.log(
        '✅ [CallManager] CallKit/VoIP inicializado',
        tag: 'CallManager',
      );
    }

    _isInitialized = true;
    ReleaseLogger.log(
      '✅ [CallManager] Inicialización completa',
      tag: 'CallManager',
    );
  }

  // ═══════════════════════════════════════════
  // CALL OPERATIONS
  // ═══════════════════════════════════════════

  /// Iniciar nueva llamada
  /// TODO: Implementar cuando CallsService tenga método initiateCall
  Future<Map<String, dynamic>> initiateCall({
    required String receiverId,
    required String remoteName,
    required bool isVideo,
    bool isEmergency = false,
    List<String>? additionalParticipants,
  }) async {
    // TODO: Descomentar cuando CallsService tenga estos métodos
    /*
    try {
      ReleaseLogger.log(
        '📞 [CallManager] Iniciando llamada: receiver=$receiverId, video=$isVideo',
        tag: 'CallManager',
      );

      final result = await _callsService.initiateCall(
        receiverId: receiverId,
        remoteName: remoteName,
        isVideo: isVideo,
        isEmergency: isEmergency,
        additionalParticipants: additionalParticipants,
      );

      if (result['success'] == true) {
        final callId = result['callId'] as String;
        _watchCall(callId);
        ReleaseLogger.log('✅ [CallManager] Llamada creada: $callId', tag: 'CallManager');
      }

      return result;
    } catch (e) {
      ReleaseLogger.error('❌ [CallManager] Error iniciando llamada: $e', tag: 'CallManager');
      return {'success': false, 'error': e.toString()};
    }
    */
    return {'success': false, 'error': 'Not implemented yet'};
  }

  /// Aceptar llamada entrante
  Future<bool> acceptCall(String callId) async {
    try {
      ReleaseLogger.log(
        '✅ [CallManager] Aceptando llamada: $callId',
        tag: 'CallManager',
      );

      final success = await _callsService.acceptCall(callId);

      if (success) {
        // El listener detectará el cambio automáticamente
        ReleaseLogger.log(
          '✅ [CallManager] Llamada aceptada: $callId',
          tag: 'CallManager',
        );
      }

      return success;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error aceptando llamada: $e',
        tag: 'CallManager',
      );
      return false;
    }
  }

  /// Rechazar llamada entrante
  Future<bool> declineCall(String callId, {String reason = 'declined'}) async {
    try {
      ReleaseLogger.log(
        '❌ [CallManager] Rechazando llamada: $callId (reason: $reason)',
        tag: 'CallManager',
      );

      final success = await _callsService.declineCall(callId, reason: reason);

      if (success) {
        _stopWatchingCall(callId);
      }

      return success;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error rechazando llamada: $e',
        tag: 'CallManager',
      );
      return false;
    }
  }

  /// Terminar llamada
  Future<bool> endCall(String callId) async {
    try {
      ReleaseLogger.log(
        '📴 [CallManager] Terminando llamada: $callId',
        tag: 'CallManager',
      );

      final success = await _callsService.endCall(callId);

      if (success) {
        // Cleanup
        _stopWatchingCall(callId);
        _activeCalls.remove(callId);
        _navigatingCallIds.remove(callId);
        _callKitActiveCallIds.remove(callId);

        notifyListeners();
      }

      return success;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error terminando llamada: $e',
        tag: 'CallManager',
      );
      return false;
    }
  }

  /// Agregar participantes a llamada grupal
  /// TODO: Arreglar parámetro - CallsService usa newParticipantIds en lugar de participantIds
  Future<Map<String, dynamic>> addParticipants({
    required String callId,
    required List<String> participantIds,
  }) async {
    try {
      ReleaseLogger.log(
        '👥 [CallManager] Agregando participantes a $callId: $participantIds',
        tag: 'CallManager',
      );

      return await _callsService.addParticipants(
        callId: callId,
        newParticipantIds: participantIds, // ✅ Usar nombre correcto
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error agregando participantes: $e',
        tag: 'CallManager',
      );
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Iniciar llamada y navegar
  Future<void> startCallAndNavigate({
    required BuildContext context,
    required String receiverId,
    required String remoteName,
    required bool isVideo,
    bool isEmergency = false,
  }) async {
    final result = await initiateCall(
      receiverId: receiverId,
      remoteName: remoteName,
      isVideo: isVideo,
      isEmergency: isEmergency,
    );

    if (result['success'] == true) {
      final callId = result['callId'] as String;
      await navigateToCall(callId: callId, source: 'start_call');
    }
  }

  // ═══════════════════════════════════════════
  // LISTENER UNIFICADO
  // ═══════════════════════════════════════════

  /// ✅ CONSOLIDACIÓN: Un solo listener por llamada
  void _watchCall(String callId) {
    // Prevenir listeners duplicados
    if (_callListeners.containsKey(callId)) {
      ReleaseLogger.log(
        '⚠️ [CallManager] Listener ya existe para $callId',
        tag: 'CallManager',
      );
      return;
    }

    ReleaseLogger.log(
      '👁️ [CallManager] Iniciando listener unificado para $callId',
      tag: 'CallManager',
    );

    _callListeners[callId] = FirebaseFirestore.instance
      .collection('calls')
      .doc(callId)
      .snapshots()
      .listen(
        (snapshot) => _onCallStateChanged(callId, snapshot),
        onError: (error) {
          ReleaseLogger.error(
            '❌ [CallManager] Error en listener: $error',
            tag: 'CallManager',
          );
        },
      );
  }

  void _stopWatchingCall(String callId) {
    _callListeners[callId]?.cancel();
    _callListeners.remove(callId);

    ReleaseLogger.log(
      '👁️ [CallManager] Listener detenido para $callId',
      tag: 'CallManager',
    );
  }

  /// ✅ EVENTO CENTRAL: Todos los cambios de estado pasan por aquí
  void _onCallStateChanged(String callId, DocumentSnapshot snapshot) {
    if (!snapshot.exists) {
      _handleCallDeleted(callId);
      return;
    }

    final call = Call.fromFirestore(snapshot.id, snapshot.data() as Map<String, dynamic>);
    final previousCall = _activeCalls[callId];
    _activeCalls[callId] = call;

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    ReleaseLogger.log(
      '📡 [CallManager] Estado actualizado: $callId, state=${call.getStateForUser(currentUserId)}',
      tag: 'CallManager',
    );

    // ═══ DETECCIÓN DE CAMBIOS IMPORTANTES ═══

    // 1. Llamada terminada → cleanup
    if (call.endedAt != null) {
      _handleCallEndedByListener(callId);
      return;
    }

    // 2. Estado cambió a "joined" → navegar a pantalla activa
    final myStatus = call.participants[currentUserId]?.status;
    final previousStatus = previousCall?.participants[currentUserId]?.status;

    if (myStatus == 'joined' && previousStatus == 'waiting') {
      ReleaseLogger.log(
        '🚀 [CallManager] Usuario se unió a llamada: $callId',
        tag: 'CallManager',
      );
      navigateToCall(callId: callId, source: 'user_joined');
    }

    // Notificar cambios a listeners
    notifyListeners();
  }

  void _handleCallDeleted(String callId) {
    ReleaseLogger.log(
      '🗑️ [CallManager] Llamada eliminada: $callId',
      tag: 'CallManager',
    );

    _stopWatchingCall(callId);
    _activeCalls.remove(callId);
    notifyListeners();
  }

  void _handleCallEndedByListener(String callId) {
    ReleaseLogger.log(
      '🔚 [CallManager] Llamada terminada detectada por listener: $callId',
      tag: 'CallManager',
    );

    _stopWatchingCall(callId);
    _activeCalls.remove(callId);
    _navigatingCallIds.remove(callId);
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // NAVIGATION
  // ═══════════════════════════════════════════

  /// Navegar a pantalla de llamada
  Future<void> navigateToCall({
    required String callId,
    String? source,
    bool replaceTemporary = false,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // ✅ Prevenir navegación duplicada
      if (_navigatingCallIds.contains(callId)) {
        ReleaseLogger.log(
          '⚠️ [CallManager] Ya navegando a $callId (source: $source)',
          tag: 'CallManager',
        );
        return;
      }

      // Extraer replaceTemporary de metadata si existe
      final shouldReplace = metadata?['replaceTemporary'] as bool? ?? replaceTemporary;

      ReleaseLogger.log(
        '🧭 [CallManager] Navegando: callId=$callId, source=$source, replace=$shouldReplace',
        tag: 'CallManager',
      );

      _navigatingCallIds.add(callId);

      // Navegar usando callback
      if (onNavigateToCall != null) {
        onNavigateToCall!(callId, replaceTemporary: shouldReplace);
      } else {
        ReleaseLogger.error(
          '❌ [CallManager] onNavigateToCall callback no configurado',
          tag: 'CallManager',
        );
      }

      // Auto-cleanup después de 2 segundos
      Future.delayed(Duration(seconds: 2), () {
        _navigatingCallIds.remove(callId);
      });

      ReleaseLogger.log(
        '✅ [CallManager] Navegación exitosa: $callId',
        tag: 'CallManager',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error navegando: $e',
        tag: 'CallManager',
      );
      _navigatingCallIds.remove(callId);
      rethrow;
    }
  }

  // ═══════════════════════════════════════════
  // CALLSSERVICE EVENT HANDLERS
  // ═══════════════════════════════════════════

  void _handleIncomingCall(Call call) {
    ReleaseLogger.log(
      '📲 [CallManager] Llamada entrante: ${call.id}',
      tag: 'CallManager',
    );

    _activeCalls[call.id] = call;
    _watchCall(call.id);

    // Notificar a main.dart
    onIncomingCall?.call(call);

    // Navegar a pantalla de llamada entrante
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId != null && call.createdBy != currentUserId) {
      navigateToCall(callId: call.id, source: 'incoming');
    }
  }

  void _handleCallStatusChanged(Call call) {
    ReleaseLogger.log(
      '📊 [CallManager] Estado cambiado: ${call.id}',
      tag: 'CallManager',
    );

    _activeCalls[call.id] = call;
    notifyListeners();
  }

  void _handleCallEnded(String callId) {
    ReleaseLogger.log(
      '🔚 [CallManager] Llamada terminada: $callId',
      tag: 'CallManager',
    );

    _stopWatchingCall(callId);
    _activeCalls.remove(callId);
    _navigatingCallIds.remove(callId);
    _callKitActiveCallIds.remove(callId);
    notifyListeners();
  }

  void _handleError(String error) {
    ReleaseLogger.error(
      '❌ [CallManager] Error: $error',
      tag: 'CallManager',
    );
    onError?.call(error);
  }

  // ═══════════════════════════════════════════
  // CALLKIT/VOIP HANDLERS
  // ═══════════════════════════════════════════

  void _handleCallAccepted(String callId) {
    ReleaseLogger.log(
      '✅ [CallManager] CallKit aceptó: $callId',
      tag: 'CallManager',
    );

    _callKitActiveCallIds.add(callId);
    acceptCall(callId);
  }

  void _handleCallDeclined(String callId) {
    ReleaseLogger.log(
      '❌ [CallManager] CallKit rechazó: $callId',
      tag: 'CallManager',
    );

    declineCall(callId);
  }

  void _handleCallKitShown(String callId) {
    ReleaseLogger.log(
      '📱 [CallManager] CallKit UI mostrada: $callId',
      tag: 'CallManager',
    );

    _callKitActiveCallIds.add(callId);
  }

  /// Verificar si llamada está siendo manejada por CallKit
  bool isCallBeingHandledByCallKit(String callId) {
    final isHandledByCallKit = _callKitActiveCallIds.contains(callId);
    final isHandledByVoIP = _voipService?.isCallHandledByVoIP(callId) ?? false;
    final isHandled = isHandledByCallKit || isHandledByVoIP;

    ReleaseLogger.log(
      '🔍 [CallManager] CallKit check $callId: ${isHandled ? "SÍ" : "NO"} (CallKit:$isHandledByCallKit, VoIP:$isHandledByVoIP)',
      tag: 'CallManager',
    );

    return isHandled;
  }

  // ═══════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════

  /// Obtener stream de cambios de una llamada
  Stream<Call?> watchCall(String callId) {
    // Asegurar que hay listener activo
    if (!_callListeners.containsKey(callId)) {
      _watchCall(callId);
    }

    // Retornar stream desde Firestore
    return FirebaseFirestore.instance
      .collection('calls')
      .doc(callId)
      .snapshots()
      .map((snapshot) {
        if (!snapshot.exists) return null;
        return Call.fromFirestore(snapshot.id, snapshot.data() as Map<String, dynamic>);
      });
  }

  /// Obtener nombre de participante
  Future<String> getParticipantName(String userId) async {
    try {
      final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .get();

      if (!userDoc.exists) return 'Usuario';

      final userData = userDoc.data()!;
      return userData['name'] as String? ??
             userData['email'] as String? ??
             'Usuario';
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error obteniendo nombre: $e',
        tag: 'CallManager',
      );
      return 'Usuario';
    }
  }

  /// Obtener contactos disponibles para agregar a llamada
  /// TODO: Implementar lógica de contactos
  Future<List<Map<String, dynamic>>> getAvailableContactsForCall({
    required String currentCallId,
    required String currentReceiverId,
  }) async {
    // TODO: Implementar cuando sea necesario
    return [];
  }

  /// Obtener nombre del otro participante en llamada 1-1
  Future<String> getOtherParticipantName(Call call) async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return 'Usuario';

    // Buscar el primer participante que NO sea el usuario actual
    for (String participantId in call.participants.keys) {
      if (participantId != currentUserId) {
        return await getParticipantName(participantId);
      }
    }

    return 'Usuario';
  }

  /// Obtener llamadas recientes del usuario
  Future<List<Call>> getRecentCalls(String userId) async {
    try {
      final cutoffTime = DateTime.now().subtract(Duration(seconds: 30));

      final snapshot = await FirebaseFirestore.instance
        .collection('calls')
        .where('participants', arrayContains: userId)
        .where('createdAt', isGreaterThan: Timestamp.fromDate(cutoffTime))
        .orderBy('createdAt', descending: true)
        .limit(5)
        .get();

      return snapshot.docs
        .map((doc) => Call.fromFirestore(doc.id, doc.data()))
        .toList();
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error obteniendo llamadas recientes: $e',
        tag: 'CallManager',
      );
      return [];
    }
  }

  /// Obtener una llamada específica
  static Future<Call?> getCall(String callId) async {
    try {
      final doc = await FirebaseFirestore.instance
        .collection('calls')
        .doc(callId)
        .get();

      if (!doc.exists) return null;
      return Call.fromFirestore(doc.id, doc.data()!);
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallManager] Error obteniendo llamada: $e',
        tag: 'CallManager',
      );
      return null;
    }
  }

  // ═══════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════

  void _dispose() {
    ReleaseLogger.log(
      '🧹 [CallManager] Disposing',
      tag: 'CallManager',
    );

    // Cancelar todos los listeners
    for (final subscription in _callListeners.values) {
      subscription.cancel();
    }
    _callListeners.clear();

    // Cleanup CallsService
    _callsService.dispose();

    // Clear state
    _activeCalls.clear();
    _navigatingCallIds.clear();
    _callKitActiveCallIds.clear();
    _navigatorKey = null;
    _isInitialized = false;

    // Clear callbacks
    onNavigateToCall = null;
    onIncomingCall = null;
    onError = null;
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }
}
