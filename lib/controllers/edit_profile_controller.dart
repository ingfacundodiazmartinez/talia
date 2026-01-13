import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_functions/cloud_functions.dart';
import '../models/parent.dart';
import '../models/user.dart';
import '../services/image_service.dart';
import '../services/multimedia_moderation_service.dart';
import '../services/subscription_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de edición de perfil
///
/// Responsabilidades:
/// - Manejar autenticación de usuario
/// - Gestionar carga y guardado de datos de perfil
/// - Validar datos de entrada
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class EditProfileController {
  late final String userId;
  final ImageService _imageService;
  final firebase_auth.FirebaseAuth _auth;

  Parent? _parent;
  Map<String, dynamic>? _userData;

  // Getters for authentication
  firebase_auth.User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;
  String? get currentUserEmail => _auth.currentUser?.email;
  String? get currentUserDisplayName => _auth.currentUser?.displayName;
  String? get currentUserPhotoURL => _auth.currentUser?.photoURL;
  bool get isUserAuthenticated => currentUser != null;

  EditProfileController({
    ImageService? imageService,
    firebase_auth.FirebaseAuth? auth,
  }) : _imageService = imageService ?? ImageService(),
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  /// Inicializa el controller cargando datos del usuario
  Future<void> initialize() async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.error('Usuario no autenticado en EditProfileController', tag: 'EditProfile');
        return;
      }

      userId = currentUser.uid;
      _parent = await Parent.getById(userId);
      _userData = await _parent?.getUserData();
      ReleaseLogger.log('EditProfileController inicializado para usuario: $userId', tag: 'EditProfile');
    } catch (e) {
      ReleaseLogger.error('Error inicializando EditProfileController: $e', tag: 'EditProfile');
    }
  }

  /// Obtiene los datos del usuario
  Map<String, dynamic>? get userData => _userData;

  /// Carga los datos actualizados del usuario
  Future<Map<String, dynamic>?> loadUserData() async {
    _parent ??= Parent(id: userId, name: '');

    _userData = await _parent!.getUserData();
    return _userData;
  }

  /// Maneja la subida de foto de perfil (la selección se hace en el screen)
  ///
  /// Si el usuario tiene Premium+ y multimedia moderation habilitada,
  /// la imagen será moderada antes de guardarla en el perfil.
  Future<String?> uploadProfilePhoto(String imagePath) async {
    try {
      final String? imageUrl = await _imageService.uploadImageToStorage(
        imagePath,
      );

      if (imageUrl != null && _parent != null) {
        // Check if user has Premium+ for multimedia moderation
        final subscriptionService = SubscriptionService();
        final premiumStatus = await subscriptionService.checkPremiumStatus();

        if (premiumStatus.tier == SubscriptionTier.premiumPlus) {
          // Run multimedia moderation on the uploaded image
          ReleaseLogger.log(
            'Moderating profile photo for Premium+ user',
            tag: 'EditProfile',
          );

          try {
            final moderationService = MultimediaModerationService();
            final result = await moderationService.moderateImage(
              imageUrl: imageUrl,
            );

            if (result.flagged) {
              ReleaseLogger.log(
                'Profile photo blocked: ${result.reason}',
                tag: 'EditProfile',
              );
              // Note: The uploaded image remains in storage but won't be linked to profile
              // Consider implementing cleanup later
              throw Exception(
                'Imagen bloqueada: ${result.reason.isNotEmpty ? result.reason : "Contenido inapropiado detectado"}',
              );
            }

            ReleaseLogger.log(
              'Profile photo approved (severity: ${result.severity})',
              tag: 'EditProfile',
            );
          } catch (e) {
            // If moderation fails but it's not a blocking error, allow upload
            if (e.toString().contains('Imagen bloqueada')) {
              rethrow;
            }
            ReleaseLogger.error(
              'Moderation error (allowing upload): $e',
              tag: 'EditProfile',
            );
          }
        }

        await _parent!.updatePhotoURL(imageUrl);
        return imageUrl;
      }

      return null;
    } catch (e) {
      ReleaseLogger.error('Error subiendo foto de perfil: $e', tag: 'EditProfile');
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
    return User.calculateAge(birthDate) ?? 0;
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

      // Normalizar fecha a UTC mediodía (12:00) para evitar problemas de timezone
      // Solo nos importa año-mes-día, no la hora
      final normalizedDate = DateTime.utc(
        birthDate.year,
        birthDate.month,
        birthDate.day,
        12, // Mediodía UTC evita problemas de cambio de día
      );

      // Llamar a Cloud Function para actualizar perfil y rol
      // La función calcula automáticamente el rol correcto basado en edad y vínculos
      final callable = FirebaseFunctions.instance.httpsCallable('updateUserProfile');
      final result = await callable.call<Map<String, dynamic>>({
        'name': name,
        'phone': phone,
        'birthDate': normalizedDate.toIso8601String(),
      });

      final response = result.data;
      final success = response['success'] as bool? ?? false;
      final newRole = response['role'] as String?;
      final age = response['age'] as int?;

      if (success) {
        ReleaseLogger.log('Perfil actualizado con rol: $newRole (edad: $age)', tag: 'EditProfile');
      } else {
        throw Exception('Error al actualizar perfil');
      }
    } catch (e) {
      ReleaseLogger.error('Error guardando perfil: $e', tag: 'EditProfile');
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
