import 'package:flutter/material.dart';

/// Widget que muestra el caption/texto de una historia
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
        left: 16,
        right: 16,
        top: 16,
        // Agregar padding inferior si NO es la historia del usuario actual
        // (porque el input de respuesta estará visible abajo)
        bottom: !isCurrentUser ? 80 : 16, // Espacio para el input de respuesta
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          caption,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
