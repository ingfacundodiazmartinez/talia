import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Repository especializado para operaciones de usuarios en Firestore
///
/// Responsabilidades:
/// - SOLO acceso a datos de usuarios (Firestore collection 'users')
/// - Queries optimizadas para usuarios
/// - NO lógica de negocio
/// - Manejo de errores de red/Firestore
class UserRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  UserRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  })  : _firestore = firestore,
        _auth = auth;

  String? get currentUserId => _auth.currentUser?.uid;

  /// Obtener usuario por ID
  Future<DocumentSnapshot?> getUser(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.exists ? doc : null;
    } catch (e) {
      throw Exception('Error obteniendo usuario: $e');
    }
  }

  /// Obtener datos del usuario como Map
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    try {
      final doc = await getUser(userId);
      return doc?.data() as Map<String, dynamic>?;
    } catch (e) {
      throw Exception('Error obteniendo datos de usuario: $e');
    }
  }

  /// Obtener usuario actual
  Future<DocumentSnapshot?> getCurrentUser() async {
    final userId = currentUserId;
    if (userId == null) return null;
    return await getUser(userId);
  }

  /// Obtener datos del usuario actual
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    final userId = currentUserId;
    if (userId == null) return null;
    return await getUserData(userId);
  }

  /// Stream de cambios en un usuario (para estado online, foto, etc)
  Stream<DocumentSnapshot> watchUser(String userId) {
    return _firestore.collection('users').doc(userId).snapshots();
  }

  /// Actualizar estado online del usuario
  Future<void> updateOnlineStatus(bool isOnline) async {
    final userId = currentUserId;
    if (userId == null) throw Exception('Usuario no autenticado');

    try {
      await _firestore.collection('users').doc(userId).update({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Error actualizando estado online: $e');
    }
  }

  /// Actualizar campos específicos del usuario
  Future<void> updateUser(String userId, Map<String, dynamic> data) async {
    try {
      await _firestore.collection('users').doc(userId).update(data);
    } catch (e) {
      throw Exception('Error actualizando usuario: $e');
    }
  }

  /// Actualizar foto de perfil
  Future<void> updatePhotoURL(String userId, String photoURL) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'photoURL': photoURL,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Error actualizando foto de perfil: $e');
    }
  }

  /// Buscar usuarios por nombre (para búsqueda de contactos)
  Future<QuerySnapshot> searchUsersByName(String query, {int limit = 20}) async {
    try {
      return await _firestore
          .collection('users')
          .where('name', isGreaterThanOrEqualTo: query)
          .where('name', isLessThan: '$query\uf8ff')
          .limit(limit)
          .get();
    } catch (e) {
      throw Exception('Error buscando usuarios: $e');
    }
  }

  /// Obtener múltiples usuarios por IDs
  Future<List<DocumentSnapshot>> getUsersByIds(List<String> userIds) async {
    if (userIds.isEmpty) return [];

    try {
      final results = <DocumentSnapshot>[];

      // Firestore solo permite 10 items en whereIn, así que dividimos en chunks
      for (int i = 0; i < userIds.length; i += 10) {
        final chunk = userIds.skip(i).take(10).toList();
        final snapshot = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        results.addAll(snapshot.docs);
      }

      return results;
    } catch (e) {
      throw Exception('Error obteniendo usuarios por IDs: $e');
    }
  }

  /// Verificar si usuario existe
  Future<bool> userExists(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.exists;
    } catch (e) {
      return false;
    }
  }
}
