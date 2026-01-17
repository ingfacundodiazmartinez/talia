import 'package:flutter/material.dart';
import '../../../services/typing_indicator_service.dart';

/// Indicador animado que muestra cuando el otro usuario está escribiendo o grabando
///
/// Características:
/// - Animación suave de fade in/out (250ms)
/// - Espacio reservado para evitar "saltos" (manejado por el padre)
/// - Estilo WhatsApp con spinner circular
/// - Soporte para indicador de grabación de audio
class TypingIndicator extends StatefulWidget {
  final String userName;
  /// Estado de actividad: typing o recording
  final UserActivityState activityState;

  const TypingIndicator({
    super.key,
    required this.userName,
    this.activityState = UserActivityState.typing,
  });

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );

    // Iniciar animación de entrada
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _getActivityText() {
    switch (widget.activityState) {
      case UserActivityState.typing:
        return '${widget.userName} está escribiendo...';
      case UserActivityState.recording:
        return '${widget.userName} está grabando audio...';
      case UserActivityState.none:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isRecording = widget.activityState == UserActivityState.recording;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isRecording)
            Icon(
              Icons.mic,
              size: 16,
              color: Colors.red,
            )
          else
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  colorScheme.primary,
                ),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            _getActivityText(),
            style: TextStyle(
              fontSize: 12,
              color: isRecording ? Colors.red : colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
