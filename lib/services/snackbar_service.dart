import 'package:flutter/material.dart';

/// Servicio centralizado para mostrar snackbars con estilos consistentes
///
/// Proporciona métodos para:
/// - Mensajes de éxito (verde)
/// - Mensajes de error (rojo)
/// - Mensajes informativos (azul)
/// - Mensajes de advertencia (naranja)
class SnackbarService {
  static final SnackbarService _instance = SnackbarService._internal();
  factory SnackbarService() => _instance;
  SnackbarService._internal();

  // Key global para el ScaffoldMessenger
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS PÚBLICOS
  // ═══════════════════════════════════════════════════════════════

  /// Muestra un mensaje de éxito (verde con checkmark)
  void showSuccess(String message, {Duration? duration}) {
    _showSnackbar(
      message: message,
      backgroundColor: Colors.green.shade600,
      icon: Icons.check_circle,
      duration: duration ?? const Duration(seconds: 3),
    );
  }

  /// Muestra un mensaje de error (rojo con icono de error)
  void showError(String message, {Duration? duration}) {
    _showSnackbar(
      message: message,
      backgroundColor: Colors.red.shade600,
      icon: Icons.error,
      duration: duration ?? const Duration(seconds: 4),
    );
  }

  /// Muestra un mensaje informativo (azul con icono de info)
  void showInfo(String message, {Duration? duration}) {
    _showSnackbar(
      message: message,
      backgroundColor: Colors.blue.shade600,
      icon: Icons.info,
      duration: duration ?? const Duration(seconds: 3),
    );
  }

  /// Muestra un mensaje de advertencia (naranja con icono de warning)
  void showWarning(String message, {Duration? duration}) {
    _showSnackbar(
      message: message,
      backgroundColor: Colors.orange.shade600,
      icon: Icons.warning,
      duration: duration ?? const Duration(seconds: 3),
    );
  }

  /// Muestra un snackbar personalizado
  void showCustom({
    required String message,
    required Color backgroundColor,
    IconData? icon,
    Duration? duration,
    SnackBarAction? action,
  }) {
    _showSnackbar(
      message: message,
      backgroundColor: backgroundColor,
      icon: icon,
      duration: duration ?? const Duration(seconds: 3),
      action: action,
    );
  }

  /// Muestra un snackbar de progreso con indicador de carga
  void showLoading(String message) {
    final context = scaffoldMessengerKey.currentContext;
    if (context == null) return;

    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.grey.shade800,
        duration: const Duration(days: 1), // No auto-dismiss
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  /// Oculta el snackbar actual
  void hide() {
    scaffoldMessengerKey.currentState?.hideCurrentSnackBar();
  }

  /// Limpia todos los snackbars en cola
  void clearAll() {
    scaffoldMessengerKey.currentState?.clearSnackBars();
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS PRIVADOS
  // ═══════════════════════════════════════════════════════════════

  void _showSnackbar({
    required String message,
    required Color backgroundColor,
    IconData? icon,
    required Duration duration,
    SnackBarAction? action,
  }) {
    final context = scaffoldMessengerKey.currentContext;
    if (context == null) return;

    // Limpiar snackbar anterior
    scaffoldMessengerKey.currentState?.clearSnackBars();

    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: backgroundColor,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        action: action,
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// EXTENSIÓN GLOBAL PARA FACILITAR USO
// ═══════════════════════════════════════════════════════════════

SnackbarService get snackbar => SnackbarService();
