import 'package:flutter/material.dart';

/// Widget que muestra el contenido de un mensaje bloqueado por moderación
class BlockedMessageContent extends StatelessWidget {
  final bool isMe;
  final String? moderationReason;
  final String? originalText;
  final String? messageId;
  final Function(String messageId, String originalText)? onEdit;

  const BlockedMessageContent({
    super.key,
    required this.isMe,
    this.moderationReason,
    this.originalText,
    this.messageId,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.block,
                color: isMe
                    ? Colors.white.withValues(alpha: 0.9)
                    : colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mensaje bloqueado',
                  style: TextStyle(
                    color: isMe
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
            moderationReason ?? 'Este mensaje fue bloqueado por contener contenido inapropiado.',
            style: TextStyle(
              color: isMe
                  ? Colors.white.withValues(alpha: 0.8)
                  : colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isMe
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
                  color: isMe
                      ? Colors.white.withValues(alpha: 0.7)
                      : colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Este mensaje no cumple con las normas de seguridad de la moderación con IA.',
                    style: TextStyle(
                      color: isMe
                          ? Colors.white.withValues(alpha: 0.7)
                          : colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Botón de editar para mensajes propios
          if (isMe && onEdit != null && originalText != null && messageId != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => onEdit!(messageId!, originalText!),
                icon: Icon(
                  Icons.edit,
                  size: 16,
                  color: isMe ? Colors.white : colorScheme.primary,
                ),
                label: Text(
                  'Editar mensaje',
                  style: TextStyle(
                    color: isMe ? Colors.white : colorScheme.primary,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.5)
                        : colorScheme.primary.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
