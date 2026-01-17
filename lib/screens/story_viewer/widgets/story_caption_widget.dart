import 'package:flutter/material.dart';

/// Widget que muestra el caption/texto de una historia
/// Estilo Instagram: texto con sombra sutil para legibilidad
class StoryCaptionWidget extends StatelessWidget {
  final String caption;
  final bool isCurrentUser;

  const StoryCaptionWidget({
    super.key,
    required this.caption,
    required this.isCurrentUser,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        // Agregar padding inferior si NO es la historia del usuario actual
        // (porque el input de respuesta estará visible abajo)
        bottom: !isCurrentUser ? 90 : 16,
      ),
      child: Text(
        caption,
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          shadows: [
            // Sombra principal para legibilidad
            Shadow(
              offset: const Offset(0, 1),
              blurRadius: 3,
              color: Colors.black.withValues(alpha: 0.8),
            ),
            // Sombra secundaria más suave
            Shadow(
              offset: const Offset(0, 2),
              blurRadius: 6,
              color: Colors.black.withValues(alpha: 0.5),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
