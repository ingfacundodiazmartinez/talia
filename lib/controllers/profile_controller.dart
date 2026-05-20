import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:image_picker/image_picker.dart';
import '../models/parent.dart';
import '../services/image_service.dart';
import '../services/data_management_service.dart';
import '../utils/release_logger.dart';

/// Controller que maneja la lógica del perfil de usuario
///
/// Responsabilidades:
/// - Manejar autenticación de usuario
/// - Gestionar imagen de perfil
/// - Actualizar configuraciones de usuario
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ProfileController {
  late final String parentId;
  final ImageService _imageService;
  final firebase_auth.FirebaseAuth _auth;

  Parent? _parent;

  // Getters for authentication
  firebase_auth.User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;
  String? get currentUserEmail => _auth.currentUser?.email;
  bool get isUserAuthenticated => currentUser != null;

  ProfileController({
    ImageService? imageService,
    firebase_auth.FirebaseAuth? auth,
  })  : _imageService = imageService ?? ImageService(),
        _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  /// Inicializa el controller cargando los datos del padre
  Future<void> initialize() async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.error('Usuario no autenticado en ProfileController', tag: 'ProfileController');
        return;
      }

      parentId = currentUser.uid;
      _parent = await Parent.getById(parentId);
      ReleaseLogger.log('ProfileController inicializado para usuario: $parentId', tag: 'ProfileController');
    } catch (e) {
      ReleaseLogger.error('Error inicializando ProfileController: $e', tag: 'ProfileController');
    }
  }

  /// Maneja la selección y subida de una imagen de perfil
  /// Retorna la URL de la imagen subida o null si hubo error
  Future<String?> pickAndUploadImage(ImageSource source, {BuildContext? context}) async {
    try {
      ReleaseLogger.log('Iniciando selección de imagen desde: ${source == ImageSource.camera ? 'cámara' : 'galería'}', tag: 'ProfileController');

      // Si no hay contexto, no podemos mostrar el cropper - error
      if (context == null) {
        throw Exception('Se requiere BuildContext para seleccionar imagen');
      }

      // Usar el flujo completo de ImageService que incluye crop circular
      final String? downloadUrl = await _imageService.pickAndUploadProfileImage(
        source: source,
        context: context,
      );

      return downloadUrl;
    } catch (e) {
      ReleaseLogger.error('Error en pickAndUploadImage: $e', tag: 'ProfileController');
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
      ReleaseLogger.error('Error eliminando foto de perfil: $e', tag: 'ProfileController');
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
      ReleaseLogger.error('Error actualizando auto-aprobación: $e', tag: 'ProfileController');
      rethrow;
    }
  }

  /// Realiza el logout del usuario
  Future<void> logout() async {
    try {
      if (_parent != null) {
        await _parent!.logout();
      }

      // Limpiar todo el cache local antes de cerrar sesión
      await DataManagementService().clearAllLocalDataOnLogout();

      await _auth.signOut();
    } catch (e) {
      ReleaseLogger.error('Error durante logout: $e', tag: 'ProfileController');
      rethrow;
    }
  }

  /// Obtiene un mensaje de error amigable desde una excepción
  static String getErrorMessage(dynamic error) {
    final errorString = error.toString();

    if (errorString.contains('PlatformException')) {
      if (errorString.contains('camera_access_denied')) {
        return 'Acceso a la cámara denegado. Ve a Configuración > Aplicaciones > Tália > Permisos para habilitarlo.';
      } else if (errorString.contains('photo_access_denied')) {
        return 'Acceso a la galería denegado. Ve a Configuración > Aplicaciones > Tália > Permisos para habilitarlo.';
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
