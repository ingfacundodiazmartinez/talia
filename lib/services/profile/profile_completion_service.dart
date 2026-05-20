import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../device_management_service.dart';
import '../user_role_service.dart';
import '../../notification_service.dart';
import '../../utils/release_logger.dart';

class ProfileCompletionResult {
  final bool success;
  final String? error;
  final String? role;

  ProfileCompletionResult({
    required this.success,
    this.error,
    this.role,
  });
}

class ProfileCompletionService {
  final DeviceManagementService _deviceService = DeviceManagementService();
  final UserRoleService _roleService = UserRoleService();

  /// Obtiene el timezone del dispositivo en formato IANA (ej: "America/Argentina/Buenos_Aires")
  String _getDeviceTimezone() {
    final offset = DateTime.now().timeZoneOffset;
    final hours = offset.inHours;

    // Mapeo de offsets comunes a timezones IANA
    // Prioriza Latinoamérica ya que es el mercado principal
    final timezoneMap = {
      -3: 'America/Argentina/Buenos_Aires', // Argentina, Brasil (algunos)
      -4: 'America/Santiago',               // Chile, Paraguay, Venezuela
      -5: 'America/Lima',                   // Perú, Colombia, Ecuador, Panamá
      -6: 'America/Mexico_City',            // México (centro)
      -7: 'America/Tijuana',                // México (noroeste)
      -2: 'America/Sao_Paulo',              // Brasil (verano)
      0: 'Europe/London',                   // UK
      1: 'Europe/Madrid',                   // España
      2: 'Europe/Paris',                    // Francia (verano)
    };

    return timezoneMap[hours] ?? 'America/Argentina/Buenos_Aires';
  }

  /// Obtiene el offset del timezone en horas
  int _getTimezoneOffsetHours() {
    return DateTime.now().timeZoneOffset.inHours;
  }

  // Calculate age from birth date
  int calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  // Upload profile image to Firebase Storage
  Future<String?> uploadProfileImage(File profileImage, String userId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        return null;
      }

