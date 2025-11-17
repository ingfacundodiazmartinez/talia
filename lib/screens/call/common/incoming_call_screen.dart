import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import '../../../controllers/call_controller.dart';
import '../../../utils/release_logger.dart';

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
  // ✅ PURE WIDGET: Sin listeners - CallScreen maneja el estado

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

    // ✅ PURE WIDGET: CallScreen manejará la detectación de cancelación automáticamente
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _slideController.dispose();
    _stopVibration();
    // ✅ PURE WIDGET: No hay listeners que cancelar
    super.dispose();
  }

  /// Iniciar patrón de vibración para llamada entrante
  void _startVibration() async {
    if (await Vibration.hasVibrator()) {
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
      // ✅ ARQUITECTURA CORRECTA: Screen → Controller
      final success = await CallController.acceptCallStatic(widget.callId);
      if (!success) {
        if (mounted) {
          setState(() => _isProcessing = false);
        }
        return;
      }

      if (!mounted) return;

      // El orchestrator detectará el cambio de estado automáticamente
      // y navegará a la pantalla correcta
      ReleaseLogger.log(
        '✅ [IncomingCallScreen] Llamada aceptada - orchestrator manejará navegación',
        tag: 'IncomingCall',
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
      // ✅ ARQUITECTURA CORRECTA: Screen → Controller
      if (!mounted) return;

      // ✅ CALL STACK: Notificar cierre al stack navigator (maneja navegación automáticamente)
      // CallStackNavigator eliminado - cierre automático por CallScreen.onCallScreenClosed(widget.callId);
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error rechazando llamada: $e',
        tag: 'IncomingCall',
      );

      // ✅ CALL STACK: Notificar cierre incluso en caso de error (maneja navegación automáticamente)
      // CallStackNavigator eliminado - cierre automático por CallScreen.onCallScreenClosed(widget.callId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(
                CurvedAnimation(
                  parent: _slideController,
                  curve: Curves.easeOutCubic,
                ),
              ),
          child: Column(
            children: [
              // Header con info de emergencia si aplica
              if (widget.isEmergency) _buildEmergencyHeader(),

              // Área principal con avatar y nombre
              Expanded(child: _buildMainContent()),

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
          const Icon(Icons.emergency, color: Colors.white, size: 32),
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
                      errorBuilder: (context, error, stackTrace) =>
                          _buildDefaultAvatar(),
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
          const CircularProgressIndicator(color: Colors.white),
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
          widget.callerName.isNotEmpty
              ? widget.callerName[0].toUpperCase()
              : '?',
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
                color: (onPressed != null ? color : Colors.grey).withValues(
                  alpha: 0.5,
                ),
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
              child: Center(child: Icon(icon, color: Colors.white, size: 36)),
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
