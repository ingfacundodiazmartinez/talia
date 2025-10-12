import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Widget que muestra el contenido de un mensaje bloqueado por moderación
class BlockedMessageContent extends StatefulWidget {
  final bool isMe;

  const BlockedMessageContent({
    super.key,
    required this.isMe,
  });

  @override
  State<BlockedMessageContent> createState() => _BlockedMessageContentState();
}

class _BlockedMessageContentState extends State<BlockedMessageContent> {
  bool _isParent = true; // Por defecto asumir parent para mensaje neutral

  @override
  void initState() {
    super.initState();
    _loadUserRole();
  }

  Future<void> _loadUserRole() async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUserId)
            .get();

        if (mounted && userDoc.exists) {
          final userData = userDoc.data();
          setState(() {
            _isParent = userData?['isParent'] ?? true;
          });
        }
      }
    } catch (e) {
      print('❌ Error cargando rol de usuario para mensaje bloqueado: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Mensaje según el rol
    final infoMessage = _isParent
        ? 'Este mensaje no cumple con las normas de seguridad de la moderación con IA.'
        : 'Este mensaje no cumple con las normas de seguridad establecidas por tus padres.';

    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.block,
                color: widget.isMe
                    ? Colors.white.withValues(alpha: 0.9)
                    : colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mensaje bloqueado',
                  style: TextStyle(
                    color: widget.isMe
                        ? Colors.white
                        : colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Este mensaje fue bloqueado por contener contenido inapropiado.',
            style: TextStyle(
              color: widget.isMe
                  ? Colors.white.withValues(alpha: 0.8)
                  : colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: widget.isMe
                  ? Colors.white.withValues(alpha: 0.1)
                  : colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: widget.isMe
                      ? Colors.white.withValues(alpha: 0.7)
                      : colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    infoMessage,
                    style: TextStyle(
                      color: widget.isMe
                          ? Colors.white.withValues(alpha: 0.7)
                          : colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
