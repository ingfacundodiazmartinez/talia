import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// Widget que muestra el estado de un mensaje con íconos estilo WhatsApp.
///
/// Estados de mensaje:
/// - sending: Spinner animado
/// - sent: 1 tilde (enviado al servidor)
/// - delivered: 2 tildes (entregado al dispositivo del receptor)
/// - seen: 2 tildes en azul WhatsApp (leído)
/// - error: Icono de error en rojo
///
/// Colores por moderación:
/// - approved: NO se sobrescribe el color del estado (es el caso normal y
///   queremos preservar el lenguaje WhatsApp: azul = leído, blanco/gris =
///   enviado/entregado). El verde anterior chocaba con el bubble violeta y
///   se perdía la información de "leído".
/// - blocked: Rojo (problema real, requiere atención)
/// - pending: Amarillo (problema temporal, requiere atención)
/// - null: gris por defecto (sent/delivered) | azul WhatsApp (seen)
class MessageStatusIndicator extends StatelessWidget {
  /// Azul "leído" estilo WhatsApp. Se usa cuando el mensaje fue visto.
  static const Color readBlue = Color(0xFF53BDEB);

  final MessageStatus status;
  final ModerationStatus? moderationStatus;
  final double size;
  /// Color base para sent/delivered. Si null, usa el del tema.
  /// Útil cuando el widget se renderiza sobre el bubble del propio mensaje
  /// (fondo violeta) y queremos blanco con opacidad.
  final Color? baseColor;

  const MessageStatusIndicator({
    super.key,
    required this.status,
    this.moderationStatus,
    this.size = 14,
    this.baseColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = _resolveColor(context);
    return _buildIcon(color);
  }

  /// Resuelve el color del ícono. Prioridad:
  ///   1. Moderación `blocked` → rojo (gana sobre todo, problema real)
  ///   2. Moderación `pending` → amarillo (problema temporal)
  ///   3. Estado `seen` → azul WhatsApp
  ///   4. `baseColor` si fue provisto
  ///   5. Color por defecto del tema
  ///
  /// Notar que `approved` NO se considera: es el estado normal y queremos
  /// preservar las tildes blancas/azules de WhatsApp.
  Color _resolveColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Moderación: solo problemas reales sobreescriben el color.
    if (moderationStatus == ModerationStatus.blocked) {
      return isDarkMode ? Colors.red : Colors.red.shade700;
    }
    if (moderationStatus == ModerationStatus.pending) {
      return isDarkMode ? Colors.amber : Colors.amber.shade800;
    }

    // "Leído" siempre azul WhatsApp (incluso si moderation == approved).
    if (status == MessageStatus.seen) {
      return readBlue;
    }

    if (baseColor != null) return baseColor!;

    return isDarkMode
        ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.8);
  }

  Widget _buildIcon(Color color) {
    switch (status) {
      case MessageStatus.sending:
        return SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        );

      case MessageStatus.sent:
        return Icon(Icons.check, size: size, color: color);

      case MessageStatus.delivered:
      case MessageStatus.seen:
        return Icon(Icons.done_all, size: size, color: color);

      case MessageStatus.error:
        return Icon(Icons.error_outline, size: size, color: Colors.red);
    }
  }
}
