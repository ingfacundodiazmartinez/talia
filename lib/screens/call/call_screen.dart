import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../controllers/call_controller.dart';
import '../../models/call.dart';
import '../../utils/release_logger.dart';
import '../../services/calls/call_listener_service.dart';
// ✅ IMPORTAR WIDGETS EXISTENTES COMO COMPONENTES
import 'video/video_call_screen.dart';
import 'audio/audio_call_screen.dart';
import 'common/incoming_call_screen.dart';

/// PANTALLA UNIFICADA DE LLAMADAS
///
/// ✅ NUEVO ENFOQUE SIMPLIFICADO:
/// - Una sola pantalla que maneja TODOS los estados de llamada internamente
/// - Renderiza la UI correcta según el estado (incoming, active video, active audio)
/// - Un solo dispose() y cleanup cuando termina
/// - Navegación mucho más simple en CallStackNavigator
///
/// Estados que maneja:
/// - connecting: Creando/conectando llamada
/// - incomingVideo/incomingAudio: Llamada entrante (mostrar botones aceptar/rechazar)
/// - activeVideo: Videollamada activa (mostrar video + controles)
/// - activeAudio: Llamada de audio activa (mostrar audio UI + controles)
/// - ended: Llamada terminada (cerrar automáticamente)
/// - error: Error (mostrar error + botón salir)
class CallScreen extends StatefulWidget {
  final String callId;

  const CallScreen({super.key, required this.callId});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  // ✅ ESTADO MÍNIMO - Solo lo necesario para routing
  Call? _currentCall;
  bool _isLoading = true;
  String _otherParticipantName = 'Usuario';
  bool _isCreatingCall = false;
  String _errorMessage = '';
  bool _isClosing = false; // Flag para evitar renders después de cerrar

  // ✅ LISTENER AUTOMÁTICO DE ESTADO
  StreamSubscription? _callStateListener;

  @override
  void initState() {
    super.initState();

    // ✅ CONFIGURACIÓN MÍNIMA - Solo cargar datos y configurar listener automático
    _loadCallData();
    _setupAutomaticStateListener();
  }

