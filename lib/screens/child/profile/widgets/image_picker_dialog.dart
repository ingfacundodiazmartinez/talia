import 'package:flutter/material.dart';

/// Dialog para seleccionar imagen de perfil
class ImagePickerDialog extends StatelessWidget {
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onDelete;

  const ImagePickerDialog({
    super.key,
    required this.onCamera,
    required this.onGallery,
    required this.onDelete,
  });

  /// Muestra el dialog de selección de imagen
  static void show(
    BuildContext context, {
    required VoidCallback onCamera,
    required VoidCallback onGallery,
    required VoidCallback onDelete,
  }) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => ImagePickerDialog(
        onCamera: onCamera,
        onGallery: onGallery,
        onDelete: onDelete,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Cambiar foto de perfil',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildImageOption(
                context: context,
                icon: Icons.camera_alt,
                label: 'Cámara',
                onTap: onCamera,
              ),
              _buildImageOption(
                context: context,
                icon: Icons.photo_library,
                label: 'Galería',
                onTap: onGallery,
              ),
              _buildImageOption(
                context: context,
                icon: Icons.delete,
                label: 'Eliminar',
                onTap: onDelete,
                isDestructive: true,
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildImageOption({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDestructive
                  ? Colors.red.withValues(alpha: 0.1)
                  : colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              size: 32,
              color: isDestructive ? Colors.red : colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDestructive ? Colors.red : colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
