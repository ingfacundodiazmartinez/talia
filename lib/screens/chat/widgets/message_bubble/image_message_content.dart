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
              // Si está enviando y tiene localPath, mostrar imagen local inmediatamente
              if (status == MessageStatus.sending && imageUrl == null && localPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.6,
                      maxHeight: 300,
                    ),
                    child: Image.file(
                      File(localPath!),
                      fit: BoxFit.contain,
                      // ✅ Cargar imagen inmediatamente con máxima prioridad
                      cacheWidth: (MediaQuery.of(context).size.width * 0.6 *
                              MediaQuery.of(context).devicePixelRatio)
                          .round(),
                      errorBuilder: (context, error, stackTrace) {
                        // Placeholder si el archivo no se puede cargar
                        return Container(
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
                                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Cargando...',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
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
                    child: Builder(
                      builder: (context) {
                        return CachedNetworkImage(
                          imageUrl: imageUrl!,
                          // Usar imageBuilder para controlar el aspect ratio
                          imageBuilder: (context, imageProvider) {
                            return ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.6,
                                maxHeight: 300,
                              ),
                              child: Image(
                                image: imageProvider,
                                fit: BoxFit.contain,
                              ),
                            );
                          },
                          // Optimización de memoria: limitar tamaño en RAM
                          memCacheWidth: (MediaQuery.of(context).size.width *
                                  0.6 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
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

              // ✅ REMOVED: El overlay "Subiendo..." fue eliminado
              // El indicador de estado en MessageTimestamp es suficiente
            ],
          ),
        ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }
}
