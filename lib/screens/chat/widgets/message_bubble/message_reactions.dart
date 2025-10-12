import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../services/reaction_service.dart';

/// Widget que muestra las reacciones a un mensaje
class MessageReactions extends StatelessWidget {
  final Map<String, dynamic> reactions;
  final String chatId;
  final String messageId;

  const MessageReactions({
    super.key,
    required this.reactions,
    required this.chatId,
    required this.messageId,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final reactionService = ReactionService();
    final auth = FirebaseAuth.instance;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        children: reactions.entries.map((entry) {
          final reaction = entry.key;
          final users = entry.value as List;
          final count = users.length;
          final hasReacted = users.contains(auth.currentUser?.uid);

          return GestureDetector(
            onTap: () => reactionService.toggleReaction(
              chatId: chatId,
              messageId: messageId,
              reaction: reaction,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: hasReacted
                    ? colorScheme.primary.withValues(alpha: 0.2)
                    : (isDarkMode
                        ? colorScheme.surfaceContainerHighest
                        : Colors.grey.withValues(alpha: 0.2)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      hasReacted ? colorScheme.primary : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(reaction, style: const TextStyle(fontSize: 16)),
                  if (count > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      count.toString(),
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
