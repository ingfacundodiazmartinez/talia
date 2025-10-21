import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// Widget que muestra el estado de un mensaje (enviando/enviado/error)
///
/// Estados:
/// - sending: ⏱️ Reloj gris (enviando)
/// - sent: ✓ Check gris (enviado)
/// - error: ⚠️ Ícono de advertencia rojo
class MessageStatusIcon extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;

  const MessageStatusIcon({
    super.key,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    switch (message.status) {
      case MessageStatus.sending:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
          ),
        );

      case MessageStatus.sent:
        return const Icon(
          Icons.check,
          size: 16,
          color: Colors.grey,
        );

      case MessageStatus.delivered:
        return const Icon(
          Icons.done_all,
          size: 16,
          color: Colors.grey,
        );

      case MessageStatus.seen:
        return const Icon(
          Icons.done_all,
          size: 16,
          color: Colors.blue,
        );

      case MessageStatus.error:
        return GestureDetector(
          onTap: onRetry,
          child: const Icon(
            Icons.error_outline,
            size: 16,
            color: Colors.red,
          ),
        );
    }
  }
}
