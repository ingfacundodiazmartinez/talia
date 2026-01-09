import 'dart:io';
import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';
import '../media_viewer_screen.dart';

/// Widget que muestra el contenido de un mensaje de video
///
/// ✅ FIX: Usa tamaño fijo consistente con ImageMessageContent
class VideoMessageContent extends StatelessWidget {
  final String? videoUrl;
  final String? localPath;
  final String? thumbnailPath;
  final MessageStatus status;
  final String? text;
  final List<MediaItem> mediaItems;
  final int initialIndex;

  // ✅ Tamaño fijo para el contenedor de video (consistente con imagen)
  static const double _containerWidth = 220.0;
  static const double _containerHeight = 180.0;

  const VideoMessageContent({
    super.key,
    required this.videoUrl,
    this.localPath,
    this.thumbnailPath,
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
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => MediaViewerScreen(
                        mediaItems: mediaItems,
                        initialIndex: initialIndex,
                      ),
                    ),
                  );
                }
              : null,
          child: Container(
            width: _containerWidth,
            height: _containerHeight,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Mostrar thumbnail si está disponible
                if (thumbnailPath != null && thumbnailPath!.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(thumbnailPath!),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),

                // Icono de play
                const Icon(
                  Icons.play_circle_outline,
                  size: 64,
                  color: Colors.white,
                ),

                // Indicator de subiendo si está enviando
                if (status == MessageStatus.sending)
                  Positioned.fill(
                    child: Container(
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
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }
}
