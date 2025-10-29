import 'package:flutter/material.dart';

/// Widget de estado vacío para lista de chats
class ChatEmptyStateWidget extends StatelessWidget {
  final String message;
  final IconData icon;

  const ChatEmptyStateWidget({
    super.key,
    this.message = 'No tienes conversaciones aún',
    this.icon = Icons.chat_bubble_outline,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 64,
            color: colorScheme.outlineVariant,
          ),
          SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
