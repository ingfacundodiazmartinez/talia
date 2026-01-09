import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../../../../models/chat_message.dart';
import '../media_viewer_screen.dart';

/// Widget que muestra el contenido de un mensaje de imagen
///
/// ✅ FIX: Usa tamaño fijo para evitar resizing de la burbuja mientras carga
/// Las imágenes se centran dentro del contenedor y el fondo rellena el espacio
class ImageMessageContent extends StatelessWidget {
  final String? imageUrl;
  final String? localPath;
  final MessageStatus status;
  final String? text;
  final List<MediaItem> mediaItems;
  final int initialIndex;

  // ✅ Tamaño fijo para el contenedor de imagen
  static const double _containerWidth = 220.0;
  static const double _containerHeight = 180.0;

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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Color de fondo para rellenar espacio vacío
    final backgroundColor = isDarkMode
        ? Colors.black54
        : colorScheme.surfaceContainerHighest;

    return Column(
      children: [
        // ✅ Contenedor de tamaño fijo para evitar resizing
        Container(
          width: _containerWidth,
          height: _containerHeight,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Si está enviando y tiene localPath, mostrar imagen local
                if (status == MessageStatus.sending && imageUrl == null && localPath != null)
                  Image.file(
                    File(localPath!),
                    fit: BoxFit.contain,
                    width: _containerWidth,
                    height: _containerHeight,
                    cacheWidth: (_containerWidth * MediaQuery.of(context).devicePixelRatio).round(),
                    errorBuilder: (context, error, stackTrace) {
                      return _buildPlaceholder(colorScheme, 'Cargando...');
                    },
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
                    child: CachedNetworkImage(
                      imageUrl: imageUrl!,
                      width: _containerWidth,
                      height: _containerHeight,
                      fit: BoxFit.contain,
                      memCacheWidth: (_containerWidth * MediaQuery.of(context).devicePixelRatio).round(),
                      maxWidthDiskCache: 800,
                      maxHeightDiskCache: 800,
                      placeholder: (context, url) => _buildLoadingPlaceholder(colorScheme),
                      errorWidget: (context, url, error) => _buildErrorPlaceholder(colorScheme),
                    ),
                  )
                else
                  _buildPlaceholder(colorScheme, 'Sin imagen'),
              ],
            ),
          ),
        ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme, String message) {
    return Container(
      width: _containerWidth,
      height: _containerHeight,
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
      width: _containerWidth,
      height: _containerHeight,
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
      width: _containerWidth,
      height: _containerHeight,
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
