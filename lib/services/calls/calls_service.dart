import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'repositories/calls_repository.dart';
import '../../models/call.dart';
import '../../utils/release_logger.dart';

/// Service principal para monitoreo de calls unificadas
///
/// Este service se integra en main.dart para:
/// - Monitorear calls donde participa el usuario actual
/// - Mostrar notificaciones automáticas para calls entrantes
/// - Navegar automáticamente a VideoCallScreen cuando el usuario acepta
/// - Manejar estados de call en tiempo real
class CallsService {
  static CallsService? _instance;

  factory CallsService({
    CallsRepository? repository,
    FirebaseAuth? auth,
    FirebaseFunctions? functions,
  }) {
    _instance ??= CallsService._internal(
      repository ?? CallsRepository(),
      auth ?? FirebaseAuth.instance,
      functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
    );
    return _instance!;
  }

  CallsService._internal(this._repository, this._auth, this._functions);

  final CallsRepository _repository;
  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  // Streams y subscriptions
  StreamSubscription<List<Call>>? _userCallsSubscription;
  StreamSubscription<User?>? _authSubscription;

  // Estado interno
  String? _currentUserId;
  List<Call> _activeCalls = [];

  // Callbacks para comunicación con main.dart
  Function(Call call)? onIncomingCall;
  Function(Call call)? onCallStatusChanged;
  Function(String callId)? onCallEnded;
  Function(Call call)? onMissedCall; // ✅ NUEVO: Para notificaciones de llamada perdida
  Function(String error)? onError;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

  /// Inicializar service y empezar monitoreo
  ///
  /// Debe ser llamado desde main.dart después de inicializar Firebase
  void initialize() {
    ReleaseLogger.log('🎧 [CallsService] Inicializando service de calls', tag: 'CallsService');

    // Monitorear cambios de autenticación
    _authSubscription = _auth.authStateChanges().listen(_onAuthStateChanged);

    // Si ya hay un usuario logueado, iniciar monitoreo inmediatamente
    if (_auth.currentUser != null) {
      _startMonitoring(_auth.currentUser!.uid);
    }
  }

  /// Manejar cambios de estado de autenticación
  void _onAuthStateChanged(User? user) {
    if (user != null && user.uid != _currentUserId) {
      ReleaseLogger.log('👤 [CallsService] Usuario logueado: ${user.uid}', tag: 'CallsService');
      _startMonitoring(user.uid);
    } else if (user == null) {
      ReleaseLogger.log('👤 [CallsService] Usuario deslogueado', tag: 'CallsService');
      _stopMonitoring();
    }
  }

  /// Iniciar monitoreo de calls para el usuario
  void _startMonitoring(String userId) {
    _currentUserId = userId;

    // Cancelar subscription anterior si existe
    _userCallsSubscription?.cancel();

    ReleaseLogger.log('👀 [CallsService] Iniciando monitoreo de calls para: $userId', tag: 'CallsService');

    // Monitorear calls del usuario en tiempo real
    _userCallsSubscription = _repository.watchUserCalls(userId: userId).listen(
      _onCallsChanged,
      onError: (error) {
        ReleaseLogger.error('❌ [CallsService] Error en stream de calls: $error', tag: 'CallsService');
        onError?.call('Error monitoreando llamadas: $error');
      },
    );
  }

  /// Detener monitoreo
  void _stopMonitoring() {
    _currentUserId = null;
    _activeCalls.clear();
    _userCallsSubscription?.cancel();
    _userCallsSubscription = null;

    ReleaseLogger.log('🔇 [CallsService] Monitoreo detenido', tag: 'CallsService');
  }

