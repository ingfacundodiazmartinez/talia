import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math';

class UserCodeService {
  static final UserCodeService _instance = UserCodeService._internal();
  factory UserCodeService() => _instance;
  UserCodeService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Generar un código único para un usuario
  Future<String> generateUserCode(String userId) async {
    try {
      String code;
      bool isUnique = false;
      int attempts = 0;

      // Intentar hasta 5 veces generar un código único
      while (!isUnique && attempts < 5) {
        code = _generateRandomCode();

        // Verificar si el código ya existe
        final existingCode = await _firestore
            .collection('user_codes')
            .where('code', isEqualTo: code)
            .limit(1)
            .get();

        if (existingCode.docs.isEmpty) {
          // Código único encontrado, guardarlo
          await _firestore.collection('user_codes').doc(userId).set({
            'code': code,
            'userId': userId,
            'createdAt': FieldValue.serverTimestamp(),
            'isActive': true,
          });

          print('✅ Código único generado para usuario $userId: $code');
          return code;
        }

        attempts++;
      }

      throw Exception('No se pudo generar un código único después de 5 intentos');
    } catch (e) {
      print('❌ Error generando código de usuario: $e');
      rethrow;
    }
  }

  /// Obtener el código de un usuario (generar si no existe)
  Future<String> getUserCode(String userId) async {
    try {
      // Verificar si ya tiene un código
      final codeDoc = await _firestore.collection('user_codes').doc(userId).get();

      if (codeDoc.exists && codeDoc.data()?['isActive'] == true) {
        return codeDoc.data()!['code'];
      }

      // Si no tiene código o está inactivo, generar uno nuevo
      return await generateUserCode(userId);
    } catch (e) {
      print('❌ Error obteniendo código de usuario: $e');
      rethrow;
    }
  }

  /// Buscar usuario por código
  Future<UserCodeResult> findUserByCode(String code) async {
    try {
      print('🔍 Buscando usuario con código: $code');

      final codeQuery = await _firestore
          .collection('user_codes')
          .where('code', isEqualTo: code.toUpperCase())
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (codeQuery.docs.isEmpty) {
        return UserCodeResult.notFound();
      }

      final codeData = codeQuery.docs.first.data();
      final userId = codeData['userId'];

      // Obtener información del usuario
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) {
        return UserCodeResult.userNotFound();
      }

      final userData = userDoc.data()!;

      return UserCodeResult.found(
        userId: userId,
        name: userData['name'] ?? 'Usuario',
        email: userData['email'] ?? '',
        photoURL: userData['photoURL'],
        isParent: userData['isParent'] ?? false,
      );
    } catch (e) {
      print('❌ Error buscando usuario por código: $e');
      return UserCodeResult.error(e.toString());
    }
  }

  /// Regenerar código de usuario
  Future<String> regenerateUserCode(String userId) async {
    try {
      // Desactivar código actual
      await _firestore.collection('user_codes').doc(userId).update({
        'isActive': false,
        'deactivatedAt': FieldValue.serverTimestamp(),
      });

      // Generar nuevo código
      return await generateUserCode(userId);
    } catch (e) {
      print('❌ Error regenerando código: $e');
      rethrow;
    }
  }

  /// Obtener código del usuario actual
  Future<String> getCurrentUserCode() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) throw Exception('Usuario no autenticado');

    return await getUserCode(userId);
  }

  /// Generar código aleatorio (formato: TALIA-ABC123)
  String _generateRandomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();

    final letters = List.generate(3, (index) => chars[random.nextInt(26)]).join(''); // Solo letras para las primeras 3
    final numbers = List.generate(3, (index) => chars[26 + random.nextInt(10)]).join(''); // Solo números para las últimas 3

    return 'TALIA-$letters$numbers';
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

  UserCodeResult._({
    required this.isFound,
    this.userId,
    this.name,
    this.email,
    this.photoURL,
    this.isParent,
    this.error,
  });

  factory UserCodeResult.found({
    required String userId,
    required String name,
    required String email,
    String? photoURL,
    required bool isParent,
  }) {
    return UserCodeResult._(
      isFound: true,
      userId: userId,
      name: name,
      email: email,
      photoURL: photoURL,
      isParent: isParent,
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