import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/child_profile_service.dart';
import '../services/image_service.dart';

/// Controller que maneja la lógica del perfil de usuario child
class ChildProfileController {
  final String userId;
  final ChildProfileService _profileService;
  final ImageService _imageService;

  ChildProfileController({
    required this.userId,
    ChildProfileService? profileService,
    ImageService? imageService,
  })  : _profileService = profileService ?? ChildProfileService(),
        _imageService = imageService ?? ImageService();

  /// Maneja la selección y subida de una imagen de perfil
  Future<String?> pickAndUploadImage(ImageSource source, BuildContext context) async {
    try {
      final String? downloadUrl = await _imageService.pickAndUploadProfileImage(
        source: source,
        context: context,
      );
      return downloadUrl;
    } catch (e) {
      print('Error en pickAndUploadImage: $e');
      rethrow;
    }
  }

  /// Elimina la foto de perfil del usuario
  Future<void> deleteProfileImage() async {
    try {
      await _imageService.deleteProfileImage();
    } catch (e) {
      print('Error eliminando foto de perfil: $e');
      rethrow;
    }
  }

  /// Realiza el logout del usuario
  Future<void> logout() async {
    try {
      await _profileService.logout(userId);
    } catch (e) {
      print('Error durante logout: $e');
      rethrow;
    }
  }

  /// Verifica si el usuario es adulto
  Future<bool> isAdultUser() async {
    return await _profileService.isAdultUser(userId);
  }

  /// Obtiene un mensaje de error amigable desde una excepción
  static String getErrorMessage(dynamic error, ImageSource source) {
    final errorString = error.toString();

    if (errorString.contains('Permisos') &&
        errorString.contains('denegados')) {
      return 'No se pudo acceder ${source == ImageSource.camera ? 'a la cámara' : 'a la galería'} porque los permisos fueron denegados.';
    } else if (errorString.contains(
      'Firebase Storage no está configurado',
    )) {
      return 'Error de configuración. Contacta al administrador.';
    } else if (errorString.contains('cámara denegado')) {
      return 'Acceso a la cámara denegado. Verifica los permisos de la aplicación.';
    } else if (errorString.contains('galería denegado')) {
      return 'Acceso a la galería denegado. Verifica los permisos de la aplicación.';
    } else if (errorString.contains('PlatformException')) {
      return 'Error de plataforma. Intenta reiniciar la aplicación.';
    } else if (errorString.contains('conexión') ||
        errorString.contains('internet')) {
      return 'Error de conexión. Verifica tu conexión a internet e intenta nuevamente.';
    } else {
      return errorString.replaceAll('Exception: ', '');
    }
  }

  /// Cleanup
  void dispose() {
    // No hay recursos que limpiar por ahora
  }
}
