import 'package:flutter/material.dart';

/// Bottom sheet que muestra las opciones de archivos adjuntos
class AttachmentOptions extends StatelessWidget {
  final VoidCallback onCameraTap;
  final VoidCallback onGalleryTap;
  final VoidCallback onVideoTap;
  final VoidCallback? onLocationTap;

  const AttachmentOptions({
    super.key,
    required this.onCameraTap,
    required this.onGalleryTap,
    required this.onVideoTap,
    this.onLocationTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Enviar archivo',
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
              _AttachmentOption(
                icon: Icons.photo_camera,
                label: 'Cámara',
                color: Colors.pink,
                onTap: onCameraTap,
              ),
              _AttachmentOption(
                icon: Icons.photo_library,
                label: 'Galería',
                color: Colors.purple,
                onTap: onGalleryTap,
              ),
              _AttachmentOption(
                icon: Icons.videocam,
                label: 'Video',
                color: Colors.red,
                onTap: onVideoTap,
              ),
              if (onLocationTap != null)
                _AttachmentOption(
                  icon: Icons.location_on,
                  label: 'Ubicación',
                  color: Colors.green,
                  onTap: onLocationTap!,
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  static void show(
    BuildContext context, {
    required VoidCallback onCameraTap,
    required VoidCallback onGalleryTap,
    required VoidCallback onVideoTap,
    VoidCallback? onLocationTap,
  }) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => AttachmentOptions(
        onCameraTap: onCameraTap,
        onGalleryTap: onGalleryTap,
        onVideoTap: onVideoTap,
        onLocationTap: onLocationTap,
      ),
    );
  }
}

class _AttachmentOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AttachmentOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 32),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
