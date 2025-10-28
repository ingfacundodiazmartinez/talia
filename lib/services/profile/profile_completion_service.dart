import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../device_management_service.dart';
import '../user_role_service.dart';

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
        print('❌ Usuario no autenticado al intentar subir imagen');
        return null;
      }

      // Force reload authentication token
      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser == null) {
        print('❌ Usuario no disponible después de reload');
        return null;
      }

      // Get ID token to ensure Storage has access
      final idToken = await refreshedUser.getIdToken(true);
      print('🔑 ID Token obtenido: ${idToken?.substring(0, 20)}...');

      // Give time for Storage SDK to update its token cache
      await Future.delayed(Duration(milliseconds: 500));
      print('⏱️ Esperando propagación del token al SDK de Storage...');

      // Create unique reference for the image
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('$userId.jpg');

      print('📁 Subiendo a: profile_images/$userId.jpg');

      // Upload the image
      final uploadTask = storageRef.putFile(profileImage);
      final snapshot = await uploadTask;

      // Get download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();
      print('📸 Imagen subida exitosamente: $downloadUrl');

      return downloadUrl;
    } catch (e) {
      print('❌ Error subiendo imagen: $e');
      return null;
    }
  }

  // Check if phone number already exists
  Future<bool> isPhoneNumberDuplicate(String phoneNumber, String currentUserId) async {
    final existingUsers = await FirebaseFirestore.instance
        .collection('users')
        .where('phone', isEqualTo: phoneNumber)
        .get();

    if (existingUsers.docs.isNotEmpty) {
      return existingUsers.docs.any((doc) => doc.id != currentUserId);
    }
    return false;
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
        print('📤 Iniciando subida de imagen...');
        profileImageUrl = await uploadProfileImage(profileImage, userId);
        print('📸 URL de imagen obtenida: $profileImageUrl');
      } else if (existingPhotoURL != null) {
        profileImageUrl = existingPhotoURL;
        print('🔄 Usando foto existente: $profileImageUrl');
      }

      // Calculate age and determine role
      final age = calculateAge(birthDate);
      print('📊 [CompleteProfile] Edad calculada: $age');

      final role = await _roleService.determineUserRole(userId, age);
      print('👤 [CompleteProfile] Rol determinado: $role');

      // Check if user already exists
      print('🔍 [CompleteProfile] Verificando si usuario existe en Firestore...');
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      final exists = userDoc.exists;
      final userData = userDoc.data();
      final hasAnyData = userData != null && userData.isNotEmpty;
      print('📄 [CompleteProfile] Documento existe: $exists, tiene datos: $hasAnyData');

      if (hasAnyData) {
        print('   Datos actuales: name=${userData!['name']}, role=${userData['role']}, createdAt=${userData['createdAt']}');
      }

      if (exists && hasAnyData) {
        // Update existing user using Cloud Function (has admin permissions to update 'role')
        print('📝 [CompleteProfile] Actualizando usuario existente via Cloud Function...');
        try {
          // Primero actualizar la foto de perfil si existe
          if (profileImageUrl != null) {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({
              'photoURL': profileImageUrl,
            }, SetOptions(merge: true));
            print('✅ [CompleteProfile] Foto de perfil actualizada');
          }

          // Luego usar Cloud Function para actualizar nombre, teléfono, fecha de nacimiento y role
          final callable = FirebaseFunctions.instance.httpsCallable('updateUserProfile');
          final result = await callable.call<Map<String, dynamic>>({
            'name': name,
            'phone': phoneNumber,
            'birthDate': birthDate.toIso8601String(),
          });

          final response = result.data;
          final success = response['success'] as bool? ?? false;
          final newRole = response['role'] as String?;

          if (success) {
            print('✅ [CompleteProfile] Usuario actualizado exitosamente via Cloud Function con rol: $newRole');
          } else {
            throw Exception('Cloud Function retornó success=false');
          }
        } catch (e) {
          print('❌ [CompleteProfile] Error al actualizar usuario: $e');
          rethrow;
        }
      } else {
        // Create new user
        print('📝 [CompleteProfile] Creando nuevo usuario con todos los campos...');
        try {
          await FirebaseFirestore.instance.collection('users').doc(userId).set({
            'name': name,
            'birthDate': Timestamp.fromDate(birthDate),
            'phone': phoneNumber,
            'phoneVerified': true,
            'photoURL': profileImageUrl,
            'role': role,
            'createdAt': FieldValue.serverTimestamp(),
            'isOnline': true,
            'lastSeen': FieldValue.serverTimestamp(),
          });
          print('✅ [CompleteProfile] Usuario creado exitosamente');
        } catch (e) {
          print('❌ [CompleteProfile] Error al crear usuario: $e');
          rethrow;
        }
      }

      // Register user device
      await _registerUserDevice(userId);

      // Obtener el rol final del usuario (puede haber sido actualizado por Cloud Function)
      final finalUserDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final finalRole = finalUserDoc.data()?['role'] as String? ?? role;

      print('✅ Perfil completado exitosamente con rol final: $finalRole');

      return ProfileCompletionResult(
        success: true,
        role: finalRole,
      );
    } catch (e) {
      print('❌ Error completando perfil: $e');
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
        print('📝 Actualizando documento existente (role: $existingRole) sin modificar campo "role"');

        await FirebaseFirestore.instance.collection('users').doc(userId).update({
          'name': 'Usuario',
          'birthDate': Timestamp.fromDate(defaultBirthDate),
          'phone': phoneNumber,
          'phoneVerified': true,
          'photoURL': profileImageUrl,
          'createdAt': FieldValue.serverTimestamp(),
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
        });

        await _registerUserDevice(userId);
        return ProfileCompletionResult(
          success: true,
          role: existingRole,
        );
      } else {
        // Document doesn't exist - use SET to create it with role
        final role = await _roleService.determineUserRole(userId, defaultAge);
        print('📝 Creando nuevo documento con role: $role');

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
        });

        await _registerUserDevice(userId);
        return ProfileCompletionResult(
          success: true,
          role: role,
        );
      }
    } catch (e) {
      print('❌ Error en skip: $e');
      return ProfileCompletionResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Load existing user data
  Future<Map<String, dynamic>?> loadExistingUserData(String userId) async {
    try {
      print('🔍 [ProfileService] Consultando Firestore para userId: $userId');

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      print('📄 [ProfileService] Documento obtenido: exists=${doc.exists}');

      if (doc.exists) {
        final data = doc.data();
        print('📊 [ProfileService] Data del documento: ${data != null ? "Sí tiene data" : "Data es null"}');

        if (data != null) {
          print('   - name: ${data['name']}');
          print('   - birthDate: ${data['birthDate']}');
          print('   - photoURL: ${data['photoURL'] != null ? "presente" : "ausente"}');
          print('   - role: ${data['role']}');
          print('   - createdAt: ${data['createdAt']}');

          DateTime? birthDate;
          if (data['birthDate'] != null) {
            if (data['birthDate'] is Timestamp) {
              birthDate = (data['birthDate'] as Timestamp).toDate();
            } else if (data['birthDate'] is String) {
              birthDate = DateTime.tryParse(data['birthDate']);
            }
          }

          return {
            'name': data['name'] ?? '',
            'birthDate': birthDate,
            'photoURL': data['photoURL'],
          };
        } else {
          print('⚠️ [ProfileService] Documento existe pero data() es null');
        }
      } else {
        print('❌ [ProfileService] Documento NO existe en Firestore');
      }
      return null;
    } catch (e, stackTrace) {
      print('❌ [ProfileService] Error loading existing user data: $e');
      print('   Stack trace: $stackTrace');
      return null;
    }
  }

  // Register device for user
  Future<void> _registerUserDevice(String userId) async {
    try {
      final result = await _deviceService.registerDeviceForUser(userId);
      if (!result.isSuccess) {
        print('⚠️ Advertencia registrando dispositivo: ${result.error}');
      }
    } catch (e) {
      print('❌ Error registrando dispositivo: $e');
    }
  }
}
