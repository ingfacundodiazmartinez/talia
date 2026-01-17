import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../services/reaction_service.dart';
import '../reactions_detail_sheet.dart';

/// Widget que muestra las reacciones a un mensaje
class MessageReactions extends StatelessWidget {
  final Map<String, dynamic> reactions;
  final String chatId;
  final String messageId;
  final bool isGroupChat;

  const MessageReactions({
    super.key,
    required this.reactions,
    required this.chatId,
    required this.messageId,
    this.isGroupChat = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final reactionService = ReactionService();
    final auth = FirebaseAuth.instance;

    // Convertir formato antiguo {userId: emoji} a formato nuevo {emoji: [userId]}
    final Map<String, List<String>> normalizedReactions = {};

    reactions.forEach((key, value) {
      if (value is List) {
        // Formato correcto: {emoji: [userId1, userId2]}
        normalizedReactions[key] = List<String>.from(value);
      } else if (value is String) {
        // Formato antiguo: {userId: emoji}
        final userId = key;
        final emoji = value;

        // Agrupar por emoji
        if (normalizedReactions.containsKey(emoji)) {
          normalizedReactions[emoji]!.add(userId);
        } else {
          normalizedReactions[emoji] = [userId];
        }
      }
    });

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: normalizedReactions.entries.map((entry) {
        final reaction = entry.key;
        final userIds = entry.value;
        final count = userIds.length;
        final hasUserReacted = userIds.contains(auth.currentUser?.uid);

        return GestureDetector(
          // Capturar taps de forma más agresiva
          behavior: HitTestBehavior.opaque,
          // En grupos: tap para ver quién reaccionó, long press para toggle
          // En chats 1:1: tap para toggle
          onTap: () {
            if (isGroupChat) {
              // Mostrar quién reaccionó
              showReactionsDetail(
                context,
                reactions: normalizedReactions.map((k, v) => MapEntry(k, v as dynamic)),
                initialEmoji: reaction,
              );
            } else {
              // Toggle reacción directamente
              reactionService.toggleReaction(
                chatId: chatId,
                messageId: messageId,
                reaction: reaction,
                isGroup: isGroupChat,
              );
            }
          },
          onLongPress: isGroupChat
              ? () => reactionService.toggleReaction(
                    chatId: chatId,
                    messageId: messageId,
                    reaction: reaction,
                    isGroup: isGroupChat,
                  )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(4), // Área táctil más grande
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
              color: hasUserReacted
                  ? colorScheme.primaryContainer.withValues(alpha: 0.7)
                  : (isDarkMode
                      ? colorScheme.surfaceContainerHighest
                      : colorScheme.surfaceContainerHigh),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasUserReacted
                    ? colorScheme.primary.withValues(alpha: 0.5)
                    : colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  reaction,
                  style: const TextStyle(fontSize: 14),
                ),
                if (count > 1) ...[
                  const SizedBox(width: 4),
                  Text(
                    count.toString(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: hasUserReacted
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
