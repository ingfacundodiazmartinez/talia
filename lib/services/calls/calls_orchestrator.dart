import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'calls_service.dart';
import '../../models/call.dart';
import '../../utils/release_logger.dart';
import '../../screens/audio_call_screen.dart';
import '../../screens/video_call_screen.dart';
import '../../screens/common/incoming_call_screen.dart';
import '../callkit_service.dart';
import '../voip_service.dart';
import '../chat_permission_service.dart';
import '../contact_alias_service.dart';

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

  // State management
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _isInitialized = false;

  // Navigation tracking para evitar loops infinitos
  final Set<String> _navigatingCallIds = <String>{};

  // ✅ ADDED: CallKit coordination para evitar IncomingCallScreen duplicado
  final Set<String> _callKitActiveCallIds = <String>{};

  // Callbacks para main.dart (interfaz mínima)
  Function(Call call)? onIncomingCall;
  Function(Call call)? onCallStatusChanged;
  Function(String callId)? onCallEnded;
  Function(String error)? onError;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

  /// Inicializar orchestrator - llamado desde main.dart
  Future<void> initialize({required GlobalKey<NavigatorState> navigatorKey}) async {
    if (_isInitialized) return;

    _navigatorKey = navigatorKey;

    ReleaseLogger.log('🎧 [CallsOrchestrator] Inicializando orchestrator', tag: 'CallsOrchestrator');

    // Configurar callbacks del CallsService
    _callsService.onIncomingCall = _handleIncomingCall;
    _callsService.onCallStatusChanged = _handleCallStatusChanged;
    _callsService.onCallEnded = _handleCallEnded;
    _callsService.onError = _handleError;

    // Inicializar el service
    _callsService.initialize();

    // ✅ ADDED: Inicializar servicios de CallKit para cancelación automática
    _callKitService = CallKitService();
    if (Platform.isIOS) {
      _voipService = VoIPService();
    }
    ReleaseLogger.log('✅ [CallsOrchestrator] Servicios CallKit inicializados', tag: 'CallsOrchestrator');

    _isInitialized = true;
    ReleaseLogger.log('✅ [CallsOrchestrator] Orchestrator inicializado', tag: 'CallsOrchestrator');
  }

  /// Dispose del orchestrator
  void dispose() {
    ReleaseLogger.log('🔇 [CallsOrchestrator] Disposing orchestrator', tag: 'CallsOrchestrator');

    _callsService.dispose();
    _navigatorKey = null;
    _isInitialized = false;

    // Limpiar tracking de navegación
    _navigatingCallIds.clear();

    // Limpiar callbacks
    onIncomingCall = null;
    onCallStatusChanged = null;
    onCallEnded = null;
    onError = null;
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
        tag: 'CallsOrchestrator'
      );

      // Solo mostrar notificaciones para llamadas entrantes (status: waiting)
      if (currentUserStatus == 'waiting') {
        _showIncomingCallScreen(call);

        // Notificar a main.dart para integración con CallKit/VoIP existente
        onIncomingCall?.call(call);
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error manejando llamada entrante: $e',
        tag: 'CallsOrchestrator'
      );
    }
  }

  /// Manejar cambios de estado de llamada
  void _handleCallStatusChanged(Call call) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) return;

      final currentUserStatus = call.participants[currentUserId]?.status;

      ReleaseLogger.log(
        '🔄 [CallsOrchestrator] Estado de llamada ${call.id} cambió: $currentUserStatus',
        tag: 'CallsOrchestrator'
      );

      // Si el usuario se unió a la llamada, navegar automáticamente SOLO si no está ya en una call screen Y la llamada NO ha terminado
      if (currentUserStatus == 'joined' && call.endedAt == null) {
        _navigateToCallScreenIfNeeded(call);
      }

      // Notificar a main.dart para integración existente
      onCallStatusChanged?.call(call);
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error manejando cambio de estado: $e',
        tag: 'CallsOrchestrator'
      );
    }
  }

  /// Manejar llamada terminada
  void _handleCallEnded(String callId) {
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Llamada terminada: $callId',
      tag: 'CallsOrchestrator'
    );

    // ✅ CRÍTICO: Terminar notificaciones CallKit activas para esta llamada
    _terminateCallKitNotification(callId);

    // Limpiar tracking de navegación para esta llamada
    _navigatingCallIds.remove(callId);

    // Limpiar tracking de CallKit para esta llamada
    _callKitActiveCallIds.remove(callId);

    // Notificar a main.dart
    onCallEnded?.call(callId);
  }

  /// Manejar errores del CallsService
  void _handleError(String error) {
    ReleaseLogger.error(
      '❌ [CallsOrchestrator] Error en CallsService: $error',
      tag: 'CallsOrchestrator'
    );

    // Notificar a main.dart
    onError?.call(error);
  }

  // ═══════════════════════════════════════════════════════════════
  // NAVEGACIÓN AUTOMÁTICA
  // ═══════════════════════════════════════════════════════════════

  /// Mostrar IncomingCallScreen para llamadas entrantes
  void _showIncomingCallScreen(Call call) {
    if (_navigatorKey?.currentContext == null) return;

    final context = _navigatorKey!.currentContext!;

    // ✅ NUEVO: Verificar si la llamada ya terminó
    if (call.endedAt != null) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Llamada ${call.id} ya terminó (endedAt: ${call.endedAt}) - NO mostrar IncomingCallScreen',
        tag: 'CallsOrchestrator'
      );
      return;
    }

    // ✅ FIXED: Verificar si CallKit ya está manejando esta llamada
    if (_isCallBeingHandledByCallKit(call.id)) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Llamada ${call.id} ya siendo manejada por CallKit - NO mostrar IncomingCallScreen',
        tag: 'CallsOrchestrator'
      );
      return;
    }

    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Mostrando IncomingCallScreen para ${call.id}',
      tag: 'CallsOrchestrator'
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => IncomingCallScreen(
          callId: call.id,
          callerName: _getCallerName(call),
          callerId: call.createdBy,
          callerPhotoUrl: null, // TODO: Obtener desde participants data
          callType: call.type,
          channelName: call.channelName,
          token: call.token,
          uid: 0, // Se generará dinámicamente
          isEmergency: false, // TODO: Agregar campo isEmergency al modelo
        ),
      ),
    );
  }

  /// Navegar a call screen solo si no está ya en una
  void _navigateToCallScreenIfNeeded(Call call) {
    if (_navigatorKey?.currentContext == null) return;

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;

    // Si el usuario actual es el creador de la llamada (caller),
    // no navegar automáticamente porque ya debe estar en VideoCallScreen
    if (call.createdBy == currentUserId) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Evitando navegación automática para caller - ya debe estar en VideoCallScreen',
        tag: 'CallsOrchestrator'
      );
      return;
    }

    // ✅ VoIP FIX: Para llamadas CallKit/VoIP, SÍ necesitamos navegar cuando se unen
    // Solo bloquear navegación para incoming calls que ya están en foreground
    if (_isCallBeingHandledByCallKit(call.id)) {
      // Obtener status del participante actual
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final currentParticipant = call.participants[currentUserId];
      final participantStatus = currentParticipant?.status;

      // Para VoIP/CallKit calls, permitir navegación cuando status = 'joined'
      if (participantStatus == 'joined') {
        ReleaseLogger.log(
          '🚀 [CallsOrchestrator] Llamada VoIP/CallKit ${call.id} se unió - SÍ navegar a VideoCallScreen',
          tag: 'CallsOrchestrator'
        );
        // Continuar con la navegación
      } else {
        ReleaseLogger.log(
          '⚠️ [CallsOrchestrator] Llamada ${call.id} ya siendo manejada por CallKit - NO navegar automáticamente (status: $participantStatus)',
          tag: 'CallsOrchestrator'
        );
        return;
      }
    }

    // ✅ ROOT CAUSE FIX: Usar tracking interno en lugar de ModalRoute detection
    // Para receivers: verificar si ya estamos navegando a esta llamada
    if (_navigatingCallIds.contains(call.id)) {
      ReleaseLogger.log(
        '⚠️ [CallsOrchestrator] Ya navegando a call ${call.id} - evitando navegación duplicada',
        tag: 'CallsOrchestrator'
      );
      return;
    }

    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Navegando automáticamente para receiver a call ${call.id}',
      tag: 'CallsOrchestrator'
    );

    // Marcar como "navegando" ANTES de navegar
    _navigatingCallIds.add(call.id);

    _navigateToCallScreen(call);
  }

  /// Navegar automáticamente a call screen cuando usuario se une
  void _navigateToCallScreen(Call call) {
    if (_navigatorKey?.currentContext == null) return;

    final context = _navigatorKey!.currentContext!;

    ReleaseLogger.log(
      '✅ [CallsOrchestrator] Navegando a ${call.type}CallScreen para ${call.id}',
      tag: 'CallsOrchestrator'
    );

    if (call.type == 'audio') {
      Navigator.of(context).push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/AudioCallScreen'), // ✅ FIXED: Named route for navigation detection
          builder: (context) => AudioCallScreen(
            callId: call.id,
            channelName: call.channelName,
            token: call.token ?? '',
            uid: 0, // Se generará dinámicamente
            isCaller: _isUserCaller(call),
            remoteName: _getOtherParticipantName(call),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/VideoCallScreen'), // ✅ FIXED: Named route for navigation detection
          builder: (context) => VideoCallScreen(
            callId: call.id,
            channelName: call.channelName,
            token: call.token ?? '',
            uid: 0, // Se generará dinámicamente
            isCaller: _isUserCaller(call),
            remoteName: _getOtherParticipantName(call),
            receiverId: call.createdBy,
            isVideo: true,
          ),
        ),
      );
    }
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
    return await _callsService.createCall(
      participantIds: participantIds,
      type: type,
      customChannelName: customChannelName,
    );
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

  /// Obtener call específica por ID
  Future<Call?> getCall(String callId) async {
    return await _callsService.getCall(callId);
  }

  /// Stream de una call específica
  Stream<Call?> watchCall(String callId) {
    return _callsService.watchCall(callId);
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
        tag: 'CallsOrchestrator'
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
          final displayName = await contactAliasService.getDisplayName(contactId, realName);

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
        tag: 'CallsOrchestrator'
      );

      return contacts;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsOrchestrator] Error obteniendo contactos: $e', tag: 'CallsOrchestrator');
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

  /// Obtener nombre del caller para llamadas entrantes
  String _getCallerName(Call call) {
    // TODO: Obtener nombre real desde user data o participants
    return 'Usuario'; // Placeholder
  }

  /// Obtener nombre del otro participante
  String _getOtherParticipantName(Call call) {
    // TODO: Obtener nombre real del otro participante
    return 'Usuario'; // Placeholder
  }

  // ═══════════════════════════════════════════════════════════════
  // CALLKIT COORDINATION
  // ═══════════════════════════════════════════════════════════════

  /// Marcar llamada como siendo manejada por CallKit
  void markCallAsCallKitHandled(String callId) {
    _callKitActiveCallIds.add(callId);
    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Llamada $callId marcada como manejada por CallKit',
      tag: 'CallsOrchestrator'
    );
  }

  /// Desmarcar llamada cuando CallKit termine
  void unmarkCallKitCall(String callId) {
    _callKitActiveCallIds.remove(callId);

    // ✅ FIXED: También limpiar tracking de navegación
    _navigatingCallIds.remove(callId);

    ReleaseLogger.log(
      '📞 [CallsOrchestrator] Llamada $callId desmarcada de CallKit y tracking limpiado',
      tag: 'CallsOrchestrator'
    );
  }

  /// Verificar si una llamada está siendo manejada por CallKit
  bool _isCallBeingHandledByCallKit(String callId) {
    final isHandled = _callKitActiveCallIds.contains(callId);
    ReleaseLogger.log(
      '🔍 [CallsOrchestrator] Verificando CallKit para $callId: ${isHandled ? "SÍ manejada" : "NO manejada"}',
      tag: 'CallsOrchestrator'
    );
    return isHandled;
  }

  // ✅ FIXED: Método público para marcar llamada como navegando desde IncomingCallScreen
  /// Marcar llamada como navegando para evitar navegación duplicada automática
  void markCallAsNavigating(String callId) {
    _navigatingCallIds.add(callId);
    ReleaseLogger.log(
      '📱 [CallsOrchestrator] Llamada $callId marcada como navegando desde IncomingCallScreen',
      tag: 'CallsOrchestrator'
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // CALLKIT NOTIFICATION TERMINATION
  // ═══════════════════════════════════════════════════════════════

  /// ✅ CRITICAL FIX: Terminar notificaciones CallKit cuando una llamada se cancela
  ///
  /// Este método resuelve el problema donde las notificaciones CallKit
  /// seguían sonando después de que A cancelara la llamada antes de que B respondiera.
  void _terminateCallKitNotification(String callId) {
    try {
      ReleaseLogger.log(
        '📞 [CallsOrchestrator] Terminando notificación CallKit para callId: $callId',
        tag: 'CallsOrchestrator'
      );

      // Verificar si tenemos servicios disponibles
      if (_callKitService == null) {
        ReleaseLogger.error(
          '❌ [CallsOrchestrator] CallKitService no disponible - no se puede terminar notificación',
          tag: 'CallsOrchestrator'
        );
        return;
      }

      // ✅ ANDROID: Terminar CallKit notification
      if (Platform.isAndroid) {
        _callKitService!.endCall(callId).then((_) {
          ReleaseLogger.log(
            '✅ [CallsOrchestrator] Notificación Android CallKit terminada para $callId',
            tag: 'CallsOrchestrator'
          );
        }).catchError((e) {
          ReleaseLogger.error(
            '❌ [CallsOrchestrator] Error terminando Android CallKit para $callId: $e',
            tag: 'CallsOrchestrator'
          );
        });
      }

      // ✅ iOS: Terminar VoIP notification
      if (Platform.isIOS && _voipService != null) {
        _voipService!.notifyCallEnded(callId).then((_) {
          ReleaseLogger.log(
            '✅ [CallsOrchestrator] Notificación iOS VoIP terminada para $callId',
            tag: 'CallsOrchestrator'
          );
        }).catchError((e) {
          ReleaseLogger.error(
            '❌ [CallsOrchestrator] Error terminando iOS VoIP para $callId: $e',
            tag: 'CallsOrchestrator'
          );
        });
      }

    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallsOrchestrator] Error crítico terminando CallKit para $callId: $e',
        tag: 'CallsOrchestrator'
      );
    }
  }
}