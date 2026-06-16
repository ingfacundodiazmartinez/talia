import 'package:flutter/material.dart';

/// Envoltorio que da una entrada SUTIL a una burbuja de mensaje:
/// fade + un leve slide hacia arriba + un micro-scale. Pensado para que la
/// aparición de la burbuja no sea brusca, sin ser intrusiva.
///
/// Clave del diseño: la animación corre SOLO para mensajes "frescos" (creados
/// hace menos de [freshWindow]). Así, al abrir un chat, los 50 mensajes del
/// historial aparecen sin animar (no hay cascada molesta) y solo las burbujas
/// que llegan/se envían en vivo entran con la animación.
///
/// Como la lista usa keys estables por mensaje (ValueKey), cada burbuja monta
/// su State una sola vez → la animación de entrada no se repite al hacer
/// scroll ni en los rebuilds del controller.
class AnimatedMessageEntry extends StatefulWidget {
  final Widget child;

  /// Tiempo efectivo del mensaje (timestamp del servidor o local del optimista).
  final DateTime messageTime;

  /// Ventana de "frescura": si el mensaje es más viejo que esto al montarse,
  /// aparece sin animar.
  final Duration freshWindow;

  const AnimatedMessageEntry({
    super.key,
    required this.child,
    required this.messageTime,
    this.freshWindow = const Duration(seconds: 10),
  });

  @override
  State<AnimatedMessageEntry> createState() => _AnimatedMessageEntryState();
}

class _AnimatedMessageEntryState extends State<AnimatedMessageEntry>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;

  bool get _isFresh =>
      DateTime.now().difference(widget.messageTime).abs() < widget.freshWindow;

  @override
  void initState() {
    super.initState();

    // Mensaje viejo (historial): sin animación, child directo. No creamos
    // controller para no gastar recursos en cada burbuja de la lista.
    if (!_isFresh) return;

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _controller = controller;

    final curve = CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(curve);
    // Slide sutil: ~10px desde abajo (offset relativo a la altura del hijo).
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(curve);
    _scale = Tween<double>(begin: 0.97, end: 1.0).animate(curve);

    controller.forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      // No-fresh: render directo, sin overhead.
      return widget.child;
    }
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: _scale,
          alignment: Alignment.bottomCenter,
          child: widget.child,
        ),
      ),
    );
  }
}
