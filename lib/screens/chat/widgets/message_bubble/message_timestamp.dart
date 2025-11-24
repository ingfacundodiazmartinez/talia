import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';

/// Widget que muestra el timestamp de un mensaje con iconos de estado
class MessageTimestamp extends StatelessWidget {
  final String time;
  final bool isMe;
  final MessageStatus? status;

  const MessageTimestamp({
    super.key,
    required this.time,
    required this.isMe,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            time,
            style: TextStyle(
              color: isMe
                  ? Colors.white.withValues(alpha: 0.9)
                  : colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          // Mostrar iconos de estado solo para mensajes propios
          if (isMe && status != null) ...[
            const SizedBox(width: 4),
            _buildStatusIcon(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusIcon() {
    // Para mensajes propios, usar blanco con diferentes opacidades
    // Esto contrasta bien con el fondo de la burbuja (primary color)
    final iconColor = isMe
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.grey.shade600;

    switch (status!) {
      case MessageStatus.sending:
        // Spinner para mensaje enviando
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              isMe ? Colors.white.withValues(alpha: 0.7) : Colors.grey,
            ),
          ),
        );

      case MessageStatus.sent:
      case MessageStatus.delivered:
        // Sobre cerrado - enviado pero no leído
        return Icon(
          Icons.mail_outline,
          size: 14,
          color: iconColor,
        );

      case MessageStatus.seen:
        // Sobre abierto - mensaje leído
        return Icon(
          Icons.drafts,
          size: 14,
          color: iconColor,
        );

      case MessageStatus.error:
        return Icon(
          Icons.error_outline,
          size: 14,
          color: isMe ? Colors.white.withValues(alpha: 0.9) : Colors.red,
        );
    }
  }
}
