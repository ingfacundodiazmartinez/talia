import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Widget que muestra la preview de un mensaje al que se está respondiendo
class ReplyPreviewWidget extends StatelessWidget {
  final Map<String, dynamic> replyTo;
  final bool isMe;
  final VoidCallback? onTap;

  const ReplyPreviewWidget({
    super.key,
    required this.replyTo,
    required this.isMe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // ✅ FIX: Detectar respuesta a historia
    final isStoryReply = replyTo['type'] == 'story_reply';
    final storyMediaUrl = replyTo['storyMediaUrl'] as String?;
    final hasStoryMedia = isStoryReply && storyMediaUrl != null && storyMediaUrl.isNotEmpty;

    final hasImage = replyTo['imageUrl'] != null;
    final hasVideo = replyTo['videoUrl'] != null;
    final hasAudio = replyTo['audioUrl'] != null;
    final hasText = replyTo['text'] != null && replyTo['text'].toString().isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: (isMe ? Colors.white : colorScheme.primary).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: isMe ? Colors.white : colorScheme.primary,
              width: 3,
            ),
          ),
        ),
        child: Row(
        children: [
          // Miniatura de la foto/video/audio/historia si existe
          if (hasStoryMedia || hasImage || hasVideo || hasAudio)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 40,
                  height: 40,
                  color: Colors.black.withValues(alpha: 0.2),
                  child: hasStoryMedia
                      // ✅ FIX: Mostrar thumbnail de historia
                      ? CachedNetworkImage(
                          imageUrl: storyMediaUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Icon(
                            Icons.auto_stories,
                            size: 20,
                            color: isMe
                                ? Colors.white.withValues(alpha: 0.6)
                                : colorScheme.primary.withValues(alpha: 0.6),
                          ),
                          errorWidget: (context, url, error) => Icon(
                            Icons.auto_stories,
                            size: 20,
                            color: isMe
                                ? Colors.white.withValues(alpha: 0.6)
                                : colorScheme.primary.withValues(alpha: 0.6),
                          ),
                        )
                      : hasImage
                          ? CachedNetworkImage(
                              imageUrl: replyTo['imageUrl'],
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Icon(
                                Icons.image,
                                size: 20,
                                color: isMe
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : colorScheme.primary.withValues(alpha: 0.6),
                              ),
                              errorWidget: (context, url, error) => Icon(
                                Icons.broken_image,
                                size: 20,
                                color: isMe
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : colorScheme.primary.withValues(alpha: 0.6),
                              ),
                            )
                          : hasVideo
                              ? Icon(
                                  Icons.play_circle_outline,
                                  size: 24,
                                  color: isMe
                                      ? Colors.white.withValues(alpha: 0.8)
                                      : colorScheme.primary.withValues(alpha: 0.8),
                                )
                              : Icon(
                                  Icons.mic,
                                  size: 24,
                                  color: isMe
                                      ? Colors.white.withValues(alpha: 0.8)
                                      : colorScheme.primary.withValues(alpha: 0.8),
                                ),
                ),
              ),
            ),
          // Contenido de texto
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // ✅ FIX: Usar storyUserName para respuestas a historia
                  isStoryReply
                      ? (replyTo['storyUserName'] ?? 'Usuario')
                      : (replyTo['senderName'] ?? 'Usuario'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: isMe ? Colors.white : colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  // ✅ FIX: Mostrar caption de historia o indicador
                  isStoryReply
                      ? (replyTo['storyCaption']?.toString().isNotEmpty == true
                          ? '📖 ${replyTo['storyCaption']}'
                          : '📖 Historia')
                      : hasText
                          ? replyTo['text']
                          : hasImage
                              ? '📷 Foto'
                              : hasVideo
                                  ? '🎥 Video'
                                  : '🎤 Audio',
                  style: TextStyle(
                    fontSize: 12,
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.8)
                        : colorScheme.onSurface.withValues(alpha: 0.8),
                    fontStyle: (hasText || isStoryReply) ? FontStyle.normal : FontStyle.italic,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }
}
