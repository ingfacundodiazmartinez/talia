import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:image_picker/image_picker.dart';
import '../models/parent.dart';
import '../services/image_service.dart';

/// Controller que maneja la lógica del perfil de usuario
class ProfileController {
  final String parentId;
  final ImageService _imageService;
  final firebase_auth.FirebaseAuth _auth;

  Parent? _parent;

  ProfileController({
    required this.parentId,
    ImageService? imageService,
    firebase_auth.FirebaseAuth? auth,
  })  : _imageService = imageService ?? ImageService(),
        _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  /// Inicializa el controller cargando los datos del padre
  Future<void> initialize() async {
    _parent = await Parent.getById(parentId);
  }

  /// Maneja la selección y subida de una imagen de perfil
  /// Retorna la URL de la imagen subida o null si hubo error
  Future<String?> pickAndUploadImage(ImageSource source) async {
    try {
      print('🔄 Iniciando selección de imagen desde: ${source == ImageSource.camera ? 'cámara' : 'galería'}');

      final pickedFile = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );

      if (pickedFile == null) {
        print('📷 Usuario canceló la selección de imagen');
        return null;
      }

      print('✅ Imagen seleccionada: ${pickedFile.path}');

      // Subir imagen
      final String? downloadUrl = await _imageService.uploadImageToStorage(pickedFile.path);

      if (downloadUrl != null && _parent != null) {
        // Actualizar Firestore
        await _parent!.updatePhotoURL(downloadUrl);
      }

      return downloadUrl;
    } catch (e) {
      print('❌ Error en pickAndUploadImage: $e');
      rethrow; // Propagar el error para que el UI lo maneje
    }
  }

  /// Elimina la foto de perfil del usuario
  Future<void> deleteProfileImage() async {
    try {
      await _imageService.deleteProfileImage();

      if (_parent != null) {
        await _parent!.deletePhotoURL();
      }
    } catch (e) {
      print('❌ Error eliminando foto de perfil: $e');
      rethrow;
    }
  }

  /// Actualiza la configuración de aprobación automática
  Future<void> toggleAutoApproval(bool enabled) async {
    if (_parent == null) {
      throw Exception('Parent not initialized');
    }

    try {
      await _parent!.updateAutoApprovalSetting(enabled);
    } catch (e) {
      print('❌ Error actualizando auto-aprobación: $e');
      rethrow;
    }
  }

  /// Realiza el logout del usuario
  Future<void> logout() async {
    try {
      if (_parent != null) {
        await _parent!.logout();
      }

      await _auth.signOut();
    } catch (e) {
      print('❌ Error durante logout: $e');
      rethrow;
    }
  }

  /// Obtiene un mensaje de error amigable desde una excepción
  static String getErrorMessage(dynamic error) {
    final errorString = error.toString();

    if (errorString.contains('PlatformException')) {
      if (errorString.contains('camera_access_denied')) {
        return 'Acceso a la cámara denegado. Ve a Configuración > Aplicaciones > Talia > Permisos para habilitarlo.';
      } else if (errorString.contains('photo_access_denied')) {
        return 'Acceso a la galería denegado. Ve a Configuración > Aplicaciones > Talia > Permisos para habilitarlo.';
      } else {
        return 'Error de plataforma. Intenta reiniciar la aplicación.';
      }
    } else if (errorString.contains('Firebase Storage no está configurado')) {
      return 'Error de configuración. Contacta al administrador.';
    } else if (errorString.contains('conexión') || errorString.contains('internet')) {
      return 'Error de conexión. Verifica tu conexión a internet e intenta nuevamente.';
    } else {
      return errorString.replaceAll('Exception: ', '');
    }
  }

  /// Cleanup
  void dispose() {
    _parent = null;
  }
}
