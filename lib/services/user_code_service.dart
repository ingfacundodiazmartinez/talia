import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/release_logger.dart';

class UserCodeService {
  static final UserCodeService _instance = UserCodeService._internal();
  factory UserCodeService() => _instance;
  UserCodeService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Cache key prefix
  static const String _cacheKeyPrefix = 'user_code_';

  /// Generar u obtener el código de un usuario
  /// ✅ FIX: Usa Cloud Function para evitar error de permisos con queries de user_codes
  /// Retorna un record con el código y la fecha de expiración
  Future<({String code, DateTime? expiresAt})> generateUserCode(String userId) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('generateUserCode');
      final result = await callable.call<Map<String, dynamic>>({});

      final response = result.data;
      final success = response['success'] as bool? ?? false;

      if (!success) {
        throw Exception('Error generando código de usuario');
      }

      final code = response['code'] as String;
      final expiresAtMillis = response['expiresAt'] as int?;
      final expiresAt = expiresAtMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(expiresAtMillis)
          : null;

      return (code: code, expiresAt: expiresAt);
    } catch (e) {
      rethrow;
    }
  }

  /// Obtener el código de un usuario (generar si no existe)
  /// ✅ FIX: Usa Cloud Function para manejar la generación de forma segura
  /// Retorna un record con el código y la fecha de expiración
  Future<({String code, DateTime? expiresAt})> getUserCode(String userId) async {
    try {
      // 1. Intentar leer el código existente de Firestore
      final codeDoc = await _firestore.collection('user_codes').doc(userId).get();

      if (codeDoc.exists && codeDoc.data()?['isActive'] == true) {
        final data = codeDoc.data()!;
        final code = data['code'] as String;
        final expiresAtTimestamp = data['expiresAt'] as Timestamp?;

        // Verificar si el código ha expirado
        if (expiresAtTimestamp != null) {
          final expiresAt = expiresAtTimestamp.toDate();
          if (expiresAt.isAfter(DateTime.now())) {
            ReleaseLogger.log('[UserCodeService] Código válido encontrado en Firestore', tag: 'UserCode');
            return (code: code, expiresAt: expiresAt);
          }
        }
      }

      // 2. Si no tiene código o expiró, generar uno nuevo via Cloud Function
      final result = await generateUserCode(userId);
      ReleaseLogger.log('[UserCodeService] Nuevo código generado', tag: 'UserCode');
      return result;
    } catch (e) {
      ReleaseLogger.error('[UserCodeService] Error obteniendo código: $e', tag: 'UserCode');
      // Si falla la lectura directa, intentar via Cloud Function
      try {
        final result = await generateUserCode(userId);
        return result;
      } catch (e2) {
        ReleaseLogger.error('[UserCodeService] Error generando código: $e2', tag: 'UserCode');
        rethrow;
      }
    }
  }

  /// Limpiar cache de código (usado al regenerar)
  Future<void> _clearCachedCode(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_cacheKeyPrefix$userId');
    } catch (e) {
      // Ignorar errores de cache
    }
  }

  /// Buscar usuario por código
  /// 🔒 SEGURIDAD: Usa Cloud Function para prevenir enumeración de usuarios
  Future<UserCodeResult> findUserByCode(String code) async {
    try {
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('findUserByCode').call({
        'code': code,
      });

      final data = result.data as Map<String, dynamic>;

      if (data['found'] != true) {
        final error = data['error'] as String?;
        if (error != null) {
          return UserCodeResult.error(error);
        }
        return UserCodeResult.notFound();
      }

      // 🔒 SEGURIDAD: No exponer email ni photoURL por privacidad
      return UserCodeResult.found(
        userId: data['userId'] as String,
        name: data['name'] as String? ?? 'Usuario',
        email: '',
        photoURL: null,
        isParent: data['role'] == 'parent',
        alreadyContact: data['alreadyContact'] as bool? ?? false,
        pendingRequest: data['pendingRequest'] as bool? ?? false,
      );
    } catch (e) {
      return UserCodeResult.error(e.toString());
    }
  }

  /// Regenerar código de usuario
  Future<({String code, DateTime? expiresAt})> regenerateUserCode(String userId) async {
    try {
      // Limpiar cache local primero
      await _clearCachedCode(userId);

      // Desactivar código actual
      try {
        await _firestore.collection('user_codes').doc(userId).update({
          'isActive': false,
          'deactivatedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        // Ignorar si el documento no existe
      }

      // Generar nuevo código
      final result = await generateUserCode(userId);

      return result;
    } catch (e) {
      rethrow;
    }
  }

  /// Obtener código del usuario actual
  Future<({String code, DateTime? expiresAt})> getCurrentUserCode() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) throw Exception('Usuario no autenticado');

    return await getUserCode(userId);
  }

  /// Validar formato de código
  bool isValidCodeFormat(String code) {
    final regex = RegExp(r'^TALIA-[A-Z]{3}[0-9]{3}$');
    return regex.hasMatch(code.toUpperCase());
  }
}

/// Resultado de búsqueda de usuario por código
class UserCodeResult {
  final bool isFound;
  final String? userId;
  final String? name;
  final String? email;
  final String? photoURL;
  final bool? isParent;
  final String? error;
  final bool alreadyContact;
  final bool pendingRequest;

  UserCodeResult._({
    required this.isFound,
    this.userId,
    this.name,
    this.email,
    this.photoURL,
    this.isParent,
    this.error,
    this.alreadyContact = false,
    this.pendingRequest = false,
  });

  factory UserCodeResult.found({
    required String userId,
    required String name,
    required String email,
    String? photoURL,
    required bool isParent,
    bool alreadyContact = false,
    bool pendingRequest = false,
  }) {
    return UserCodeResult._(
      isFound: true,
      userId: userId,
      name: name,
      email: email,
      photoURL: photoURL,
      isParent: isParent,
      alreadyContact: alreadyContact,
      pendingRequest: pendingRequest,
    );
  }

  factory UserCodeResult.notFound() {
    return UserCodeResult._(isFound: false);
  }

  factory UserCodeResult.userNotFound() {
    return UserCodeResult._(isFound: false, error: 'Usuario no encontrado');
  }

  factory UserCodeResult.error(String error) {
    return UserCodeResult._(isFound: false, error: error);
  }

  bool get hasError => error != null;
}