  /// Procesar cambios en las calls del usuario
  void _onCallsChanged(List<Call> calls) {
    ReleaseLogger.log('🔄 [CallsService] Calls actualizadas: ${calls.length} activas', tag: 'CallsService');

    final previousCalls = Map.fromEntries(_activeCalls.map((call) => MapEntry(call.id, call)));

    for (final call in calls) {
      final previousCall = previousCalls[call.id];
      final currentUserStatus = call.participants[_currentUserId]?.status;

      if (previousCall == null) {
        // ✅ Nueva call detectada
        ReleaseLogger.log('📞 [CallsService] Nueva call detectada: ${call.id} (status: $currentUserStatus)', tag: 'CallsService');

        if (currentUserStatus == 'waiting' && call.endedAt == null) {
          // Call entrante activa - mostrar notificación
          _handleIncomingCall(call);
        } else if (currentUserStatus == 'waiting' && call.endedAt != null) {
          // ✅ NUEVO: Call que llegó ya terminada - fue llamada perdida
          ReleaseLogger.log('📞 [CallsService] Call perdida detectada al llegar: ${call.id}', tag: 'CallsService');
          _handleMissedCall(call);
        }
      } else {
        // ✅ Call existente - verificar cambios de estado
        final previousStatus = previousCall.participants[_currentUserId]?.status;

        if (previousStatus != currentUserStatus) {
          ReleaseLogger.log('🔄 [CallsService] Call ${call.id} cambió estado: $previousStatus → $currentUserStatus', tag: 'CallsService');

          if (currentUserStatus == 'joined') {
            // Usuario se unió - notificar para navegación
            _handleCallJoined(call);
          } else if (currentUserStatus == 'ended' || call.endedAt != null) {
            // ✅ NUEVO: Detectar si fue llamada perdida
            if (previousStatus == 'waiting') {
              // Usuario estaba esperando y la llamada se terminó → llamada perdida
              _handleMissedCall(call);
            } else {
              // Call terminada normalmente
              _handleCallEnded(call);
            }
          }
        } else if (call.endedAt != null && previousCall.endedAt == null) {
          // ✅ NUEVO: La llamada se marcó como terminada sin cambio de estado del usuario
          ReleaseLogger.log('🔄 [CallsService] Call ${call.id} marcada como terminada (endedAt changed)', tag: 'CallsService');

          if (currentUserStatus == 'waiting') {
            // Usuario seguía esperando cuando se terminó → llamada perdida
            _handleMissedCall(call);
          } else {
            // Call terminada normalmente
            _handleCallEnded(call);
          }
        }

        // Notificar cambios generales de estado
        onCallStatusChanged?.call(call);
      }
    }

    // Detectar calls que fueron eliminadas
    final currentCallIds = calls.map((call) => call.id).toSet();
    for (final previousCall in _activeCalls) {
      if (!currentCallIds.contains(previousCall.id)) {
        ReleaseLogger.log('🗑️ [CallsService] Call eliminada: ${previousCall.id}', tag: 'CallsService');

        // ✅ NUEVO: Detectar si fue llamada perdida al ser eliminada
        final userStatus = previousCall.participants[_currentUserId]?.status;
        if (userStatus == 'waiting') {
          // Usuario estaba esperando y la llamada fue eliminada → llamada perdida
          _handleMissedCall(previousCall);
        } else {
          // Call eliminada normalmente
          _handleCallEnded(previousCall);
        }
      }
    }

    _activeCalls = calls;
  }

  /// Manejar call entrante (waiting)
  void _handleIncomingCall(Call call) {
    ReleaseLogger.log('📞 [CallsService] Call entrante: ${call.id} (${call.type})', tag: 'CallsService');

    // Notificar a main.dart para mostrar notificación/CallKit
    onIncomingCall?.call(call);

    // En un entorno real, aquí también se triggerea CallKit/VoIP
    // _showCallKitNotification(call);
  }

  /// Manejar cuando el usuario se une a una call
  void _handleCallJoined(Call call) {
    ReleaseLogger.log('✅ [CallsService] Usuario se unió a call: ${call.id}', tag: 'CallsService');

    // Este evento se puede usar para navegación automática en main.dart
    onCallStatusChanged?.call(call);
  }

