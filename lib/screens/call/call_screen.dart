import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/calls/calls_orchestrator.dart';
import '../../services/calls/call_stack_navigator.dart';
import '../../models/call.dart';
import '../../utils/release_logger.dart';
import 'video/video_call_screen.dart';
import 'audio/audio_call_screen.dart';
import 'common/incoming_call_screen.dart';

/// Router principal para llamadas que decide qué widget mostrar
///
/// Responsabilidades:
/// - Determinar si es llamada entrante o activa
/// - Determinar si es audio o video
/// - Navegar al widget apropiado
/// - Manejar transiciones entre estados
class CallScreen extends StatefulWidget {
  final String callId;

  const CallScreen({super.key, required this.callId});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Call? _currentCall;
  bool _isLoading = true;
  String _otherParticipantName = 'Usuario';
  bool _isCreatingCall = false;
  StreamSubscription? _callEndListener;

  @override
  void initState() {
    super.initState();
    _loadCallData();
    _setupCallTerminationListener();
  }

  /// Configurar listener para detectar cuando la llamada termina
  void _setupCallTerminationListener() {
    // Solo configurar si no es una llamada temporal
    if (widget.callId.startsWith('temp_')) return;

    try {
      _callEndListener = CallsOrchestrator()
          .watchCall(widget.callId)
          .listen((call) {
        if (call?.endedAt != null && mounted) {
          ReleaseLogger.log(
            '🔚 [CallScreen] Detectada terminación de llamada ${widget.callId} - cerrando automáticamente',
            tag: 'CallScreen',
          );

          // ✅ CALL STACK: Notificar cierre al stack navigator
          CallStackNavigator.onCallScreenClosed(widget.callId);

          // Cerrar la pantalla
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            CallsOrchestrator().navigateBackSafely(context, source: 'call_screen_ended');
          }
        }
      });
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallScreen] Error configurando listener de terminación: $e',
        tag: 'CallScreen',
      );
    }
  }

  /// Cargar datos de la llamada desde Firestore
  Future<void> _loadCallData() async {
    try {
      // ✅ UX FIX: Detectar si es una llamada temporal (en proceso de creación)
      if (widget.callId.startsWith('temp_')) {
        setState(() {
          _isCreatingCall = true;
          _isLoading = false;
        });

        // Iniciar polling para esperar que la llamada real se cree
        _pollForRealCall();
        return;
      }

      final call = await CallsOrchestrator().getCall(widget.callId);

      // Si tenemos la call, obtener el nombre del otro participante
      String participantName = 'Usuario';
      if (call != null) {
        participantName = await CallsOrchestrator().getOtherParticipantName(
          call,
        );
      }

      if (mounted) {
        setState(() {
          _currentCall = call;
          _otherParticipantName = participantName;
          _isLoading = false;
          _isCreatingCall = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallScreen] Error cargando datos de llamada: $e',
        tag: 'CallScreen',
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isCreatingCall = false;
        });
      }
    }
  }

  /// Polling para esperar que se cree la llamada real
  void _pollForRealCall() async {
    int attempts = 0;
    const maxAttempts = 30; // 15 segundos máximo
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    while (attempts < maxAttempts && mounted && _isCreatingCall) {
      await Future.delayed(Duration(milliseconds: 500));
      attempts++;

      try {
        ReleaseLogger.log(
          '🔄 [CallScreen] Buscando llamada real... intento $attempts/$maxAttempts',
          tag: 'CallScreen',
        );

        // Buscar llamadas activas del usuario actual en los últimos 30 segundos
        final recentCalls = await CallsOrchestrator().getRecentCalls(
          currentUserId,
        );

        if (recentCalls.isNotEmpty) {
          // Encontramos una llamada real, usarla
          final realCall = recentCalls.first;

          ReleaseLogger.log(
            '✅ [CallScreen] Llamada real encontrada: ${realCall.id}',
            tag: 'CallScreen',
          );

          if (mounted) {
            ReleaseLogger.log(
              '🔄 [CallScreen] Actualizando estado con llamada real: ${realCall.id}, state: ${realCall.getStateForUser(currentUserId)}',
              tag: 'CallScreen',
            );

            ReleaseLogger.log(
              '🚀 [CallScreen] NAVEGANDO A LLAMADA REAL: ${realCall.id} (reemplazando temporal: ${widget.callId})',
              tag: 'CallScreen',
            );

            // ✅ FIX CRÍTICO: Usar CallStackNavigator para evitar dispose del CallController
            // pushReplacement destruye el CallController singleton que necesita la pantalla real
            CallStackNavigator.showCallScreen(
              context: context,
              callId: realCall.id,
            );
          }
          return;
        }
      } catch (e) {
        ReleaseLogger.error(
          '❌ [CallScreen] Error en polling: $e',
          tag: 'CallScreen',
        );
      }
    }

    // Si llegamos aquí y seguimos creando, mostrar error
    if (mounted && _isCreatingCall) {
      setState(() {
        _isCreatingCall = false;
      });
    }
  }

  /// Determinar el estado actual del usuario en la llamada
  CallState _determineCallState() {
    // ✅ UX FIX: Si estamos creando la llamada, mostrar estado de "connecting"
    if (_isCreatingCall) {
      return CallState.connecting;
    }

    if (_currentCall == null) {
      return CallState.error;
    }

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      return CallState.error;
    }

    return _currentCall!.getStateForUser(currentUserId);
  }

  /// Obtener el ID del otro usuario (para llamadas 1-1)
  String _getOtherUserId() {
    if (_currentCall == null) return '';

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return '';

    // Buscar el primer participante que NO sea el usuario actual
    for (String participantId in _currentCall!.participants.keys) {
      if (participantId != currentUserId) {
        return participantId;
      }
    }
    return '';
  }

  /// Determinar si el usuario actual es quien inició la llamada
  bool _isCurrentUserCaller() {
    if (_currentCall == null) return false;

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    return _currentCall!.createdBy == currentUserId;
  }

  @override
  void dispose() {
    // Limpiar listener de terminación
    _callEndListener?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final state = _determineCallState();

    ReleaseLogger.log(
      '📱 [CallScreen] Routing to state: $state for call ${widget.callId}',
      tag: 'CallScreen',
    );

    ReleaseLogger.log(
      '🔍 [CallScreen] Debug info - isCreating: $_isCreatingCall, currentCall: ${_currentCall?.id}, callEnded: ${_currentCall?.endedAt != null}',
      tag: 'CallScreen',
    );

    switch (state) {
      case CallState.connecting:
        return Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
                SizedBox(height: 24),
                Text(
                  'Conectando...',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                SizedBox(height: 8),
                Text(
                  _otherParticipantName,
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ],
            ),
          ),
        );

      case CallState.incomingVideo:
        return IncomingCallScreen(
          callId: widget.callId,
          callerName: _otherParticipantName,
          callerId: _currentCall!.createdBy,
          callerPhotoUrl: null,
          callType: 'video',
          channelName: _currentCall!.channelName,
          token: _currentCall!.token ?? '',
          uid: 0, // Se generará dinámicamente
          isEmergency: false,
        );

      case CallState.incomingAudio:
        return IncomingCallScreen(
          callId: widget.callId,
          callerName: _otherParticipantName,
          callerId: _currentCall!.createdBy,
          callerPhotoUrl: null,
          callType: 'audio',
          channelName: _currentCall!.channelName,
          token: _currentCall!.token ?? '',
          uid: 0, // Se generará dinámicamente
          isEmergency: false,
        );

      case CallState.activeVideo:
        return VideoCallScreen(
          callId: widget.callId,
          channelName: _currentCall!.channelName,
          token: _currentCall!.token,
          uid: 0, // Se generará dinámicamente
          isCaller: _isCurrentUserCaller(),
          remoteName: _otherParticipantName,
          receiverId: _getOtherUserId(),
          isVideo: true,
        );

      case CallState.activeAudio:
        return AudioCallScreen(
          callId: widget.callId,
          channelName: _currentCall!.channelName,
          token: _currentCall!.token ?? '',
          uid: 0, // Se generará dinámicamente
          remoteName: _otherParticipantName,
          receiverId: _getOtherUserId(),
          isCaller: _isCurrentUserCaller(),
        );

      case CallState.ended:
      case CallState.error:
        return Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, color: Colors.white, size: 64),
                SizedBox(height: 16),
                Text(
                  'Llamada no disponible',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    // ✅ CALL STACK: Notificar cierre al stack navigator
                    CallStackNavigator.onCallScreenClosed(widget.callId);
                    Navigator.of(context).pop();
                  },
                  child: Text('Volver'),
                ),
              ],
            ),
          ),
        );
    }
  }
}
