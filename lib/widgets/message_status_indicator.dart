import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// Widget que muestra el estado de un mensaje con un icono
///
/// Estados de mensaje:
/// - sending: Spinner animado
/// - sent: Sobre cerrado (enviado al servidor)
/// - delivered: Sobre con marca (recibido en dispositivo)
/// - seen: Sobre abierto (visto/leído)
/// - error: Icono de error
///
/// Colores por moderación:
/// - approved: Verde
/// - blocked: Rojo
/// - pending: Amarillo
/// - null: Color por defecto (gris)
class MessageStatusIndicator extends StatelessWidget {
  final MessageStatus status;
  final ModerationStatus? moderationStatus;
  final double size;

  const MessageStatusIndicator({
    super.key,
    required this.status,
    this.moderationStatus,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    // Determinar color basado en moderación
    final color = _getColorByModeration(context);

    // Determinar icono basado en estado
    return _getIconByStatus(color);
  }

  /// Obtiene el color basado en el estado de moderación
  Color _getColorByModeration(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Si hay moderación, usar colores específicos según el tema
    if (moderationStatus != null) {
      switch (moderationStatus!) {
        case ModerationStatus.approved:
          // Verde más oscuro en modo claro, verde normal en modo oscuro
          return isDarkMode ? Colors.green : Colors.green.shade700;
        case ModerationStatus.blocked:
          // Rojo más oscuro en modo claro, rojo normal en modo oscuro
          return isDarkMode ? Colors.red : Colors.red.shade700;
        case ModerationStatus.pending:
          // Amarillo más oscuro en modo claro, amarillo normal en modo oscuro
          return isDarkMode ? Colors.amber : Colors.amber.shade800;
      }
    }

    // Color por defecto (sin moderación)
    // Más oscuro en modo claro, más claro en modo oscuro
    return isDarkMode
        ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.8);
  }

  /// Obtiene el icono basado en el estado del mensaje
  Widget _getIconByStatus(Color color) {
    switch (status) {
      case MessageStatus.sending:
        // Spinner animado
        return SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        );

      case MessageStatus.sent:
        // Sobre cerrado
        return Icon(
          Icons.mail_outline,
          size: size,
          color: color,
        );

      case MessageStatus.delivered:
        // Sobre con marca (recibido)
        return Icon(
          Icons.markunread,
          size: size,
          color: color,
        );

      case MessageStatus.seen:
        // Sobre abierto
        return Icon(
          Icons.drafts_outlined,
          size: size,
          color: color,
        );

      case MessageStatus.error:
        // Icono de error
        return Icon(
          Icons.error_outline,
          size: size,
          color: Colors.red,
        );
    }
  }
}
