import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Widget para mostrar foto de perfil ampliada
class ProfilePhotoViewer extends StatelessWidget {
  final String photoUrl;
  final String name;

  const ProfilePhotoViewer({
    super.key,
    required this.photoUrl,
    required this.name,
  });

  /// Mostrar foto de perfil en diálogo
  static void show(BuildContext context, String photoUrl, String name) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => ProfilePhotoViewer(
        photoUrl: photoUrl,
        name: name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(16),
      child: Stack(
        children: [
          // Foto ampliada con zoom
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: photoUrl,
                  fit: BoxFit.contain,
                  placeholder: (context, url) => Container(
                    width: 200,
                    height: 200,
                    color: Colors.grey[900],
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    width: 200,
                    height: 200,
                    color: Colors.grey[900],
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.broken_image, color: Colors.white, size: 48),
                        SizedBox(height: 8),
                        Text(
                          'Error cargando imagen',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Botón cerrar
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
                tooltip: 'Cerrar',
              ),
            ),
          ),

          // Nombre del usuario
          Positioned(
            top: 16,
            left: 16,
            right: 80,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                name,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          // Instrucciones de uso
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Pellizca para hacer zoom',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Widget de Avatar clickeable que muestra la foto ampliada al tocar
class ClickableAvatar extends StatelessWidget {
  final String? photoUrl;
  final String name;
  final double radius;
  final Color? backgroundColor;

  const ClickableAvatar({
    super.key,
    required this.photoUrl,
    required this.name,
    this.radius = 20,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = radius * 2;

    return GestureDetector(
      onTap: () {
        if (photoUrl != null && photoUrl!.isNotEmpty) {
          ProfilePhotoViewer.show(context, photoUrl!, name);
        }
      },
      child: CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor ?? colorScheme.primaryContainer,
        child: photoUrl != null && photoUrl!.isNotEmpty
            ? ClipOval(
                child: CachedNetworkImage(
                  imageUrl: photoUrl!,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: radius * 0.6,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  errorWidget: (context, url, error) => Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: radius * 0.6,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              )
            : Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: radius * 0.6,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
      ),
    );
  }
}
