import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';
import 'message_status_bar.dart';

/// Widget que muestra el timestamp + ícono de estado dentro del bubble.
class MessageTimestamp extends StatelessWidget {
  final String time;
  final bool isMe;
  final MessageStatus? status;
  final ModerationStatus? moderationStatus;
  final bool isFavorite;
  final DateTime? localTimestamp;
  final VoidCallback? onRetry;

  const MessageTimestamp({
    super.key,
    required this.time,
    required this.isMe,
    this.status,
    this.moderationStatus,
    this.isFavorite = false,
    this.localTimestamp,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFavorite) ...[
            Icon(
              Icons.star_rounded,
              size: 12,
              color: isMe ? Colors.amber.shade300 : Colors.amber.shade600,
            ),
            const SizedBox(width: 3),
          ],
          Text(
            time,
            style: TextStyle(
              color: isMe
                  ? Colors.white.withValues(alpha: 0.9)
                  : colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          // Ícono de estado para mensajes propios. El bubble usa gradient
          // sutil más oscuro en esta esquina inferior-derecha, lo que da
          // contraste suficiente al azul "leído" sin necesidad de moverlo
          // afuera del bubble.
          if (isMe && status != null) ...[
            const SizedBox(width: 4),
            MessageStatusBar(
              status: status,
              moderationStatus: moderationStatus,
              localTimestamp: localTimestamp,
              onRetry: onRetry,
              size: 14,
              baseColor: Colors.white.withValues(alpha: 0.9),
            ),
          ],
        ],
      ),
    );
  }
}
