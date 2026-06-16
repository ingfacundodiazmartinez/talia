import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../../../../models/chat_message.dart';
import '../media_viewer_screen.dart';

/// Widget que muestra el contenido de un mensaje de imagen
///
/// ✅ Contenedor CUADRADO de tamaño fijo (no hay resizing mientras carga) y
/// la imagen lo llena completo con BoxFit.cover — sin franjas laterales en
/// fotos portrait ni franjas verticales en panorámicas. El recorte es solo
/// visual: el tap abre el MediaViewer con la foto completa.
class ImageMessageContent extends StatelessWidget {
  final String? imageUrl;
  final String? localPath;
  final MessageStatus status;
  final String? text;
  final List<MediaItem> mediaItems;
  final int initialIndex;

  // ✅ Tamaño fijo cuadrado para el contenedor de imagen
  static const double _containerSize = 220.0;

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
          child: SizedBox(
            width: _containerSize,
            height: _containerSize,
            // Mientras NO haya URL de red (enviando o error), mostrar la
            // imagen local. ✅ FIX: antes solo en 'sending' → si el envío
            // fallaba (status error) la burbuja quedaba vacía ("Sin imagen").
            child: (imageUrl == null && localPath != null)
                ? Image.file(
                    File(localPath!),
                    fit: BoxFit.cover,
                    width: _containerSize,
                    height: _containerSize,
                    cacheWidth: (_containerSize *
                            MediaQuery.of(context).devicePixelRatio)
                        .round(),
                    errorBuilder: (context, error, stackTrace) {
                      return _buildPlaceholder(
                        colorScheme,
                        status == MessageStatus.error ? 'Error' : 'Cargando...',
                      );
                    },
                  )
                : (imageUrl != null)
                    ? GestureDetector(
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
                        child: CachedNetworkImage(
                          imageUrl: imageUrl!,
                          width: _containerSize,
                          height: _containerSize,
                          fit: BoxFit.cover,
                          memCacheWidth: (_containerSize *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          maxWidthDiskCache: 800,
                          maxHeightDiskCache: 800,
                          placeholder: (context, url) =>
                              _buildLoadingPlaceholder(colorScheme),
                          errorWidget: (context, url, error) =>
                              _buildErrorPlaceholder(colorScheme),
                        ),
                      )
                    : _buildPlaceholder(colorScheme, 'Sin imagen'),
          ),
        ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme, String message) {
    return Container(
      width: _containerSize,
      height: _containerSize,
      color: colorScheme.surfaceContainerHighest,
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
            message,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: _containerSize,
      height: _containerSize,
      color: colorScheme.surfaceContainerHighest,
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
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: _containerSize,
      height: _containerSize,
      color: colorScheme.errorContainer,
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
    );
  }
}
