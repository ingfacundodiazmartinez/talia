import 'package:flutter/material.dart';

/// Widget que muestra el timestamp de un mensaje
class MessageTimestamp extends StatelessWidget {
  final String time;
  final bool isMe;

  const MessageTimestamp({
    super.key,
    required this.time,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        time,
        style: TextStyle(
          color: isMe
              ? Colors.white.withValues(alpha: 0.9)
              : colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }
}
