import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import '../../services/video_calls/video_call_orchestrator.dart';
import '../../services/video_calls/services/call_state_service.dart';
import '../video_call_screen.dart';
import '../audio_call_screen.dart';
import '../../utils/release_logger.dart';

/// Pantalla de llamada entrante para foreground
///
/// Muestra interfaz similar a CallKit pero controlada por Flutter
/// Permite al usuario DECIDIR si aceptar o rechazar antes de conectar
class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String callerName;
  final String callerId;
  final String? callerPhotoUrl;
  final String callType; // 'video' o 'audio'
  final String? channelName;
  final String? token;
  final int? uid;
  final bool isEmergency;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerName,
    required this.callerId,
    this.callerPhotoUrl,
    required this.callType,
    this.channelName,
    this.token,
    this.uid,
    this.isEmergency = false,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _slideController;
  bool _isProcessing = false;
  StreamSubscription<CallStateUpdate>? _callStateSubscription;

  @override
  void initState() {
    super.initState();

    // Animaciones para un efecto visual atractivo
    _pulseController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    )..repeat(reverse: true);

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideController.forward();

    // ✅ VIBRACIÓN INICIAL: Simular comportamiento de CallKit
    _startVibration();

    // ✅ CRÍTICO: Escuchar cancelaciones de llamada para auto-cerrar
    _setupCallCancellationListener();
  }

  /// Escuchar eventos de cancelación de llamada
  void _setupCallCancellationListener() {
    try {
      final callStateService = CallStateService();
      _callStateSubscription = callStateService.callStateStream.listen(
        (callStateUpdate) {
          // Solo procesar eventos de esta llamada específica
          if (callStateUpdate.callId == widget.callId) {
            ReleaseLogger.log('📱 [IncomingCallScreen] Evento recibido: ${callStateUpdate.status}', tag: 'IncomingCall');

            // Si el caller canceló la llamada, cerrar la pantalla automáticamente
            if (callStateUpdate.status == 'cancelled_by_caller' ||
                callStateUpdate.status == 'ended' ||
                callStateUpdate.status == 'missed' ||
                callStateUpdate.status == 'declined') {
              ReleaseLogger.log('🚫 [IncomingCallScreen] Llamada cancelada por caller - cerrando pantalla', tag: 'IncomingCall');
              _handleCallCancellation();
            }
          }
        },
        onError: (error) {
          ReleaseLogger.error('❌ [IncomingCallScreen] Error en listener de cancelación: $error', tag: 'IncomingCall');
        },
      );
      ReleaseLogger.log('✅ [IncomingCallScreen] Listener de cancelación configurado para callId: ${widget.callId}', tag: 'IncomingCall');
    } catch (e) {
      ReleaseLogger.error('❌ [IncomingCallScreen] Error configurando listener de cancelación: $e', tag: 'IncomingCall');
    }
  }

  /// Manejar cancelación de llamada por parte del caller
  void _handleCallCancellation() {
    if (!mounted || _isProcessing) return;

    setState(() => _isProcessing = true);
    _stopVibration();

    // Cerrar la pantalla inmediatamente
    Navigator.of(context).pop();
    ReleaseLogger.log('✅ [IncomingCallScreen] Pantalla cerrada por cancelación del caller', tag: 'IncomingCall');
  }

  @override
  void dispose() {
    _callStateSubscription?.cancel();
    _pulseController.dispose();
    _slideController.dispose();
    _stopVibration();
    super.dispose();
  }

  /// Iniciar patrón de vibración para llamada entrante
  void _startVibration() async {
    if (await Vibration.hasVibrator() ?? false) {
      // Patrón: vibrar 500ms, pausa 1000ms, repetir
      Vibration.vibrate(duration: 500);

      // Repetir vibración cada 1.5 segundos
      Future.doWhile(() async {
        if (!mounted || _isProcessing) return false;

        await Future.delayed(Duration(milliseconds: 1500));
        if (!mounted || _isProcessing) return false;

        Vibration.vibrate(duration: 500);
        return true;
      });
    }
  }

  /// Detener vibración
  void _stopVibration() {
    Vibration.cancel();
  }

  /// Aceptar la llamada
  Future<void> _acceptCall() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    _stopVibration();

    try {
      // Aceptar llamada en Firestore
      await VideoCallOrchestrator().acceptCall(widget.callId);

      if (!mounted) return;

      // Navegar a la pantalla de videollamada
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => widget.callType == 'audio'
              ? AudioCallScreen(
                  callId: widget.callId,
                  channelName: widget.channelName,
                  token: widget.token,
                  uid: widget.uid,
                  isCaller: false,
                  remoteName: widget.callerName,
                )
              : VideoCallScreen(
                  callId: widget.callId,
                  channelName: widget.channelName,
                  token: widget.token,
                  uid: widget.uid,
                  isCaller: false,
                  remoteName: widget.callerName,
                  receiverId: widget.callerId,
                  isVideo: widget.callType == 'video',
                ),
        ),
      );

    } catch (e) {
      ReleaseLogger.error('❌ Error aceptando llamada: $e', tag: 'IncomingCall');
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  /// Rechazar la llamada
  Future<void> _rejectCall() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    _stopVibration();

    try {
      // Rechazar llamada en Firestore
      await VideoCallOrchestrator().rejectCall(widget.callId);

      if (!mounted) return;

      // Cerrar pantalla
      Navigator.of(context).pop();

    } catch (e) {
      ReleaseLogger.error('❌ Error rechazando llamada: $e', tag: 'IncomingCall');
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: _slideController,
            curve: Curves.easeOutCubic,
          )),
          child: Column(
            children: [
              // Header con info de emergencia si aplica
              if (widget.isEmergency) _buildEmergencyHeader(),

              // Área principal con avatar y nombre
              Expanded(
                child: _buildMainContent(),
              ),

              // Botones de acción
              _buildActionButtons(),
            ],
          ),
        ),
      ),
    );
  }

  /// Header para llamadas de emergencia
  Widget _buildEmergencyHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.9),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.emergency,
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(height: 8),
          const Text(
            'LLAMADA DE EMERGENCIA',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Contenido principal: avatar, nombre, estado
  Widget _buildMainContent() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Avatar con animación de pulso
        ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1.1).animate(
            CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
          ),
          child: Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.3),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: ClipOval(
              child: widget.callerPhotoUrl != null
                  ? Image.network(
                      widget.callerPhotoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => _buildDefaultAvatar(),
                    )
                  : _buildDefaultAvatar(),
            ),
          ),
        ),

        const SizedBox(height: 32),

        // Nombre del caller
        Text(
          widget.callerName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w300,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 16),

        // Tipo de llamada
        Text(
          widget.callType == 'audio' ? 'Llamada de voz' : 'Videollamada',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 18,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 8),

        // Estado
        if (!_isProcessing)
          Text(
            'Llamada entrante...',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 16,
            ),
            textAlign: TextAlign.center,
          )
        else
          const CircularProgressIndicator(
            color: Colors.white,
          ),
      ],
    );
  }

  /// Avatar por defecto
  Widget _buildDefaultAvatar() {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Colors.blue, Colors.purple],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          widget.callerName.isNotEmpty ? widget.callerName[0].toUpperCase() : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 48,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  /// Botones de aceptar y rechazar
  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Botón rechazar
          _buildActionButton(
            onPressed: _isProcessing ? null : _rejectCall,
            icon: Icons.call_end,
            color: Colors.red,
            label: 'Rechazar',
          ),

          const SizedBox(width: 60),

          // Botón aceptar
          _buildActionButton(
            onPressed: _isProcessing ? null : _acceptCall,
            icon: widget.callType == 'audio' ? Icons.call : Icons.videocam,
            color: Colors.green,
            label: 'Aceptar',
          ),
        ],
      ),
    );
  }

  /// Botón de acción individual
  Widget _buildActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onPressed != null ? color : Colors.grey,
            boxShadow: [
              BoxShadow(
                color: (onPressed != null ? color : Colors.grey).withValues(alpha: 0.5),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(40),
              child: Center(
                child: Icon(
                  icon,
                  color: Colors.white,
                  size: 36,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: TextStyle(
            color: onPressed != null ? Colors.white : Colors.grey,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}