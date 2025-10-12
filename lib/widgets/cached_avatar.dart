import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Widget optimizado para mostrar avatares de usuario con caché
///
/// Características:
/// - Usa CachedNetworkImage para caché automático
/// - Límites de tamaño para optimizar memoria y disco
/// - Placeholder y error widgets personalizados
/// - Thumbnail optimizado para listas
class CachedAvatar extends StatelessWidget {
  final String? imageUrl;
  final double radius;
  final String? userName;
  final Color? backgroundColor;

  const CachedAvatar({
    super.key,
    required this.imageUrl,
    this.radius = 20,
    this.userName,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Si no hay URL, mostrar inicial
    if (imageUrl == null || imageUrl!.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor ?? colorScheme.primaryContainer,
        child: Text(
          _getInitial(userName ?? '?'),
          style: TextStyle(
            color: colorScheme.onPrimaryContainer,
            fontSize: radius * 0.8,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: imageUrl!,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          // Optimización: thumbnails pequeños para avatares
          memCacheWidth: (radius * 2 * 3).toInt(), // 3x para alta resolución
          memCacheHeight: (radius * 2 * 3).toInt(),
          maxWidthDiskCache: 200, // Tamaño pequeño en disco
          maxHeightDiskCache: 200,
          placeholder: (context, url) => Container(
            width: radius * 2,
            height: radius * 2,
            color: colorScheme.surfaceContainerHighest,
            child: Center(
              child: SizedBox(
                width: radius * 0.5,
                height: radius * 0.5,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary.withOpacity(0.5),
                ),
              ),
            ),
          ),
          errorWidget: (context, url, error) => Container(
            width: radius * 2,
            height: radius * 2,
            color: backgroundColor ?? colorScheme.primaryContainer,
            child: Center(
              child: Text(
                _getInitial(userName ?? '?'),
                style: TextStyle(
                  color: colorScheme.onPrimaryContainer,
                  fontSize: radius * 0.8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _getInitial(String name) {
    if (name.isEmpty) return '?';
    return name.substring(0, 1).toUpperCase();
  }
}

/// Widget de avatar con indicador de estado online
class CachedAvatarWithStatus extends StatelessWidget {
  final String? imageUrl;
  final double radius;
  final String? userName;
  final bool isOnline;
  final Color? backgroundColor;

  const CachedAvatarWithStatus({
    super.key,
    required this.imageUrl,
    this.radius = 20,
    this.userName,
    this.isOnline = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CachedAvatar(
          imageUrl: imageUrl,
          radius: radius,
          userName: userName,
          backgroundColor: backgroundColor,
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: radius * 0.4,
              height: radius * 0.4,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
