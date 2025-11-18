import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'calls_service.dart';
import '../../models/call.dart';
import '../../utils/release_logger.dart';
import '../callkit_service.dart';
import '../voip_service.dart';
import '../chat_permission_service.dart';
import '../contact_alias_service.dart';
import 'call_listener_service.dart';

/// Orchestrator principal para la gestión de calls unificadas
///
/// Sigue CODING_RULES.md siguiendo la arquitectura de stories:
/// UI → Controller → Orchestrator → Services
///
/// Responsabilidades:
/// - Coordinar entre CallsService y UI components
/// - Manejar navegación automática para llamadas
/// - Gestionar callbacks de main.dart de forma limpia
/// - Integrar con el ecosistema de notificaciones existente
class CallsOrchestrator {
  static CallsOrchestrator? _instance;

  factory CallsOrchestrator() {
    _instance ??= CallsOrchestrator._internal();
    return _instance!;
  }

  CallsOrchestrator._internal();

  // Dependencies
  final CallsService _callsService = CallsService();

  // ✅ ADDED: CallKit dependencies para cancelación automática
  CallKitService? _callKitService;
  VoIPService? _voipService;

  // Services
  final CallListenerService _listenerService = CallListenerService();

  // State management
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _isInitialized = false;

  // Global listeners
  bool _globalListenersInitialized = false;
  StreamSubscription<Map<String, dynamic>>? _pendingCallSubscription;

  // Recovery callbacks (stored for listener recovery)
  Function(String callId, String source)? _lastDetectedCallCallback;
  Function(String callId)? _lastCallEndedCallback;

  // Navigation tracking para evitar loops infinitos
  final Set<String> _navigatingCallIds = <String>{};

  // ✅ ADDED: CallKit coordination para evitar IncomingCallScreen duplicado
  final Set<String> _callKitActiveCallIds = <String>{};

  // ✅ FIX CRÍTICO: Deduplicación centralizada de llamadas entrantes procesadas
  final Map<String, DateTime> _processedIncomingCalls = {};

  // Callbacks para main.dart (interfaz mínima)
  Function(Call call)? onIncomingCall;
  Function(Call call)? onCallStatusChanged;
  Function(String callId)? onCallEnded;
  Function(String error)? onError;

  // ✅ NUEVO: Callback para navegación sin dependencia circular
  Function(String callId, {bool replaceTemporary})? onNavigateToCall;

  // ✅ FIX ESCENARIO CALLKIT: Getter para verificar estado de listeners
  bool get areGlobalListenersInitialized => _globalListenersInitialized;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

