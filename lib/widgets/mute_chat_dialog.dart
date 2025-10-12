import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Dialog para silenciar un chat
class MuteChatDialog extends StatelessWidget {
  final String chatId;
  final String chatName;

  const MuteChatDialog({
    super.key,
    required this.chatId,
    required this.chatName,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String chatId,
    required String chatName,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => MuteChatDialog(
        chatId: chatId,
        chatName: chatName,
      ),
    );
  }

  Future<void> _muteChat(BuildContext context, Duration? duration) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      final mutedUntil = duration != null ? DateTime.now().add(duration) : null;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('muted_chats')
          .doc(chatId)
          .set({
        'chatId': chatId,
        'chatName': chatName,
        'mutedAt': FieldValue.serverTimestamp(),
        'mutedUntil': mutedUntil?.toIso8601String(),
      });

      if (context.mounted) {
        Navigator.of(context).pop(true);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              duration != null
                  ? 'Chat silenciado por ${_formatDuration(duration)}'
                  : 'Chat silenciado indefinidamente',
            ),
            action: SnackBarAction(
              label: 'Deshacer',
              onPressed: () => _unmuteChat(context),
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _unmuteChat(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('muted_chats')
          .doc(chatId)
          .delete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat desmuteado')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours >= 24) {
      return '${duration.inDays} día${duration.inDays > 1 ? 's' : ''}';
    } else if (duration.inHours > 0) {
      return '${duration.inHours} hora${duration.inHours > 1 ? 's' : ''}';
    } else {
      return '${duration.inMinutes} minutos';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Silenciar Notificaciones'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('¿Por cuánto tiempo quieres silenciar "$chatName"?'),
          const SizedBox(height: 16),
          Text(
            'No recibirás notificaciones de este chat, pero aún podrás ver los mensajes.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        // 15 minutos
        TextButton(
          onPressed: () => _muteChat(context, const Duration(minutes: 15)),
          child: const Text('15 min'),
        ),

        // 1 hora
        TextButton(
          onPressed: () => _muteChat(context, const Duration(hours: 1)),
          child: const Text('1 hora'),
        ),

        // 8 horas
        TextButton(
          onPressed: () => _muteChat(context, const Duration(hours: 8)),
          child: const Text('8 horas'),
        ),

        // 1 día
        TextButton(
          onPressed: () => _muteChat(context, const Duration(days: 1)),
          child: const Text('1 día'),
        ),

        // 1 semana
        TextButton(
          onPressed: () => _muteChat(context, const Duration(days: 7)),
          child: const Text('1 semana'),
        ),

        // Indefinido
        TextButton(
          onPressed: () => _muteChat(context, null),
          child: const Text('Siempre'),
        ),

        // Cancelar
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

/// Widget para mostrar si un chat está silenciado
class MutedChatIndicator extends StatelessWidget {
  final String chatId;

  const MutedChatIndicator({
    super.key,
    required this.chatId,
  });

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('muted_chats')
          .doc(chatId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;
        final mutedUntilStr = data['mutedUntil'] as String?;

        String subtitle;
        if (mutedUntilStr != null) {
          final mutedUntil = DateTime.parse(mutedUntilStr);
          final now = DateTime.now();

          if (now.isAfter(mutedUntil)) {
            // Expiró
            return const SizedBox.shrink();
          }

          final remaining = mutedUntil.difference(now);
          subtitle = _formatRemaining(remaining);
        } else {
          subtitle = 'Silenciado';
        }

        return Tooltip(
          message: subtitle,
          child: const Icon(
            Icons.notifications_off,
            size: 16,
            color: Colors.grey,
          ),
        );
      },
    );
  }

  String _formatRemaining(Duration duration) {
    if (duration.inDays > 0) {
      return 'Silenciado por ${duration.inDays}d';
    } else if (duration.inHours > 0) {
      return 'Silenciado por ${duration.inHours}h';
    } else {
      return 'Silenciado por ${duration.inMinutes}m';
    }
  }
}
