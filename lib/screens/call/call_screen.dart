import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/calls/calls_orchestrator.dart';
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

  @override
  void initState() {
    super.initState();
    _loadCallData();
  }

  /// Cargar datos de la llamada desde Firestore
  Future<void> _loadCallData() async {
    try {
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
        });
      }
    }
  }

  /// Determinar el estado actual del usuario en la llamada
  CallState _determineCallState() {
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

    switch (state) {
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
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Volver'),
                ),
              ],
            ),
          ),
        );
    }
  }
}
