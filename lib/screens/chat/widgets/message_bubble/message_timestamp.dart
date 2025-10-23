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
    switch (status!) {
      case MessageStatus.sending:
        // Spinner amarillo para mensaje analizando/pendiente
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              Colors.amber,
            ),
          ),
        );

      case MessageStatus.sent:
      case MessageStatus.delivered:
        // Sobre verde cerrado para mensaje enviado/aprobado
        return Icon(
          Icons.mail,
          size: 14,
          color: Colors.green,
        );

      case MessageStatus.seen:
        // Sobre verde abierto para mensaje leído
        return Icon(
          Icons.drafts,
          size: 14,
          color: Colors.green,
        );

      case MessageStatus.error:
        return Icon(
          Icons.error_outline,
          size: 14,
          color: Colors.red,
        );
    }
  }
}