  /// ✅ LISTENER UNIFICADO: CallScreen usa CallListenerService directamente
  /// Elimina redundancia con CallController.watchCall()
  void _setupAutomaticStateListener() {
    // ✅ UNIFICADO: Usar CallListenerService en lugar de CallController.watchCall()
    _callStateListener = CallListenerService().getCallStream(widget.callId).listen(
      (call) {
        if (!mounted || _isClosing) return;

        // ✅ CRITICAL: Cerrar automáticamente si la llamada terminó
        if (call?.endedAt != null) {
          ReleaseLogger.log(
            '🔚 [CallScreen] Llamada terminada - cerrando CallScreen automáticamente',
            tag: 'CallScreen',
          );

          _isClosing = true;

          // Cerrar después de un frame para evitar problemas de setState durante build
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).pop();
            }
          });
          return;
        }

        // ✅ SIMPLIFIED: Solo actualizar UI si la llamada sigue activa
        ReleaseLogger.log(
          '📱 [CallScreen] UNIFICADO - Actualizando UI via CallListenerService para ${widget.callId}',
          tag: 'CallScreen',
        );

        setState(() {
          _currentCall = call;
        });
      },
      onError: (error) {
        ReleaseLogger.error(
          '❌ [CallScreen] Error en listener unificado: $error',
          tag: 'CallScreen',
        );
        if (mounted && !_isClosing) {
          setState(() {
            _errorMessage = 'Error monitoreando llamada: $error';
          });
        }
      },
    );
  }


  /// ✅ SIMPLIFICADO: Solo cargar datos de la llamada para routing
  Future<void> _loadCallData() async {
    try {
      // ✅ UX FIX: Detectar si es una llamada temporal (en proceso de creación)
      if (widget.callId.startsWith('temp_')) {
        if (!_isClosing) {
          setState(() {
            _isCreatingCall = true;
            _isLoading = false;
          });

          // Iniciar polling para esperar que la llamada real se cree
          _pollForRealCall();
        }
        return;
      }

      final call = await CallController.getCall(widget.callId);

      // Si tenemos la call, obtener el nombre del otro participante
      String participantName = 'Usuario';
      if (call != null) {
        participantName = await CallController.getOtherParticipantName(call);
      }

      if (mounted && !_isClosing) {
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
      if (mounted && !_isClosing) {
        setState(() {
          _isLoading = false;
          _isCreatingCall = false;
          _errorMessage = 'Error cargando llamada: $e';
        });
      }
    }
  }

  /// ✅ FIX: Usar listener en lugar de polling (elimina 30 queries innecesarias)
  void _pollForRealCall() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    ReleaseLogger.log(
      '🔄 [CallScreen] Esperando creación de llamada real con listener...',
      tag: 'CallScreen',
    );

    // ✅ FIX: Listener directo en lugar de polling
    // Busca llamadas creadas en los últimos 10 segundos por el usuario actual
    final cutoffTime = DateTime.now().subtract(Duration(seconds: 10));

    final callListener = FirebaseFirestore.instance
      .collection('calls')
      .where('createdBy', isEqualTo: currentUserId)
      .where('createdAt', isGreaterThan: Timestamp.fromDate(cutoffTime))
      .limit(1)
      .snapshots()
      .listen(
        (snapshot) {
          if (!mounted || _isClosing || !_isCreatingCall) return;

          if (snapshot.docs.isNotEmpty) {
            final doc = snapshot.docs.first;
            final realCall = Call.fromFirestore(doc.id, doc.data());

            ReleaseLogger.log(
              '✅ [CallScreen] Llamada real encontrada via listener: ${realCall.id}',
              tag: 'CallScreen',
            );

            ReleaseLogger.log(
              '🚀 [CallScreen] NAVEGANDO A LLAMADA REAL: ${realCall.id} (reemplazando temporal: ${widget.callId})',
              tag: 'CallScreen',
            );

            // Navegar a la llamada real
            CallController.navigateToRealCall(
              context: context,
              callId: realCall.id,
              replaceTemporary: true,
            );
          }
        },
        onError: (error) {
          ReleaseLogger.error(
            '❌ [CallScreen] Error en listener de llamada real: $error',
            tag: 'CallScreen',
          );
        },
      );

    // ✅ Timeout de seguridad (15 segundos)
    Future.delayed(Duration(seconds: 15), () {
      callListener.cancel();

      if (mounted && _isCreatingCall && !_isClosing) {
        ReleaseLogger.error(
          '⏱️ [CallScreen] Timeout esperando llamada real',
          tag: 'CallScreen',
        );
        setState(() {
          _isCreatingCall = false;
          _errorMessage = 'Error: Timeout creando llamada';
        });
      }
    });
  }

  /// ✅ MÉTODOS AUXILIARES SIMPLIFICADOS

  /// Determinar el estado actual del usuario en la llamada
  CallState _determineCallState([Call? call]) {
    call = call ?? _currentCall;

    // ✅ UX FIX: Si estamos creando la llamada, mostrar estado de "connecting"
    if (_isCreatingCall) {
      return CallState.connecting;
    }

    if (call == null) {
      return CallState.error;
    }

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      return CallState.error;
    }

    // ✅ UX FIX: Si CallKit aceptó la llamada, mostrar pantalla activa inmediatamente
    // No esperar a que Firebase actualice el status de 'waiting' → 'joined'
    // Esto elimina el delay de 7+ segundos después de aceptar desde CallKit
    if (CallController.isCallKitHandled(widget.callId)) {
      final isReceiver = call.createdBy != currentUserId;
      final myStatus = call.participants[currentUserId]?.status;

      if (isReceiver && myStatus == 'waiting') {
        // CallKit aceptó pero Firebase no actualizó → tratar como activo
        ReleaseLogger.log(
          '🚀 [CallScreen] CallKit activo + status waiting → forzando estado activo para UX inmediata',
          tag: 'CallScreen',
        );
        return call.type == 'video' ? CallState.activeVideo : CallState.activeAudio;
      }
    }

    return call.getStateForUser(currentUserId);
  }

  /// Obtener el ID del otro usuario (para llamadas 1-1)
  String _getOtherUserId([Call? call]) {
    call = call ?? _currentCall;
    if (call == null) return '';

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return '';

    // Buscar el primer participante que NO sea el usuario actual
    for (String participantId in call.participants.keys) {
      if (participantId != currentUserId) {
        return participantId;
      }
    }
    return '';
  }

  /// Determinar si el usuario actual es quien inició la llamada
  bool _isCurrentUserCaller([Call? call]) {
    call = call ?? _currentCall;
    if (call == null) return false;

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    return call.createdBy == currentUserId;
  }


  @override
  void dispose() {
    ReleaseLogger.log(
      '🧹 [CallScreen] dispose() - cleaning up unified call screen router: ${widget.callId}',
      tag: 'CallScreen',
    );

    // ✅ CLEANUP UNIFICADO - Cancelar listener y limpiar stream de CallListenerService
    _callStateListener?.cancel();

    // ✅ UNIFICADO: Cerrar stream individual en CallListenerService
    CallListenerService().closeCallStream(widget.callId);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ✅ FIXED: Si ya estamos cerrando, no renderizar nada más
    if (_isClosing) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final state = _determineCallState();

    ReleaseLogger.log(
      '📱 [CallScreen] UNIFIED - Rendering state: $state for call ${widget.callId}',
      tag: 'CallScreen',
    );

    // ✅ RENDER PARCIAL - Usar widgets existentes como componentes
    switch (state) {
      case CallState.connecting:
        return _buildConnectingView();

      case CallState.incomingVideo:
        // ✅ RENDER PARCIAL: Usar IncomingCallScreen existente
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
        // ✅ RENDER PARCIAL: Usar IncomingCallScreen existente
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
        // ✅ RENDER PARCIAL: Usar VideoCallScreen existente
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
        // ✅ RENDER PARCIAL: Usar AudioCallScreen existente
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
        // ✅ FIXED: No renderizar nada - dejar que Navigator.pop() del listener cierre inmediatamente
        // Fallback: mostrar loading mientras se completa el cierre
        return _buildConnectingView();

      case CallState.error:
        return _buildErrorView();
    }
  }

  /// ✅ VISTAS MÍNIMAS - Solo las que no tenemos como componentes

  /// Vista de conectando/creando llamada
  Widget _buildConnectingView() {
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
  }


  /// Vista de error
  Widget _buildErrorView() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.white, size: 64),
            SizedBox(height: 16),
            Text(
              'Error en la llamada',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            if (_errorMessage.isNotEmpty) ...[
              SizedBox(height: 8),
              Text(
                _errorMessage,
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
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
