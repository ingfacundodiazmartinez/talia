import 'package:firebase_auth/firebase_auth.dart';
import '../models/parent.dart';
import '../models/user.dart' as user_model;
import '../services/image_service.dart';
import '../services/user_role_service.dart';

/// Controller para manejar la lógica de edición de perfil
class EditProfileController {
  final String userId;
  final ImageService _imageService;
  final UserRoleService _roleService;
  final FirebaseAuth _auth;

  Parent? _parent;
  Map<String, dynamic>? _userData;

  EditProfileController({
    required this.userId,
    ImageService? imageService,
    UserRoleService? roleService,
    FirebaseAuth? auth,
  }) : _imageService = imageService ?? ImageService(),
       _roleService = roleService ?? UserRoleService(),
       _auth = auth ?? FirebaseAuth.instance;

  /// Inicializa el controller cargando datos del usuario
  Future<void> initialize() async {
    _parent = await Parent.getById(userId);
    _userData = await _parent?.getUserData();
  }

  /// Obtiene los datos del usuario
  Map<String, dynamic>? get userData => _userData;

  /// Carga los datos actualizados del usuario
  Future<Map<String, dynamic>?> loadUserData() async {
    if (_parent == null) {
      _parent = Parent(id: userId, name: '');
    }

    _userData = await _parent!.getUserData();
    return _userData;
  }

  /// Maneja la subida de foto de perfil (la selección se hace en el screen)
  Future<String?> uploadProfilePhoto(String imagePath) async {
    try {
      final String? imageUrl = await _imageService.uploadImageToStorage(
        imagePath,
      );

      if (imageUrl != null && _parent != null) {
        await _parent!.updatePhotoURL(imageUrl);
        return imageUrl;
      }

      return null;
    } catch (e) {
      print('❌ Error subiendo foto de perfil: $e');
      rethrow;
    }
  }

  /// Valida los datos del formulario
  String? validateProfileData({
    required String name,
    required String phone,
    DateTime? birthDate,
  }) {
    if (name.isEmpty) {
      return 'El nombre no puede estar vacío';
    }

    if (phone.isEmpty) {
      return 'El teléfono no puede estar vacío';
    }

    if (birthDate == null) {
      return 'Por favor selecciona tu fecha de nacimiento';
    }

    return null; // Todo válido
  }

  /// Calcula la edad desde una fecha de nacimiento
  int calculateAge(DateTime birthDate) {
    return user_model.User.calculateAge(birthDate) ?? 0;
  }

  /// Guarda el perfil actualizado
  Future<void> saveProfile({
    required String name,
    required String phone,
    required DateTime birthDate,
  }) async {
    try {
      if (_parent == null) {
        throw Exception('Parent not initialized');
      }

      // Validar datos
      final validationError = validateProfileData(
        name: name,
        phone: phone,
        birthDate: birthDate,
      );

      if (validationError != null) {
        throw Exception(validationError);
      }

      // Actualizar nombre en Firebase Auth
      await _auth.currentUser?.updateDisplayName(name);

      // Calcular edad
      final age = calculateAge(birthDate);

      // Determinar rol basado en edad
      final newRole = await _roleService.determineUserRole(userId, age);

      // Actualizar perfil en Firestore
      await _parent!.updateProfile(
        name: name,
        phone: phone,
        birthDate: birthDate,
        role: newRole,
      );

      print('✅ Perfil actualizado con rol: $newRole (edad: $age)');
    } catch (e) {
      print('❌ Error guardando perfil: $e');
      rethrow;
    }
  }

  /// Obtiene un mensaje de error amigable
  static String getErrorMessage(dynamic error) {
    final errorString = error.toString();

    if (errorString.contains('not found')) {
      return 'Usuario no encontrado';
    } else if (errorString.contains('connection') ||
        errorString.contains('internet')) {
      return 'Error de conexión. Verifica tu conexión a internet';
    } else if (errorString.contains('permission')) {
      return 'No tienes permisos para realizar esta acción';
    } else {
      return errorString.replaceAll('Exception: ', '');
    }
  }

  /// Cleanup
  void dispose() {
    _parent = null;
    _userData = null;
  }
}
