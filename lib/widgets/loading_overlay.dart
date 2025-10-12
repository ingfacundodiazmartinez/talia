import 'package:flutter/material.dart';

/// Overlay de carga que cubre toda la pantalla
///
/// Uso típico:
/// ```dart
/// LoadingOverlay.show(context, message: 'Cargando...');
/// // Hacer operación
/// LoadingOverlay.hide(context);
/// ```
class LoadingOverlay {
  static OverlayEntry? _currentOverlay;

  /// Muestra el overlay de carga
  static void show(
    BuildContext context, {
    String? message,
    bool dismissible = false,
  }) {
    // Ocultar overlay anterior si existe
    hide(context);

    final overlay = Overlay.of(context);

    _currentOverlay = OverlayEntry(
      builder: (context) => _LoadingOverlayWidget(
        message: message,
        dismissible: dismissible,
        onDismiss: () => hide(context),
      ),
    );

    overlay.insert(_currentOverlay!);
  }

  /// Oculta el overlay de carga
  static void hide(BuildContext context) {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }

  /// Verifica si el overlay está visible
  static bool get isVisible => _currentOverlay != null;
}

class _LoadingOverlayWidget extends StatelessWidget {
  final String? message;
  final bool dismissible;
  final VoidCallback onDismiss;

  const _LoadingOverlayWidget({
    this.message,
    required this.dismissible,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: GestureDetector(
        onTap: dismissible ? onDismiss : null,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                if (message != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    message!,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (dismissible) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Toca para cancelar',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Widget alternativo: Overlay de carga inline (para usar dentro de un widget)
class InlineLoadingOverlay extends StatelessWidget {
  final bool isLoading;
  final Widget child;
  final String? message;

  const InlineLoadingOverlay({
    super.key,
    required this.isLoading,
    required this.child,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLoading)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (message != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          message!,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
