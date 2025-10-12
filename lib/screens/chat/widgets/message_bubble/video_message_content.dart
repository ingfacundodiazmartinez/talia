import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';
import '../media_viewer_screen.dart';

/// Widget que muestra el contenido de un mensaje de video
class VideoMessageContent extends StatelessWidget {
  final String? videoUrl;
  final String? localPath;
  final MessageStatus status;
  final String? text;
  final List<MediaItem> mediaItems;
  final int initialIndex;

  const VideoMessageContent({
    super.key,
    required this.videoUrl,
    this.localPath,
    required this.status,
    this.text,
    required this.mediaItems,
    required this.initialIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: videoUrl != null && status != MessageStatus.sending
              ? () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MediaViewerScreen(
                        mediaItems: mediaItems,
                        initialIndex: initialIndex,
                      ),
                    ),
                  );
                }
              : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.6,
              maxHeight: 220,
            ),
            child: Container(
              width: MediaQuery.of(context).size.width * 0.6,
              height: 180,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Icon(
                    Icons.play_circle_outline,
                    size: 64,
                    color: Colors.white,
                  ),
                  // Indicator de subiendo si está enviando
                  if (status == MessageStatus.sending)
                    Container(
                      color: Colors.black.withValues(alpha: 0.5),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Subiendo video...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '🎥 Video',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }
}
