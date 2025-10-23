import 'package:flutter/material.dart';

/// Indicador animado que muestra cuando el otro usuario está escribiendo
///
/// Características:
/// - Animación suave de fade in/out (250ms)
/// - Espacio reservado para evitar "saltos" (manejado por el padre)
/// - Estilo WhatsApp con spinner circular
class TypingIndicator extends StatefulWidget {
  final String userName;

  const TypingIndicator({
    super.key,
    required this.userName,
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
            '${widget.userName} está escribiendo...',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