  /// Manejar call terminada
  void _handleCallEnded(Call call) {
    ReleaseLogger.log('📞 [CallsService] Call terminada: ${call.id}', tag: 'CallsService');

    onCallEnded?.call(call.id);
  }

  /// Manejar llamada perdida
  ///
  /// Se activa cuando una llamada se termina/elimina mientras el usuario
  /// estaba en estado 'waiting' (nunca contestó)
  void _handleMissedCall(Call call) {
    ReleaseLogger.log('📞 [CallsService] Llamada perdida detectada: ${call.id} (${call.type})', tag: 'CallsService');

    // Notificar a main.dart para mostrar notificación de llamada perdida
    onMissedCall?.call(call);

    // También terminar la call para limpiar el estado
    onCallEnded?.call(call.id);
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS PÚBLICOS PARA ACCIONES DEL USUARIO
  // ═══════════════════════════════════════════════════════════════

  /// Crear nueva call (1-1 o grupal)
  Future<Map<String, dynamic>> createCall({
    required List<String> participantIds,
    required String type, // 'video' | 'audio'
    String? customChannelName,
  }) async {
    try {
      ReleaseLogger.log('🚀 [CallsService] Creando call $type con ${participantIds.length} participantes', tag: 'CallsService');

      final callable = _functions.httpsCallable('createCall');
      final result = await callable.call({
        'participantIds': participantIds,
        'type': type,
        'customChannelName': customChannelName,
      });

      final data = result.data as Map<String, dynamic>;

      if (data['success'] == true) {
        ReleaseLogger.log('✅ [CallsService] Call creada exitosamente: ${data['callId']}', tag: 'CallsService');
      } else {
        ReleaseLogger.error('❌ [CallsService] Error creando call: ${data['error']}', tag: 'CallsService');
      }

      return data;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsService] Exception creando call: $e', tag: 'CallsService');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Agregar participantes a call existente
  Future<Map<String, dynamic>> addParticipants({
    required String callId,
    required List<String> newParticipantIds,
  }) async {
    try {
      ReleaseLogger.log('➕ [CallsService] Agregando ${newParticipantIds.length} participantes a $callId', tag: 'CallsService');

      final callable = _functions.httpsCallable('addParticipants');
      final result = await callable.call({
        'callId': callId,
        'newParticipantIds': newParticipantIds,
      });

      final data = result.data as Map<String, dynamic>;

      if (data['success'] == true) {
        ReleaseLogger.log('✅ [CallsService] Participantes agregados exitosamente', tag: 'CallsService');
      } else {
        ReleaseLogger.error('❌ [CallsService] Error agregando participantes: ${data['error']}', tag: 'CallsService');
      }

      return data;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsService] Exception agregando participantes: $e', tag: 'CallsService');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Aceptar call entrante
  Future<bool> acceptCall(String callId) async {
    try {
      ReleaseLogger.log('✅ [CallsService] Aceptando call: $callId', tag: 'CallsService');

      final participant = CallParticipant(
        status: 'joined',
        joinedAt: DateTime.now(),
      );

      final success = await _repository.updateParticipantStatus(
        callId: callId,
        participantId: _currentUserId!,
        newParticipantData: participant,
      );

      if (success) {
        ReleaseLogger.log('✅ [CallsService] Call aceptada exitosamente', tag: 'CallsService');
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsService] Error aceptando call: $e', tag: 'CallsService');
      return false;
    }
  }

  /// Rechazar call entrante
  Future<bool> declineCall(String callId, {String reason = 'declined'}) async {
    try {
      ReleaseLogger.log('❌ [CallsService] Rechazando call: $callId (reason: $reason)', tag: 'CallsService');

      final participant = CallParticipant(
        status: 'declined',
        declinedAt: DateTime.now(),
        declineReason: reason,
      );

      final success = await _repository.updateParticipantStatus(
        callId: callId,
        participantId: _currentUserId!,
        newParticipantData: participant,
      );

      if (success) {
        ReleaseLogger.log('✅ [CallsService] Call rechazada exitosamente', tag: 'CallsService');
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsService] Error rechazando call: $e', tag: 'CallsService');
      return false;
    }
  }

  /// Terminar call activa
  Future<bool> endCall(String callId) async {
    try {
      ReleaseLogger.log('📞 [CallsService] Terminando call: $callId', tag: 'CallsService');

      // ✅ NUEVO: Primero obtener la call para verificar si es 1-1
      final call = await _repository.getCallById(callId);
      if (call == null) {
        ReleaseLogger.error('❌ [CallsService] Call no encontrada: $callId', tag: 'CallsService');
        return false;
      }

      final participantCount = call.participants.length;
      ReleaseLogger.log('📊 [CallsService] Call tiene $participantCount participantes', tag: 'CallsService');

      // ✅ NUEVO: Para llamadas 1-1 (2 participantes), terminar toda la call
      if (participantCount == 2) {
        ReleaseLogger.log('🔚 [CallsService] Llamada 1-1 detectada, terminando para todos los participantes', tag: 'CallsService');

        // Usar la repository directamente para actualizar endedAt de toda la call
        final success = await _repository.endEntireCall(callId);

        if (success) {
          ReleaseLogger.log('✅ [CallsService] Call 1-1 terminada exitosamente para todos', tag: 'CallsService');
        } else {
          ReleaseLogger.error('❌ [CallsService] Error terminando call 1-1', tag: 'CallsService');
        }

        return success;
      }

      // ✅ Para llamadas grupales (3+ participantes), solo actualizar el participante actual
      ReleaseLogger.log('👥 [CallsService] Llamada grupal detectada, solo actualizando participante actual', tag: 'CallsService');

      final participant = CallParticipant(
        status: 'ended',
        endedAt: DateTime.now(),
      );

      final success = await _repository.updateParticipantStatus(
        callId: callId,
        participantId: _currentUserId!,
        newParticipantData: participant,
      );

      if (success) {
        ReleaseLogger.log('✅ [CallsService] Participante actual marcado como terminado', tag: 'CallsService');
      }

      return success;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsService] Error terminando call: $e', tag: 'CallsService');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GETTERS Y UTILIDADES
  // ═══════════════════════════════════════════════════════════════

  /// Obtener call específica por ID
  Future<Call?> getCall(String callId) async {
    return await _repository.getCallById(callId);
  }

  /// Stream de una call específica
  Stream<Call?> watchCall(String callId) {
    return _repository.watchCall(callId);
  }

  /// Verificar si el usuario tiene calls activas
  bool get hasActiveCalls => _activeCalls.isNotEmpty;

  /// Obtener calls activas del usuario
  List<Call> get activeCalls => List.unmodifiable(_activeCalls);

  /// Obtener call activa por tipo
  Call? getActiveCallByType(String type) {
    try {
      return _activeCalls.firstWhere((call) => call.type == type);
    } catch (e) {
      return null;
    }
  }

  /// Verificar si el usuario está actualmente en una videollamada
  bool get isInVideoCall {
    return _activeCalls.any((call) =>
        call.type == 'video' &&
        call.participants[_currentUserId]?.status == 'joined');
  }

  /// Verificar si el usuario está actualmente en una llamada de audio
  bool get isInAudioCall {
    return _activeCalls.any((call) =>
        call.type == 'audio' &&
        call.participants[_currentUserId]?.status == 'joined');
  }

  /// Dispose del service
  void dispose() {
    ReleaseLogger.log('🔇 [CallsService] Disposing service', tag: 'CallsService');

    _userCallsSubscription?.cancel();
    _authSubscription?.cancel();

    _currentUserId = null;
    _activeCalls.clear();

    // Limpiar callbacks
    onIncomingCall = null;
    onCallStatusChanged = null;
    onCallEnded = null;
    onMissedCall = null; // ✅ NUEVO: Limpiar callback de llamada perdida
    onError = null;
  }
}