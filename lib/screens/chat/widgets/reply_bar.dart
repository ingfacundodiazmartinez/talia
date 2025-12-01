import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Barra que muestra el mensaje al que se está respondiendo
class ReplyBar extends StatelessWidget {
  final Map<String, dynamic> messageData;
  final VoidCallback onClose;

  const ReplyBar({
    super.key,
    required this.messageData,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    final senderName = messageData['senderName'] ?? 'Usuario';
    final text = messageData['text'] as String? ?? '';
    final imageUrl = messageData['imageUrl'] as String?;
    final videoUrl = messageData['videoUrl'] as String?;
    final audioUrl = messageData['audioUrl'] as String?;

    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final hasVideo = videoUrl != null && videoUrl.isNotEmpty;
    final hasAudio = audioUrl != null && audioUrl.isNotEmpty;
    final hasText = text.isNotEmpty;

    // Determinar el texto a mostrar
    String displayText;
    if (hasText) {
      displayText = text;
    } else if (hasImage) {
      displayText = '📷 Foto';
    } else if (hasVideo) {
      displayText = '🎥 Video';
    } else if (hasAudio) {
      displayText = '🎤 Audio';
    } else {
      displayText = 'Mensaje';
    }

    return Container(
      color: isDarkMode ? const Color(0xFF1C1B1F) : colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 40,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 12),
            // Miniatura si es imagen/video
            if (hasImage || hasVideo)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    width: 36,
                    height: 36,
                    color: Colors.black.withValues(alpha: 0.1),
                    child: hasImage
                        ? CachedNetworkImage(
                            imageUrl: imageUrl!, // hasImage already verifies non-null
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Icon(
                              Icons.image,
                              size: 18,
                              color: colorScheme.primary.withValues(alpha: 0.6),
                            ),
                            errorWidget: (context, url, error) => Icon(
                              Icons.broken_image,
                              size: 18,
                              color: colorScheme.primary.withValues(alpha: 0.6),
                            ),
                          )
                        : Icon(
                            Icons.play_circle_outline,
                            size: 20,
                            color: colorScheme.primary.withValues(alpha: 0.8),
                          ),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Respondiendo a $senderName',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    displayText,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                      fontStyle: hasText ? FontStyle.normal : FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              color: colorScheme.onSurfaceVariant,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
