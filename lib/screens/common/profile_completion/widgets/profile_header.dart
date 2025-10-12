import 'package:flutter/material.dart';

class ProfileHeader extends StatelessWidget {
  final bool isEditMode;

  const ProfileHeader({
    super.key,
    this.isEditMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        // Icon
        Container(
          height: 100,
          width: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDarkMode
                ? colorScheme.surfaceVariant.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.person_add,
              size: 50,
              color: isDarkMode ? colorScheme.onSurface : Colors.white,
            ),
          ),
        ),

        SizedBox(height: 24),

        // Title
        Text(
          isEditMode ? 'Actualizar Perfil' : 'Completar Perfil',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: isDarkMode ? colorScheme.onSurface : Colors.white,
          ),
        ),

        SizedBox(height: 8),

        Text(
          isEditMode
              ? 'Modifica tu información si lo deseas'
              : 'Ayúdanos a personalizar tu experiencia',
          style: TextStyle(
            fontSize: 16,
            color: isDarkMode
                ? colorScheme.onSurface.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.9),
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