      // Force reload authentication token
      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser == null) {
        return null;
      }

      // Get ID token to ensure Storage has access
      await refreshedUser.getIdToken(true);

      // Give time for Storage SDK to update its token cache
      await Future.delayed(Duration(milliseconds: 500));

      // Create unique reference for the image
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('$userId.jpg');


      // Upload the image
      final uploadTask = storageRef.putFile(profileImage);
      final snapshot = await uploadTask;

      // Get download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      return null;
    }
  }

  // Check if phone number already exists
  // ✅ FIX: Usa Cloud Function para evitar error de permisos con queries de usuarios
  Future<bool> isPhoneNumberDuplicate(String phoneNumber, String currentUserId) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('checkPhoneDuplicate');
      final result = await callable.call<Map<String, dynamic>>({
        'phoneNumber': phoneNumber,
      });

      final response = result.data;
      final success = response['success'] as bool? ?? false;

      if (!success) {
        ReleaseLogger.error('Error verificando teléfono duplicado', tag: 'ProfileCompletion');
        return false; // Asumir que no hay duplicado en caso de error
      }

      return response['isDuplicate'] as bool? ?? false;
    } catch (e) {
      ReleaseLogger.error('Error llamando checkPhoneDuplicate: $e', tag: 'ProfileCompletion');
      // En caso de error, permitir continuar (la validación de duplicados no es crítica)
      return false;
    }
  }

  // Complete user profile
  Future<ProfileCompletionResult> completeProfile({
    required String userId,
    required String name,
    required DateTime birthDate,
    required String phoneNumber,
    File? profileImage,
    String? existingPhotoURL,
    bool isEditMode = false,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        return ProfileCompletionResult(
          success: false,
          error: 'Usuario no autenticado',
        );
      }

      // Check for duplicate phone number
      if (!isEditMode) {
        final isDuplicate = await isPhoneNumberDuplicate(phoneNumber, userId);
        if (isDuplicate) {
          return ProfileCompletionResult(
            success: false,
            error: 'Este número de teléfono ya está registrado en otra cuenta',
          );
        }
      }

      // Update display name in Firebase Auth
      await user.updateDisplayName(name);

      // Upload profile image if provided
      String? profileImageUrl;
      if (profileImage != null) {
        profileImageUrl = await uploadProfileImage(profileImage, userId);
      } else if (existingPhotoURL != null) {
        profileImageUrl = existingPhotoURL;
      }

      // Calculate age and determine role
      final age = calculateAge(birthDate);

      final role = await _roleService.determineUserRole(userId, age);

      // Check if user already exists
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      final exists = userDoc.exists;
      final userData = userDoc.data();
      final hasAnyData = userData != null && userData.isNotEmpty;

      if (hasAnyData) {
      }

      if (exists && hasAnyData) {
        // Update existing user using Cloud Function (has admin permissions to update 'role')
        try {
          // Primero actualizar la foto de perfil si existe
          if (profileImageUrl != null) {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({
              'photoURL': profileImageUrl,
            }, SetOptions(merge: true));
          }

          // Normalizar fecha a UTC mediodía para evitar problemas de timezone
          final normalizedDate = DateTime.utc(
            birthDate.year,
            birthDate.month,
            birthDate.day,
            12, // Mediodía UTC
          );

          // Luego usar Cloud Function para actualizar nombre, teléfono, fecha de nacimiento y role
          final callable = FirebaseFunctions.instance.httpsCallable('updateUserProfile');
          final result = await callable.call<Map<String, dynamic>>({
            'name': name,
            'phone': phoneNumber,
            'birthDate': normalizedDate.toIso8601String(),
          });

          final response = result.data;
          final success = response['success'] as bool? ?? false;

          if (success) {
          } else {
            throw Exception('Cloud Function retornó success=false');
          }
        } catch (e) {
          rethrow;
        }
      } else {
        // Create new user
        try {
          // Normalizar fecha a UTC mediodía para evitar problemas de timezone
          final normalizedDate = DateTime.utc(
            birthDate.year,
            birthDate.month,
            birthDate.day,
            12, // Mediodía UTC
          );

          await FirebaseFirestore.instance.collection('users').doc(userId).set({
            'name': name,
            'birthDate': Timestamp.fromDate(normalizedDate),
            'phone': phoneNumber,
            'phoneVerified': true,
            'photoURL': profileImageUrl,
            'role': role,
            'createdAt': FieldValue.serverTimestamp(),
            'isOnline': true,
            'lastSeen': FieldValue.serverTimestamp(),
            // Timezone para mensajes de Talia en horario apropiado
            'timezone': _getDeviceTimezone(),
            'timezoneOffset': _getTimezoneOffsetHours(),
          });
        } catch (e) {
          rethrow;
        }
      }

      // Register user device
      await _registerUserDevice(userId);

      // ✅ FIX: Inicializar FCM token ahora que el usuario ya existe en Firestore
      await _initializeFCMToken();

      // Obtener el rol final del usuario (puede haber sido actualizado por Cloud Function)
      final finalUserDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final finalRole = finalUserDoc.data()?['role'] as String? ?? role;


      return ProfileCompletionResult(
        success: true,
        role: finalRole,
      );
    } catch (e) {
      return ProfileCompletionResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Complete profile with minimal data (skip flow)
  Future<ProfileCompletionResult> completeProfileWithDefaults({
    required String userId,
    required String phoneNumber,
    File? profileImage,
    bool isEditMode = false,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        return ProfileCompletionResult(
          success: false,
          error: 'Usuario no autenticado',
        );
      }

      // Check if user already exists
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      final bool documentExists = userDoc.exists;
      final userData = userDoc.data();

      // If user has complete data, just register device and continue
      if (documentExists && userData?['name'] != null && userData?['createdAt'] != null) {
        final role = userData?['role'] ?? 'child';
        await _registerUserDevice(userId);
        return ProfileCompletionResult(
          success: true,
          role: role,
        );
      }

      // Check for duplicate phone number
      if (!isEditMode) {
        final isDuplicate = await isPhoneNumberDuplicate(phoneNumber, userId);
        if (isDuplicate) {
          return ProfileCompletionResult(
            success: false,
            error: 'Este número de teléfono ya está registrado en otra cuenta',
          );
        }
      }

      // Upload image if exists
      String? profileImageUrl;
      if (profileImage != null) {
        profileImageUrl = await uploadProfileImage(profileImage, userId);
      }

      // Default birth date: 30 years ago
      final defaultBirthDate = DateTime.now().subtract(Duration(days: 30 * 365));
      const defaultAge = 30;

      if (documentExists) {
        // Document exists but is incomplete - use UPDATE to avoid touching 'role' field
        final existingRole = userData?['role'] ?? 'child';

        await FirebaseFirestore.instance.collection('users').doc(userId).update({
          'name': 'Usuario',
          'birthDate': Timestamp.fromDate(defaultBirthDate),
          'phone': phoneNumber,
          'phoneVerified': true,
          'photoURL': profileImageUrl,
          'createdAt': FieldValue.serverTimestamp(),
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
          // Timezone para mensajes de Talia en horario apropiado
          'timezone': _getDeviceTimezone(),
          'timezoneOffset': _getTimezoneOffsetHours(),
        });

        await _registerUserDevice(userId);
        await _initializeFCMToken();
        return ProfileCompletionResult(
          success: true,
          role: existingRole,
        );
      } else {
        // Document doesn't exist - use SET to create it with role
        final role = await _roleService.determineUserRole(userId, defaultAge);

        await FirebaseFirestore.instance.collection('users').doc(userId).set({
          'name': 'Usuario',
          'birthDate': Timestamp.fromDate(defaultBirthDate),
          'phone': phoneNumber,
          'phoneVerified': true,
          'photoURL': profileImageUrl,
          'role': role,
          'createdAt': FieldValue.serverTimestamp(),
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
          // Timezone para mensajes de Talia en horario apropiado
          'timezone': _getDeviceTimezone(),
          'timezoneOffset': _getTimezoneOffsetHours(),
        });

        await _registerUserDevice(userId);
        await _initializeFCMToken();
        return ProfileCompletionResult(
          success: true,
          role: role,
        );
      }
    } catch (e) {
      return ProfileCompletionResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Load existing user data
  Future<Map<String, dynamic>?> loadExistingUserData(String userId) async {
    try {

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();


      if (doc.exists) {
        final data = doc.data();

        if (data != null) {

          DateTime? birthDate;
          if (data['birthDate'] != null) {
            DateTime? parsedDate;
            if (data['birthDate'] is Timestamp) {
              parsedDate = (data['birthDate'] as Timestamp).toDate();
            } else if (data['birthDate'] is String) {
              parsedDate = DateTime.tryParse(data['birthDate']);
            }

            // Normalizar a fecha local sin hora para mostrar correctamente
            if (parsedDate != null) {
              birthDate = DateTime(
                parsedDate.year,
                parsedDate.month,
                parsedDate.day,
              );
            }
          }

          return {
            'name': data['name'] ?? '',
            'birthDate': birthDate,
            'photoURL': data['photoURL'],
          };
        } else {
        }
      } else {
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // Register device for user
  Future<void> _registerUserDevice(String userId) async {
    try {
      final result = await _deviceService.registerDeviceForUser(userId);
      if (!result.isSuccess) {
        // Device registration failed but profile completion should continue
      }
    } catch (_) {
      // Silently ignored - device registration errors should not block profile completion
    }
  }

  /// Inicializar FCM token después de que el usuario ya existe en Firestore
  /// Esto es necesario porque initializeFCMTokenAfterLogin se ejecutó antes
  /// de que existiera el documento del usuario
  Future<void> _initializeFCMToken() async {
    try {
      await NotificationService().initializeFCMTokenAfterLogin();
      ReleaseLogger.log('✅ FCM token inicializado después de completar perfil', tag: 'ProfileCompletionService');
    } catch (e) {
      ReleaseLogger.log('⚠️ Error inicializando FCM token: $e', tag: 'ProfileCompletionService');
      // No bloquear el flujo si falla
    }
  }

  /// Verifica si existe un usuario con el teléfono dado y retorna sus datos.
  /// Útil para detectar usuarios existentes que vuelven a autenticarse.
  ///
  /// ✅ FIX: Usa Cloud Function para evitar error de permisos.
  /// Las Firestore rules no permiten queries sobre usuarios a usuarios
  /// recién autenticados sin relaciones existentes.
  ///
  /// Retorna:
  /// - ExistingUserResult con los datos si existe un usuario con ese teléfono
  /// - null si no existe ningún usuario con ese teléfono
  Future<ExistingUserResult?> checkExistingUserByPhone(String phoneNumber, String currentAuthUid) async {
    try {
      ReleaseLogger.log('🔍 Verificando usuario existente con teléfono: ${_redactPhone(phoneNumber)}', tag: 'ProfileCompletionService');

      final callable = FirebaseFunctions.instance.httpsCallable('checkExistingUserByPhone');
      final result = await callable.call<Map<String, dynamic>>({
        'phoneNumber': phoneNumber,
      });

      final response = result.data;
      final success = response['success'] as bool? ?? false;

      if (!success) {
        ReleaseLogger.error('Error en Cloud Function checkExistingUserByPhone', tag: 'ProfileCompletionService');
        return null;
      }

      final exists = response['exists'] as bool? ?? false;

      if (!exists) {
        ReleaseLogger.log('ℹ️ No existe usuario con este teléfono', tag: 'ProfileCompletionService');
        return null;
      }

      final userId = response['userId'] as String? ?? '';
      final role = response['role'] as String? ?? 'child';
      final hasCompleteProfile = response['hasCompleteProfile'] as bool? ?? false;
      final isSameUid = response['isSameUid'] as bool? ?? false;

      if (isSameUid) {
        ReleaseLogger.log('✅ Documento encontrado para UID actual, perfil completo: $hasCompleteProfile', tag: 'ProfileCompletionService');
      } else {
        ReleaseLogger.log('⚠️ Usuario encontrado con diferente UID. Doc ID: $userId, Auth UID: $currentAuthUid', tag: 'ProfileCompletionService');
      }

      return ExistingUserResult(
        exists: true,
        userId: userId,
        role: role,
        hasCompleteProfile: hasCompleteProfile,
        isSameUid: isSameUid,
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error verificando usuario existente: $e', tag: 'ProfileCompletionService');
      return null;
    }
  }

  /// Migra los datos de un usuario existente al nuevo UID de autenticación.
  /// Esto es necesario cuando Firebase Auth crea un nuevo UID para el mismo teléfono.
  Future<ProfileCompletionResult> migrateUserToNewUid({
    required String oldUserId,
    required String newUserId,
    required String phoneNumber,
  }) async {
    try {
      ReleaseLogger.log('🔄 Migrando usuario de $oldUserId a $newUserId', tag: 'ProfileCompletionService');

      // Obtener datos del documento antiguo
      final oldDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(oldUserId)
          .get();

      if (!oldDoc.exists) {
        return ProfileCompletionResult(
          success: false,
          error: 'Usuario original no encontrado',
        );
      }

      final oldData = oldDoc.data()!;
      final role = oldData['role'] ?? 'child';

      // Crear nuevo documento con el nuevo UID manteniendo los datos
      await FirebaseFirestore.instance.collection('users').doc(newUserId).set({
        ...oldData,
        'migratedFrom': oldUserId,
        'migratedAt': FieldValue.serverTimestamp(),
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        // Actualizar timezone con el dispositivo actual
        'timezone': _getDeviceTimezone(),
        'timezoneOffset': _getTimezoneOffsetHours(),
      });

      // Marcar el documento antiguo como migrado (no eliminarlo para mantener referencias)
      await FirebaseFirestore.instance.collection('users').doc(oldUserId).update({
        'migratedTo': newUserId,
        'migratedAt': FieldValue.serverTimestamp(),
        'isOnline': false,
      });

      // Registrar dispositivo y FCM token
      await _registerUserDevice(newUserId);
      await _initializeFCMToken();

      ReleaseLogger.log('✅ Usuario migrado exitosamente', tag: 'ProfileCompletionService');

      return ProfileCompletionResult(
        success: true,
        role: role,
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error migrando usuario: $e', tag: 'ProfileCompletionService');
      return ProfileCompletionResult(
        success: false,
        error: 'Error migrando cuenta: $e',
      );
    }
  }

  String _redactPhone(String phone) {
    if (phone.length < 6) return '***';
    return '${phone.substring(0, 3)}***${phone.substring(phone.length - 2)}';
  }

  /// Actualiza el timezone del usuario si cambió (ej: viajó a otro país)
  /// Llamar periódicamente al abrir la app
  Future<void> updateUserTimezoneIfNeeded(String userId) async {
    try {
      final currentTimezone = _getDeviceTimezone();
      final currentOffset = _getTimezoneOffsetHours();

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (!userDoc.exists) return;

      final storedTimezone = userDoc.data()?['timezone'] as String?;
      final storedOffset = userDoc.data()?['timezoneOffset'] as int?;

      // Solo actualizar si cambió el offset (significa que el usuario cambió de zona)
      if (storedOffset != currentOffset) {
        await FirebaseFirestore.instance.collection('users').doc(userId).update({
          'timezone': currentTimezone,
          'timezoneOffset': currentOffset,
          'timezoneUpdatedAt': FieldValue.serverTimestamp(),
        });
        ReleaseLogger.log(
          '🌍 Timezone actualizado: $storedTimezone → $currentTimezone',
          tag: 'ProfileCompletionService',
        );
      }
    } catch (e) {
      // No bloquear el flujo si falla
      ReleaseLogger.error('Error actualizando timezone: $e', tag: 'ProfileCompletionService');
    }
  }
}

/// Resultado de verificación de usuario existente
class ExistingUserResult {
  final bool exists;
  final String userId;
  final String role;
  final bool hasCompleteProfile;
  final bool isSameUid;

  ExistingUserResult({
    required this.exists,
    required this.userId,
    required this.role,
    required this.hasCompleteProfile,
    required this.isSameUid,
  });
}