  /// ✅ FIX CRÍTICO: Operación atómica para prevenir navegación duplicada
  /// Retorna true si debemos proceder con la navegación, false si ya está navegando
  bool _tryStartNavigation(String callId) {
    if (_navigatingCallIds.contains(callId)) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Ya navegando a $callId - evitando duplicado',
        tag: 'CallsOrchestrator',
      );
      return false;
    }

    // Marcar como navegando
    _navigatingCallIds.add(callId);

    // Auto-cleanup después de 3 segundos
    Future.delayed(Duration(seconds: 3), () {
      _navigatingCallIds.remove(callId);
    });

    return true;
  }

  /// ✅ SIMPLE: Helper para navegación usando callback limpio
  void _navigateToCallScreen(String callId, {bool replaceTemporary = false}) {
    if (onNavigateToCall == null) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] onNavigateToCall callback no configurado',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    ReleaseLogger.log(
      '🎯 [CallsOrchestrator] Navegando a CallScreen via callback: $callId (replace: $replaceTemporary)',
      tag: 'CallsOrchestrator',
    );

    onNavigateToCall!(callId, replaceTemporary: replaceTemporary);
  }

  /// Inicializar orchestrator - llamado desde main.dart
  Future<void> initialize({
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    if (_isInitialized) return;

    _navigatorKey = navigatorKey;

    ReleaseLogger.log(
      '🎧 [CallsOrchestrator] Inicializando orchestrator',
      tag: 'CallsOrchestrator',
    );

    // Configurar callbacks del CallsService
    _callsService.onIncomingCall = _handleIncomingCall;
    _callsService.onCallStatusChanged = _handleCallStatusChanged;
    _callsService.onCallEnded = _handleCallEnded;
    _callsService.onError = _handleError;

    // Inicializar el service
    _callsService.initialize();

    // ✅ ADDED: Inicializar servicios de CallKit para cancelación automática
    _callKitService = CallKitService();
    await _callKitService!.initialize(
      onCallAccepted: _handleCallAccepted,
      onCallDeclined: _handleCallDeclined,
      onCallEnded: _handleCallEnded,
      onCallKitShown: _handleCallKitShown,
    );

    if (Platform.isIOS) {
      _voipService = VoIPService();
    }
    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Servicios CallKit inicializados',
      tag: 'CallsOrchestrator',
    );

    _isInitialized = true;
    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Orchestrator inicializado',
      tag: 'CallsOrchestrator',
    );
  }

  /// Dispose del orchestrator
  void dispose() {
    ReleaseLogger.log(
      '🔇 [CallsOrchestrator] Disposing orchestrator',
      tag: 'CallsOrchestrator',
    );

    // ✅ FIX MEMORY LEAK: Cancelar pending call subscription
    _pendingCallSubscription?.cancel();
    _pendingCallSubscription = null;

    _callsService.dispose();
    _navigatorKey = null;
    _isInitialized = false;
    _globalListenersInitialized = false;

    // Limpiar tracking de navegación
    _navigatingCallIds.clear();
    _callKitActiveCallIds.clear();

    // Limpiar callbacks
    onIncomingCall = null;
    onCallStatusChanged = null;
    onCallEnded = null;
    onError = null;
    onNavigateToCall = null;
  }

  // ═══════════════════════════════════════════════════════════════
  // MANEJO DE EVENTOS DEL CALLSSERVICE
  // ═══════════════════════════════════════════════════════════════

  /// Manejar llamada entrante detectada por CallsService
  void _handleIncomingCall(Call call) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) return;

      final currentUserStatus = call.participants[currentUserId]?.status;

      ReleaseLogger.log(
        '📞 [CallsOrchestrator] Manejando llamada entrante ${call.id} con estado: $currentUserStatus',
        tag: 'CallsOrchestrator',
      );

      // Solo mostrar notificaciones para llamadas entrantes (status: waiting)
      if (currentUserStatus == 'waiting') {
        _showIncomingCallScreen(call);

        // ✅ FIXED: Comentar callback redundante que causa triple IncomingCallScreen
        // La integración con CallKit/VoIP ya se maneja en _showIncomingCallScreen
        // onIncomingCall?.call(call);
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error manejando llamada entrante: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Manejar cambios de estado de llamada
  void _handleCallStatusChanged(Call call) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.log(
          '❌ [CallsOrchestrator] No hay usuario logueado en _handleCallStatusChanged',
          tag: 'CallsOrchestrator',
        );
        return;
      }

      final currentUserStatus = call.participants[currentUserId]?.status;

      ReleaseLogger.log(
        '🔄 [CallsOrchestrator] Estado de llamada ${call.id} cambió: $currentUserStatus (endedAt: ${call.endedAt})',
        tag: 'CallsOrchestrator',
      );

      // Si el usuario se unió a la llamada, navegar automáticamente SOLO si no está ya en una call screen Y la llamada NO ha terminado
      if (currentUserStatus == 'joined' && call.endedAt == null) {
        // ✅ FIX: Si soy el caller, ya tengo CallScreen temporal activo
        // El polling del temporal manejará la navegación a la llamada real
        // NO navegar aquí para evitar duplicados
        final isCaller = call.createdBy == currentUserId;
        if (isCaller) {
          ReleaseLogger.log(
            '⚠️ [CallsOrchestrator] Soy el caller de ${call.id} - ya tengo CallScreen temporal, NO navegar',
            tag: 'CallsOrchestrator',
          );
          return;
        }

        ReleaseLogger.log(
          '✅ [CallsOrchestrator] Usuario se unió a llamada ${call.id} - intentando navegar',
          tag: 'CallsOrchestrator',
        );
        _navigateToCallScreenIfNeeded(call);
      } else {
        ReleaseLogger.log(
          '⚠️ [CallsOrchestrator] No navegando para ${call.id}: status=$currentUserStatus, endedAt=${call.endedAt}',
          tag: 'CallsOrchestrator',
        );
      }

      // Notificar a main.dart para integración existente
      onCallStatusChanged?.call(call);
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error manejando cambio de estado: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Callback cuando CallKit acepta una llamada
  Future<void> _handleCallAccepted(Map<String, dynamic> callData) async {
    final callId = callData['id'] as String?;
    if (callId == null) return;

    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Llamada aceptada desde CallKit: $callId',
      tag: 'CallsOrchestrator',
    );

    // ✅ CRITICAL: Marcar como CallKitHandled INMEDIATAMENTE para evitar IncomingCallScreen
    // Esto previene que cuando la app vuelva a foreground, _showIncomingCallScreen() se ejecute
    markCallAsCallKitHandled(callId);

    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Llamada marcada como CallKitHandled - IncomingCallScreen bloqueada',
      tag: 'CallsOrchestrator',
    );

    // ✅ UX FIX: Navegar INMEDIATAMENTE para evitar demora de 7+ segundos
    // No esperar a que Firebase actualice el estado
    try {
      // Primero: Cargar la call actual desde Firebase
      final call = await _callsService.getCall(callId);

      if (call == null) {
        ReleaseLogger.error(
          '❌ [CallsOrchestrator] No se pudo cargar call para navegar: $callId',
          tag: 'CallsOrchestrator',
        );
        return;
      }

      ReleaseLogger.log(
        '🚀 [CallsOrchestrator] Aceptando llamada en Firebase antes de navegar',
        tag: 'CallsOrchestrator',
      );

      // ✅ CRITICAL FIX: Aceptar llamada PRIMERO para que VideoCallScreen tenga todo listo
      // Esto agrega ~200-500ms pero evita que VideoCallScreen se quede en "Inicializando..."
      await acceptCall(callId);

      ReleaseLogger.log(
        '✅ [CallsOrchestrator] Llamada aceptada, navegando a CallScreen',
        tag: 'CallsOrchestrator',
      );

      // Navegar DESPUÉS de aceptar (VideoCallScreen espera que acceptCall() ya se ejecutó)
      _navigateToCallScreenIfNeeded(call);

    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error aceptando llamada desde CallKit: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Callback cuando CallKit rechaza una llamada
  Future<void> _handleCallDeclined(String callId) async {
    ReleaseLogger.log(
      '❌ [CallsOrchestrator] Llamada rechazada desde CallKit: $callId',
      tag: 'CallsOrchestrator',
    );

    // Marcar la llamada como rechazada en Firestore
    try {
      await _callsService.declineCall(callId);
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error marcando llamada como rechazada: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Callback cuando CallKit se muestra
  void _handleCallKitShown(String callId) {
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] CallKit mostrado para llamada: $callId',
      tag: 'CallsOrchestrator',
    );

    // ✅ FIX: Marcar como manejada por CallKit para evitar mostrar IncomingCallScreen
    markCallAsCallKitHandled(callId);
  }

  /// Manejar llamada terminada
  Future<void> _handleCallEnded(String callId) async {
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Llamada terminada: $callId',
      tag: 'CallsOrchestrator',
    );

    ReleaseLogger.log(
      '🔍 [DEBUG] CallsOrchestrator _handleCallEnded called for callId: $callId',
      tag: 'CallsOrchestrator',
    );

    // Context no longer needed with simplified navigation

    // ✅ CRÍTICO: Terminar notificaciones CallKit activas para esta llamada
    ReleaseLogger.log(
      '📞 [DEBUG] CallsOrchestrator calling _terminateCallKitNotification for $callId',
      tag: 'CallsOrchestrator',
    );
    await _terminateCallKitNotification(callId);

    // ✅ SINGLE SOURCE: Notificar callback para cerrar CallScreen automáticamente
    if (onCallEnded != null) {
      onCallEnded!(callId);
      ReleaseLogger.log(
        '🔚 [CallsOrchestrator] Llamada $callId terminada - callback notificado para cerrar CallScreen',
        tag: 'CallsOrchestrator',
      );
    } else {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] onCallEnded callback no configurado - CallScreen no se cerrará automáticamente',
        tag: 'CallsOrchestrator',
      );
    }

    // Limpiar tracking de navegación para esta llamada
    _navigatingCallIds.remove(callId);

    // Limpiar tracking de CallKit para esta llamada
    _callKitActiveCallIds.remove(callId);

    // ✅ FIX SPINNER INFINITO: NO navegar al home cuando termina la llamada
    //
    // PROBLEMA ANTERIOR: Navigator.pushReplacementNamed(context, '/') creaba un nuevo
    // AuthWrapper que reiniciaba el stream de autenticación, causando spinner infinito.
    //
    // SOLUCIÓN: Solo limpiar estado y notificar - dejar que la UI actual maneje
    // la navegación naturalmente sin disrumpir los StreamBuilders activos.
    //
    // ✅ OVERLAY STACK: Con el overlay independiente, simplemente cerramos el overlay
    // sin afectar el stack principal de navegación
    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Llamada $callId limpiada y overlay cerrado',
      tag: 'CallsOrchestrator',
    );

    // Notificar a main.dart
    onCallEnded?.call(callId);
  }

  /// Manejar errores del CallsService
  void _handleError(String error) {
    ReleaseLogger.error(
      '❌ [CallsOrchestrator] Error en CallsService: $error',
      tag: 'CallsOrchestrator',
    );

    // Notificar a main.dart
    onError?.call(error);
  }

  // ═══════════════════════════════════════════════════════════════
  // NAVEGACIÓN AUTOMÁTICA
  // ═══════════════════════════════════════════════════════════════

  /// Mostrar IncomingCallScreen para llamadas entrantes
  Future<void> _showIncomingCallScreen(Call call) async {
    if (_navigatorKey?.currentContext == null) return;

    // ✅ FIX CRÍTICO: Deduplicación basada en callId + timestamp
    // Previene que CallsService Y CallListenerService muestren la misma llamada 2+ veces
    final callTimestamp = call.createdAt;

    if (_processedIncomingCalls.containsKey(call.id)) {
      final previousTimestamp = _processedIncomingCalls[call.id]!;
      if (previousTimestamp == callTimestamp) {
        ReleaseLogger.log(
          '⚠️ [CallsOrchestrator] Llamada ${call.id} ya procesada (timestamp: $callTimestamp) - evitando duplicado',
          tag: 'CallsOrchestrator',
        );
        return;
      }
    }

    // Marcar como procesada
    _processedIncomingCalls[call.id] = callTimestamp;

    // Limpiar después de 10 segundos
    Future.delayed(Duration(seconds: 10), () {
      _processedIncomingCalls.remove(call.id);
    });

    // ✅ NUEVO: Verificar si la llamada ya terminó
    if (call.endedAt != null) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Llamada ${call.id} ya terminó (endedAt: ${call.endedAt}) - NO mostrar IncomingCallScreen',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    // ✅ FIXED: Verificar si CallKit ya está manejando esta llamada
    if (isCallBeingHandledByCallKit(call.id)) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Llamada ${call.id} ya siendo manejada por CallKit - NO mostrar IncomingCallScreen',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    // ✅ FIXED: Verificar si VoIP ya está manejando esta llamada
    if (_voipService != null && _voipService!.isCallHandledByVoIP(call.id)) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Llamada ${call.id} ya siendo manejada por VoIP - NO mostrar IncomingCallScreen',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    // ✅ FIX: Marcar como handled by VoIP ANTES de mostrar IncomingCallScreen
    // Esto previene que listeners posteriores disparen notificaciones duplicadas
    if (_voipService != null) {
      _voipService!.markCallAsVoIPHandled(call.id);
      ReleaseLogger.log(
        '🔄 [CallsOrchestrator] Llamada ${call.id} marcada como handled by VoIP',
        tag: 'CallsOrchestrator',
      );
    }

    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Mostrando IncomingCallScreen para ${call.id}',
      tag: 'CallsOrchestrator',
    );

    // Caller name no longer needed with simplified navigation

    // ✅ SIMPLIFIED: Usar callback para mostrar IncomingCallScreen
    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Usando callback para navegar a IncomingCallScreen: ${call.id}',
      tag: 'CallsOrchestrator',
    );

    _navigateToCallScreen(call.id);
  }

  /// Navegar a call screen solo si no está ya en una
  void _navigateToCallScreenIfNeeded(Call call) {
    ReleaseLogger.log(
      '🔍 [CallsOrchestrator] _navigateToCallScreenIfNeeded llamado para ${call.id}',
      tag: 'CallsOrchestrator',
    );

    if (_navigatorKey?.currentContext == null) {
      ReleaseLogger.log(
        '❌ [CallsOrchestrator] Navigator context es null - reintentando en 1 segundo',
        tag: 'CallsOrchestrator',
      );

      // ✅ CONTEXT RETRY: Reintentar navegación cuando el context esté disponible
      Future.delayed(Duration(seconds: 1), () {
        if (_navigatorKey?.currentContext != null) {
          ReleaseLogger.log(
            '🔄 [CallsOrchestrator] Context disponible después de delay - reintentando navegación',
            tag: 'CallsOrchestrator',
          );
          _navigateToCallScreenIfNeeded(call);
        } else {
          ReleaseLogger.log(
            '❌ [CallsOrchestrator] Context sigue null después de delay - navegación fallida',
            tag: 'CallsOrchestrator',
          );
        }
      });
      return;
    }

    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Navigator context disponible',
      tag: 'CallsOrchestrator',
    );

    // Si el usuario actual es el creador de la llamada (caller),
    // no navegar automáticamente porque ya debe estar en VideoCallScreen
    if (_isUserCaller(call)) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Evitando navegación automática para caller - ya debe estar en VideoCallScreen',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    // ✅ UX FIX: Para llamadas CallKit/VoIP, navegar INMEDIATAMENTE si el receptor acepta
    // No esperar a que Firebase actualice (puede tardar 7+ segundos)
    if (isCallBeingHandledByCallKit(call.id)) {
      // Obtener status del participante actual
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final currentParticipant = call.participants[currentUserId];
      final participantStatus = currentParticipant?.status;

      // ✅ CRITICAL FIX: Si soy el RECEPTOR (no caller) y mi status es 'waiting',
      // significa que CallKit aceptó pero Firebase aún no actualizó
      // → Navegar INMEDIATAMENTE para mejor UX
      final isReceiver = call.createdBy != currentUserId;
      final shouldNavigateImmediately = isReceiver && participantStatus == 'waiting';

      if (participantStatus == 'joined' || shouldNavigateImmediately) {
        ReleaseLogger.log(
          '🚀 [CallsOrchestrator] Llamada VoIP/CallKit ${call.id} - navegando (status: $participantStatus, isReceiver: $isReceiver)',
          tag: 'CallsOrchestrator',
        );
        // Continuar con la navegación
      } else {
        ReleaseLogger.log(
          '⚠️ [CallsOrchestrator] Llamada ${call.id} ya siendo manejada por CallKit - NO navegar automáticamente (status: $participantStatus)',
          tag: 'CallsOrchestrator',
        );
        return;
      }
    }

    // ✅ FIX CRÍTICO: Usar operación atómica para prevenir race conditions
    if (!_tryStartNavigation(call.id)) {
      return; // Ya navegando
    }

    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Navegando automáticamente para receiver a call ${call.id}',
      tag: 'CallsOrchestrator',
    );

    _navigateToCallScreenForCall(call);
  }

  /// Navegar automáticamente a call screen cuando usuario se une
  void _navigateToCallScreenForCall(Call call) {
    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Navegando a CallScreen para ${call.id}',
      tag: 'CallsOrchestrator',
    );

    _navigateToCallScreen(call.id);
  }

  /// Navegar inmediatamente a call screen cuando usuario crea una llamada (caller)
  void _navigateToCallScreenAsCreator(
    String callId,
    bool isVideo, {
    List<String>? participantIds,
    Map<String, dynamic>? callData,
  }) {
    ReleaseLogger.log(
      '🚀 [CallsOrchestrator] Navegando a CallScreen como creador para $callId (video: $isVideo)',
      tag: 'CallsOrchestrator',
    );

    final metadata = <String, dynamic>{
      'isVideo': isVideo,
      'isCaller': true,
      'isCreating': callId.startsWith('temp_'),
    };

    if (participantIds != null) {
      metadata['participantIds'] = participantIds;
    }

    if (callData != null) {
      metadata.addAll(callData);
    }

    _navigateToCallScreen(callId);
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS PÚBLICOS PARA CONTROLLERS
  // ═══════════════════════════════════════════════════════════════

  /// Crear nueva llamada - usado por controllers
  Future<Map<String, dynamic>> createCall({
    required List<String> participantIds,
    required String type,
    String? customChannelName,
  }) async {
    // ✅ UX FIX: Navegar INMEDIATAMENTE para mejor experiencia de usuario
    // Generar callId temporal para navegación inmediata
    final tempCallId = 'temp_${DateTime.now().millisecondsSinceEpoch}';

    ReleaseLogger.log(
      '🚀 [CallsOrchestrator] Navegando inmediatamente como caller (UX optimizada) - callId temporal: $tempCallId',
      tag: 'CallsOrchestrator',
    );

    // Navegar inmediatamente mientras se crea la llamada en background
    _navigateToCallScreenAsCreator(
      tempCallId,
      type == 'video',
      participantIds: participantIds,
    );

    // Crear la llamada en background
    final result = await _callsService.createCall(
      participantIds: participantIds,
      type: type,
      customChannelName: customChannelName,
    );

    if (result['success'] == true) {
      ReleaseLogger.log(
        '✅ [CallsOrchestrator] Llamada creada exitosamente en background: ${result['callId']}',
        tag: 'CallsOrchestrator',
      );

      // ✅ DEBUG: Log para verificar que no hay interferencias después de crear la llamada
      ReleaseLogger.log(
        '🔍 [CallsOrchestrator] Llamada ${result['callId']} creada, usuario debería estar en CallScreen temporal $tempCallId',
        tag: 'CallsOrchestrator',
      );
    } else {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error creando llamada en background: ${result['error']}',
        tag: 'CallsOrchestrator',
      );
    }

    return result;
  }

  /// Agregar participantes a llamada existente
  Future<Map<String, dynamic>> addParticipants({
    required String callId,
    required List<String> newParticipantIds,
  }) async {
    return await _callsService.addParticipants(
      callId: callId,
      newParticipantIds: newParticipantIds,
    );
  }

  /// Aceptar llamada entrante
  Future<bool> acceptCall(String callId) async {
    return await _callsService.acceptCall(callId);
  }

  /// Rechazar llamada entrante
  Future<bool> declineCall(String callId, {String reason = 'declined'}) async {
    return await _callsService.declineCall(callId, reason: reason);
  }

  /// Terminar llamada activa
  Future<bool> endCall(String callId) async {
    return await _callsService.endCall(callId);
  }

  /// Limpiar tracking de llamadas
  ///
  /// ✅ SIMPLIFICADO: Solo limpia tracking interno
  void cleanupCallTracking() {
    _navigatingCallIds.clear();
    _callKitActiveCallIds.clear();
    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Tracking de llamadas limpiado',
      tag: 'CallsOrchestrator',
    );
  }

  /// Obtener call específica por ID
  Future<Call?> getCall(String callId) async {
    return await _callsService.getCall(callId);
  }

  /// Obtener llamadas recientes del usuario para detectar llamadas recién creadas
  Future<List<Call>> getRecentCalls(String userId) async {
    try {
      // Obtener llamadas creadas en los últimos 30 segundos
      final thirtySecondsAgo = DateTime.now().subtract(Duration(seconds: 30));

      final querySnapshot = await FirebaseFirestore.instance
          .collection('calls')
          .where(
            'createdAt',
            isGreaterThan: Timestamp.fromDate(thirtySecondsAgo),
          )
          .orderBy('createdAt', descending: true)
          .limit(10)
          .get();

      final calls = querySnapshot.docs
          .map((doc) => Call.fromFirestore(doc.id, doc.data()))
          .where(
            (call) =>
                call.endedAt == null && // Solo llamadas activas
                call.participants.containsKey(userId),
          ) // Usuario participa
          .toList();

      return calls;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error obteniendo llamadas recientes: $e',
        tag: 'CallsOrchestrator',
      );
      return [];
    }
  }

  /// ==== MÉTODOS DE NAVEGACIÓN PARA MAIN.DART ====

  /// Procesar llamada entrante desde CallKit
  Future<void> processCallKitCall(String callId) async {
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Procesando llamada CallKit: $callId',
      tag: 'CallsOrchestrator',
    );

    _navigateToCallScreen(callId);
  }

  /// Procesar llamada entrante en foreground
  Future<void> processForegroundCall(String callId) async {
    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Procesando llamada foreground: $callId',
      tag: 'CallsOrchestrator',
    );

    // ✅ RECOVERY: Verificar y recuperar listeners antes de procesar
    if (!_listenerService.isHealthy) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Listener unhealthy detected before processing - attempting recovery',
        tag: 'CallsOrchestrator',
      );
      await attemptListenerRecovery();
    }

    try {
      // Obtener datos de la llamada
      final call = await getCall(callId);
      if (call == null) {
        ReleaseLogger.error(
          '❌ [CallsOrchestrator] No se pudo obtener llamada $callId para foreground',
          tag: 'CallsOrchestrator',
        );
        return;
      }

      // Caller name no longer needed with simplified navigation

      // ✅ SIMPLIFIED: Usar callback para navegación
      _navigateToCallScreen(callId);

      ReleaseLogger.log(
        '✅ [CallsOrchestrator] IncomingCallScreen mostrado para foreground: $callId',
        tag: 'CallsOrchestrator',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error procesando llamada foreground $callId: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Procesar llamada desde VoIP
  Future<void> processVoIPCall(String callId) async {
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Procesando llamada VoIP: $callId',
      tag: 'CallsOrchestrator',
    );

    _navigateToCallScreen(callId);
  }

  /// Procesar cualquier llamada (método genérico)
  Future<void> processIncomingCall(String callId, {String? source}) async {
    ReleaseLogger.log(
      '📲 [CallsOrchestrator] Procesando llamada entrante: $callId (source: $source)',
      tag: 'CallsOrchestrator',
    );

    _navigateToCallScreen(callId);
  }

  /// Stream de una call específica
  Stream<Call?> watchCall(String callId) {
    return _callsService.watchCall(callId);
  }

  /// ==== MÉTODOS DE LISTENERS GLOBALES PARA CALLCONTROLLER ====

  /// Inicializar listeners globales
  Future<void> initializeGlobalListeners({
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    if (_globalListenersInitialized) return;

    _navigatorKey = navigatorKey;

    ReleaseLogger.log(
      '🚀🚀🚀 [CallsOrchestrator] INITIALIZEGLOBALLISTENERS EJECUTANDOSE!!! 🚀🚀🚀',
      tag: 'CallsOrchestrator',
    );

    // Inicializar orchestrator si no está inicializado
    await initialize(navigatorKey: navigatorKey);

    // ✅ SIMPLIFICADO: Ya no usamos navigation service

    // ✅ RECOVERY: Guardar callbacks para recuperación posterior
    _lastDetectedCallCallback = _handleDetectedCall;
    _lastCallEndedCallback = _handleCallEnded;

    // Inicializar listener service con callbacks
    await _listenerService.initialize(
      onCallDetected: _handleDetectedCall,
      onCallEnded: _handleCallEnded,
    );

    // Inicializar VoIP y configurar integration
    await _initializeVoIPIntegration();

    _globalListenersInitialized = true;

    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Listeners globales inicializados',
      tag: 'CallsOrchestrator',
    );
  }

  /// Dispose listeners globales
  void disposeGlobalListeners() {
    ReleaseLogger.log(
      '🧹 [CallsOrchestrator] Disposing global listeners...',
      tag: 'CallsOrchestrator',
    );

    _listenerService.dispose();
    // ✅ ROOT CAUSE FIX: Safe cancel para evitar MissingPluginException
    if (_pendingCallSubscription != null) {
      try {
        _pendingCallSubscription!.cancel();
        ReleaseLogger.log(
          '✅ [CallsOrchestrator] Pending call subscription cancelada exitosamente',
          tag: 'CallsOrchestrator',
        );
      } catch (e) {
        ReleaseLogger.log(
          '⚠️ [CallsOrchestrator] Error cancelando pending call subscription (ignorando): $e',
          tag: 'CallsOrchestrator',
        );
      }
    }
    _globalListenersInitialized = false;

    ReleaseLogger.log(
      '🧹 [CallsOrchestrator] Listeners globales disposed',
      tag: 'CallsOrchestrator',
    );
  }

  /// ✅ RECOVERY: Attempt to recover listeners if they were disposed
  Future<void> attemptListenerRecovery() async {
    ReleaseLogger.log(
      '🔍 [CallsOrchestrator] attemptListenerRecovery called - globalInit=$_globalListenersInitialized',
      tag: 'CallsOrchestrator',
    );

    final isHealthy =
        _listenerService.isHealthy; // Esto triggerea el log del health check

    if (_globalListenersInitialized && isHealthy) {
      ReleaseLogger.log(
        '✅ [CallsOrchestrator] Listeners are already healthy',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    if (!_globalListenersInitialized) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Listeners not initialized - cannot recover',
        tag: 'CallsOrchestrator',
      );
      return;
    }

    ReleaseLogger.log(
      '🔄 [CallsOrchestrator] Listener health check detected failure - recovering...',
      tag: 'CallsOrchestrator',
    );

    try {
      if (_lastDetectedCallCallback != null && _lastCallEndedCallback != null) {
        await _listenerService.attemptRecovery(
          onCallDetected: _lastDetectedCallCallback!,
          onCallEnded: _lastCallEndedCallback!,
        );

        ReleaseLogger.log(
          '✅ [CallsOrchestrator] Listener recovery completed',
          tag: 'CallsOrchestrator',
        );
      } else {
        ReleaseLogger.error(
          '❌ [CallsOrchestrator] Cannot recover - callbacks were not saved',
          tag: 'CallsOrchestrator',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Listener recovery failed: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Callback cuando el listener service detecta una llamada
  Future<void> _handleDetectedCall(String callId, String source) async {
    ReleaseLogger.log(
      '📲 [CallsOrchestrator] Llamada detectada por listener: $callId (source: $source)',
      tag: 'CallsOrchestrator',
    );

    // Delegar al método correspondiente según la source
    await processIncomingCall(callId, source: source);
  }

  /// Inicializar integración con VoIP (usa métodos existentes del VoIPService)
  Future<void> _initializeVoIPIntegration() async {
    if (!Platform.isIOS) return;

    try {
      // Inicializar VoIP service (usa su método initialize existente)
      if (_voipService != null) {
        await _voipService!.initialize();

        // Suscribirse al stream de llamadas pendientes
        _pendingCallSubscription = _voipService!.pendingCallStream.listen((
          callData,
        ) {
          ReleaseLogger.log(
            '📞 [CallsOrchestrator] VoIP call detected: ${callData['callId']}',
            tag: 'CallsOrchestrator',
          );

          final callId = callData['callId'] as String;
          processIncomingCall(callId, source: 'voip');
        });

        // Verificar llamadas pendientes al inicializar (usa método existente)
        await Future.delayed(const Duration(milliseconds: 500));
        final pendingData = _voipService!.getPendingCallData();
        if (pendingData != null) {
          ReleaseLogger.log(
            '📞 [CallsOrchestrator] Pending VoIP call found: ${pendingData['callId']}',
            tag: 'CallsOrchestrator',
          );

          final callId = pendingData['callId'] as String;
          await processIncomingCall(callId, source: 'voip');
        }
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error initializing VoIP integration: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }

  /// Verificar si el usuario tiene calls activas
  bool get hasActiveCalls => _callsService.hasActiveCalls;

  /// Obtener calls activas del usuario
  List<Call> get activeCalls => _callsService.activeCalls;

  /// Obtener contactos disponibles para agregar a una llamada
  Future<List<Map<String, dynamic>>> getAvailableContactsForCall({
    required String currentCallId,
    required String currentReceiverId,
  }) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) return [];

      ReleaseLogger.log(
        '🔍 [CallsOrchestrator] Obteniendo contactos disponibles para call $currentCallId',
        tag: 'CallsOrchestrator',
      );

      // Obtener contactos con aprobación bidireccional usando ChatPermissionService
      final chatPermissionService = ChatPermissionService();
      final bidirectionalContactIds = await chatPermissionService
          .getBidirectionallyApprovedContacts(currentUserId);

      final contacts = <Map<String, dynamic>>[];

      for (final contactId in bidirectionalContactIds) {
        // Evitar agregar al usuario actual a la lista
        if (contactId == currentUserId) continue;

        // Evitar agregar al usuario que ya está en la llamada
        if (contactId == currentReceiverId) continue;

        // Obtener información del contacto desde Firestore
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(contactId)
            .get();
        final userData = userDoc.data();

        if (userData != null) {
          final realName = userData['name'] ?? 'Usuario';

          // Usar ContactAliasService para obtener el nombre con alias si existe
          final contactAliasService = ContactAliasService();
          final displayName = await contactAliasService.getDisplayName(
            contactId,
            realName,
          );

          contacts.add({
            'contactId': contactId,
            'name': displayName,
            'photoUrl': userData['photoURL'] ?? '',
            'isOnline': userData['isOnline'] ?? false,
          });
        }
      }

      ReleaseLogger.log(
        '✅ [CallsOrchestrator] Encontrados ${contacts.length} contactos disponibles',
        tag: 'CallsOrchestrator',
      );

      return contacts;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error obteniendo contactos: $e',
        tag: 'CallsOrchestrator',
      );
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS PRIVADOS
  // ═══════════════════════════════════════════════════════════════

  /// Determinar si el usuario actual es el caller
  bool _isUserCaller(Call call) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    return call.createdBy == currentUserId;
  }


  /// Obtener nombre del otro participante
  Future<String> getOtherParticipantName(Call call) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) return 'Usuario';

      for (String participantId in call.participants.keys) {
        if (participantId != currentUserId) {
          return await _callsService.getUserDisplayName(participantId);
        }
      }
      return 'Usuario';
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error obteniendo nombre de participante: $e',
        tag: 'CallsOrchestrator',
      );
      return 'Usuario';
    }
  }

  /// Obtener nombre de participante específico por userId
  Future<String> getParticipantName(String userId) async {
    try {
      return await _callsService.getUserDisplayName(userId);
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error obteniendo nombre de participante $userId: $e',
        tag: 'CallsOrchestrator',
      );
      return 'Usuario';
    }
  }

  /// Iniciar nueva llamada y navegar (outgoing calls)
  Future<void> startCallAndNavigate({
    required BuildContext context,
    required String receiverId,
    required String remoteName,
    required bool isVideo,
    bool isEmergency = false,
  }) async {
    try {
      ReleaseLogger.log(
        '📞 [CallsOrchestrator] Iniciando nueva llamada - receiver: $receiverId, video: $isVideo',
        tag: 'CallsOrchestrator',
      );

      // Crear la llamada usando el service
      final result = await createCall(
        participantIds: [receiverId],
        type: isVideo ? 'video' : 'audio',
      );

      if (result['success'] == true) {
        final callId = result['callId'];

        // ✅ SIMPLIFIED: Usar callback para navegación directa
        _navigateToCallScreen(callId);

        ReleaseLogger.log(
          '✅ [CallsOrchestrator] Call iniciado exitosamente: $callId',
          tag: 'CallsOrchestrator',
        );
      } else {
        throw Exception('Failed to create call: ${result['error']}');
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error iniciando call: $e',
        tag: 'CallsOrchestrator',
      );
      rethrow;
    }
  }

  /// Navegar a una llamada usando el sistema de navegación centralizado
  Future<void> navigateToCall({
    required String callId,
    String? source,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // ✅ Extraer flag de metadata
      final replaceTemporary = metadata?['replaceTemporary'] as bool? ?? false;

      ReleaseLogger.log(
        '🧭 [CallsOrchestrator] Navegando a llamada - callId: $callId, source: $source, replace: $replaceTemporary',
        tag: 'CallsOrchestrator',
      );

      // ✅ FIX CRÍTICO: Usar operación atómica para prevenir race conditions
      if (!_tryStartNavigation(callId)) {
        return; // Ya navegando
      }

      _navigateToCallScreen(callId, replaceTemporary: replaceTemporary);

      ReleaseLogger.log(
        '✅ [CallsOrchestrator] Navegación exitosa: $callId',
        tag: 'CallsOrchestrator',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error en navegación: $e',
        tag: 'CallsOrchestrator',
      );
      // ✅ FIX: Remover del set en caso de error para no bloquear futuras navegaciones
      _navigatingCallIds.remove(callId);
      rethrow;
    }
  }


  // ═══════════════════════════════════════════════════════════════
  // CALLKIT COORDINATION
  // ═══════════════════════════════════════════════════════════════

  /// Marcar llamada como siendo manejada por CallKit
  void markCallAsCallKitHandled(String callId) {
    _callKitActiveCallIds.add(callId);
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Llamada $callId marcada como manejada por CallKit',
      tag: 'CallsOrchestrator',
    );
  }

  /// Desmarcar llamada cuando CallKit termine
  void unmarkCallKitCall(String callId) {
    _callKitActiveCallIds.remove(callId);

    // ✅ FIXED: También limpiar tracking de navegación
    _navigatingCallIds.remove(callId);

    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Llamada $callId desmarcada de CallKit y tracking limpiado',
      tag: 'CallsOrchestrator',
    );
  }

  /// Verificar si una llamada está siendo manejada por CallKit/VoIP
  /// ✅ PÚBLICO: Usado por CallController para determinar estado de UI
  bool isCallBeingHandledByCallKit(String callId) {
    // ✅ FIX: Verificar AMBOS sets (CallKit y VoIP) para iOS
    final isHandledByCallKit = _callKitActiveCallIds.contains(callId);
    final isHandledByVoIP = _voipService?.isCallHandledByVoIP(callId) ?? false;
    final isHandled = isHandledByCallKit || isHandledByVoIP;

    ReleaseLogger.log(
      '🔍 [CallsOrchestrator] Verificando CallKit/VoIP para $callId: ${isHandled ? "SÍ manejada" : "NO manejada"} (CallKit:$isHandledByCallKit, VoIP:$isHandledByVoIP)',
      tag: 'CallsOrchestrator',
    );
    return isHandled;
  }

  // ✅ FIXED: Método público para marcar llamada como navegando desde IncomingCallScreen
  /// Marcar llamada como navegando para evitar navegación duplicada automática
  void markCallAsNavigating(String callId) {
    _navigatingCallIds.add(callId);
    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Llamada $callId marcada como navegando desde IncomingCallScreen',
      tag: 'CallsOrchestrator',
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // CALLKIT NOTIFICATION TERMINATION
  // ═══════════════════════════════════════════════════════════════

  /// ✅ CRITICAL FIX: Terminar notificaciones CallKit cuando una llamada se cancela
  ///
  /// Este método resuelve el problema donde las notificaciones CallKit
  /// seguían sonando después de que A cancelara la llamada antes de que B respondiera.
  Future<void> _terminateCallKitNotification(String callId) async {
    try {
      ReleaseLogger.log(
        '📞 [CallsOrchestrator] Terminando notificación CallKit para callId: $callId',
        tag: 'CallsOrchestrator',
      );

      ReleaseLogger.log(
        '🔍 [DEBUG] _terminateCallKitNotification - Platform: ${Platform.operatingSystem}',
        tag: 'CallsOrchestrator',
      );

      // Verificar si tenemos servicios disponibles
      if (_callKitService == null) {
        ReleaseLogger.error(
          '❌ [CallsOrchestrator] CallKitService no disponible - no se puede terminar notificación',
          tag: 'CallsOrchestrator',
        );
        ReleaseLogger.error(
          '❌ [DEBUG] _terminateCallKitNotification - _callKitService is NULL!',
          tag: 'CallsOrchestrator',
        );
        return;
      }

      ReleaseLogger.log(
        '✅ [DEBUG] _terminateCallKitNotification - _callKitService is available',
        tag: 'CallsOrchestrator',
      );

      // ✅ ANDROID: Terminar CallKit notification
      if (Platform.isAndroid) {
        await _callKitService!.endCall(callId);
        await _callKitService!.endAllCalls();
        ReleaseLogger.log(
          '✅ [CallsOrchestrator] CallKit terminado para $callId',
          tag: 'CallsOrchestrator',
        );
      }

      // ✅ iOS: Terminar CallKit y VoIP
      if (Platform.isIOS) {
        await _callKitService!.endCall(callId);
        await _callKitService!.endAllCalls();
        if (_voipService != null) {
          await _voipService!.notifyCallEnded(callId);
        }
        ReleaseLogger.log(
          '✅ [CallsOrchestrator] CallKit y VoIP terminados para $callId',
          tag: 'CallsOrchestrator',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error crítico terminando CallKit para $callId: $e',
        tag: 'CallsOrchestrator',
      );
    }
  }
}
