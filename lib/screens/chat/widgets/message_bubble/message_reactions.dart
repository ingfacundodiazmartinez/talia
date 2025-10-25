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

    print('🔄 Reacciones normalizadas: $normalizedReactions');

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: normalizedReactions.entries.map((entry) {
        final reaction = entry.key;

        return GestureDetector(
          onTap: () => reactionService.toggleReaction(
            chatId: chatId,
            messageId: messageId,
            reaction: reaction,
          ),
          child: Text(reaction, style: const TextStyle(fontSize: 16)),
        );
      }).toList(),
    );
  }
}
