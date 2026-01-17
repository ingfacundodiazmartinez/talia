import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ProfileImagePicker extends StatelessWidget {
  final File? profileImage;
  final String? existingPhotoURL;
  final VoidCallback onTap;
  final bool isEditMode;

  const ProfileImagePicker({
    super.key,
    this.profileImage,
    this.existingPhotoURL,
    required this.onTap,
    this.isEditMode = false,
  });

  Widget _buildDefaultPhotoPlaceholder(ColorScheme colorScheme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.camera_alt,
          size: 40,
          color: colorScheme.primary,
        ),
        SizedBox(height: 4),
        Text(
          isEditMode ? 'Cambiar\nFoto' : 'Agregar\nFoto',
          style: TextStyle(
            color: colorScheme.primary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colorScheme.primaryContainer,
          border: Border.all(
            color: colorScheme.primary.withValues(alpha: 0.3),
            width: 2,
          ),
        ),
        child: profileImage != null
            ? ClipOval(
                child: Image.file(
                  profileImage!,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              )
            : existingPhotoURL != null
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: existingPhotoURL!,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Center(
                        child: CircularProgressIndicator(
                          color: colorScheme.primary,
                        ),
                      ),
                      errorWidget: (context, url, error) {
                        return _buildDefaultPhotoPlaceholder(colorScheme);
                      },
                    ),
                  )
                : _buildDefaultPhotoPlaceholder(colorScheme),
      ),
    );
  }
}
