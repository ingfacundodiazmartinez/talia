import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../../../../models/chat_message.dart';
import '../media_viewer_screen.dart';

/// Widget que muestra el contenido de un mensaje de imagen
class ImageMessageContent extends StatelessWidget {
  final String? imageUrl;
  final String? localPath;
  final MessageStatus status;
  final String? text;
  final List<MediaItem> mediaItems;
  final int initialIndex;

  const ImageMessageContent({
    super.key,
    required this.imageUrl,
    this.localPath,
    required this.status,
    this.text,
    required this.mediaItems,
    required this.initialIndex,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Si está enviando y tiene localPath, mostrar imagen local
              if (status == MessageStatus.sending && imageUrl == null && localPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.6,
                      maxHeight: 220,
                    ),
                    child: Image.file(
                      File(localPath!),
                      fit: BoxFit.contain,
                    ),
                  ),
                )
              // Si tiene URL, mostrar de red
              else if (imageUrl != null)
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MediaViewerScreen(
                          mediaItems: mediaItems,
                          initialIndex: initialIndex,
                        ),
                      ),
                    );
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.6,
                      height: 180,
                      color: Colors.black,
                      child: Builder(
                        builder: (context) {
                          print('🖼️ [DEBUG] Intentando cargar imagen: $imageUrl');
                          return CachedNetworkImage(
                            imageUrl: imageUrl!,
                            fit: BoxFit.cover,
                            // Optimización de memoria: limitar tamaño en RAM
                            memCacheWidth: (MediaQuery.of(context).size.width *
                                    0.6 *
                                    MediaQuery.of(context).devicePixelRatio)
                                .round(),
                            memCacheHeight: (180 * MediaQuery.of(context).devicePixelRatio).round(),
                            // Optimización de disco: limitar tamaño de caché
                            maxWidthDiskCache: 800,
                            maxHeightDiskCache: 800,
                            placeholder: (context, url) => Container(
                          width: MediaQuery.of(context).size.width * 0.6,
                          height: 180,
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.image_outlined,
                                size: 48,
                                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                              ),
                              const SizedBox(height: 12),
                              const SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          width: MediaQuery.of(context).size.width * 0.6,
                          height: 180,
                          decoration: BoxDecoration(
                            color: colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.broken_image_outlined,
                                size: 48,
                                color: colorScheme.error,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Error cargando imagen',
                                style: TextStyle(
                                  color: colorScheme.error,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),

              // Overlay de "Subiendo..." si está enviando
              if (status == MessageStatus.sending)
                Container(
                  width: MediaQuery.of(context).size.width * 0.6,
                  height: 200,
                  color: Colors.black.withValues(alpha: 0.4),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Subiendo...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }
}
