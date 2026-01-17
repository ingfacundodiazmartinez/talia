import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../controllers/profile_controller.dart';
import '../../services/image_service.dart';
import '../../utils/release_logger.dart';

/// Widget que muestra el header del perfil con foto, nombre y email
class ProfileHeaderWidget extends StatefulWidget {
  final String parentId;
  final String? email;
  final ProfileController controller;
  final VoidCallback onImageChanged;

  const ProfileHeaderWidget({
    super.key,
    required this.parentId,
    required this.email,
    required this.controller,
    required this.onImageChanged,
  });

  @override
  State<ProfileHeaderWidget> createState() => _ProfileHeaderWidgetState();
}

class _ProfileHeaderWidgetState extends State<ProfileHeaderWidget> {
  final ImageService _imageService = ImageService();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(widget.parentId)
          .snapshots(),
      builder: (context, snapshot) {
        String? photoURL;
        String? displayName;

        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          photoURL = data?['photoURL'];
          displayName = data?['name'];
        }

        return Center(
          child: Column(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: colorScheme.primary,
                    child: photoURL != null
                        ? ClipOval(
                            child: CachedNetworkImage(
                              imageUrl: photoURL,
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Icon(Icons.person, size: 60, color: Colors.white),
                              errorWidget: (context, url, error) => Icon(Icons.person, size: 60, color: Colors.white),
                            ),
                          )
                        : Icon(Icons.person, size: 60, color: Colors.white),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => _showImageOptions(context, photoURL),
                      child: Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          Icons.camera_alt,
                          size: 20,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16),
              Text(
                displayName ?? 'Usuario',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
              SizedBox(height: 4),
              Text(
                widget.email ?? '',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: 8),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Cuenta Padre',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Muestra opciones de imagen usando el flujo de ImageService
  /// (Mismo enfoque que EditProfileScreen - funciona en iOS)
  Future<void> _showImageOptions(BuildContext context, String? photoURL) async {
    ReleaseLogger.log('Iniciando cambio de foto de perfil...', tag: 'ProfileHeader');

    try {
      // Mostrar selector de fuente de imagen (maneja el bottom sheet internamente)
      final source = await _imageService.showImageSourceSelection(context);
      ReleaseLogger.log('Selector cerrado. Source seleccionado: $source', tag: 'ProfileHeader');

      if (source == null) {
        ReleaseLogger.log('Usuario canceló la selección', tag: 'ProfileHeader');
        return;
      }

      ReleaseLogger.log('Iniciando selección y subida de imagen...', tag: 'ProfileHeader');

      // Seleccionar imagen (pickAndUploadProfileImage maneja el loading dialog internamente)
      final String? imageUrl = await widget.controller.pickAndUploadImage(source, context: context);

      ReleaseLogger.log('Resultado: ${imageUrl != null ? 'URL obtenida' : 'null'}', tag: 'ProfileHeader');

      if (imageUrl != null && mounted) {
        widget.onImageChanged();
        ReleaseLogger.log('Foto de perfil actualizada exitosamente', tag: 'ProfileHeader');
      }
    } catch (e) {
      ReleaseLogger.error('Error al cambiar foto: $e', tag: 'ProfileHeader');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ProfileController.getErrorMessage(e)),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }
}
