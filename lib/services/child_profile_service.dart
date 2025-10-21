import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;

/// Service que maneja la lógica de perfil para usuarios child
class ChildProfileService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;

  // Singleton pattern
  static final ChildProfileService _instance = ChildProfileService._internal();
  factory ChildProfileService() => _instance;
  ChildProfileService._internal();

  /// Stream de datos del usuario actual
  Stream<DocumentSnapshot> getUserDataStream(String userId) {
    return _firestore.collection('users').doc(userId).snapshots();
  }

  /// Obtiene datos del usuario como Map
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (!doc.exists) return null;
      return doc.data();
    } catch (e) {
      print('Error obteniendo datos de usuario: $e');
      return null;
    }
  }

  /// Stream de links padre-hijo aprobados para un child
  Stream<QuerySnapshot> getParentChildLinksStream(String childId) {
    return _firestore
        .collection('parent_children')
        .where('childId', isEqualTo: childId)
        .where('status', isEqualTo: 'approved')
        .snapshots();
  }

  /// Obtiene información de un padre por su ID
  Future<Map<String, dynamic>?> getParentData(String parentId) async {
    try {
      final doc = await _firestore.collection('users').doc(parentId).get();
      if (!doc.exists) return null;
      return doc.data() as Map<String, dynamic>?;
    } catch (e) {
      print('Error obteniendo datos de padre: $e');
      return null;
    }
  }

  /// Stream de chats del usuario
  Stream<QuerySnapshot> getChatsStream(String userId) {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .snapshots();
  }

  /// Cuenta chats no eliminados por el usuario
  int countActiveChats(QuerySnapshot chatsSnapshot, String userId) {
    return chatsSnapshot.docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final deletedBy = List<String>.from(data['deletedBy'] ?? []);
      return !deletedBy.contains(userId);
    }).length;
  }

  /// Realiza el logout del usuario
  Future<void> logout(String userId) async {
    try {
      // Actualizar estado offline y limpiar token FCM
      await _firestore.collection('users').doc(userId).update({
        'isOnline': false,
        'lastSeen': FieldValue.serverTimestamp(),
        'fcmToken': null,
      }).catchError((e) => print('Error actualizando estado: $e'));

      // Cerrar sesión
      await _auth.signOut();
    } catch (e) {
      print('Error al cerrar sesión: $e');
      rethrow;
    }
  }

  /// Verifica si un usuario es adulto
  Future<bool> isAdultUser(String userId) async {
    try {
      final userData = await getUserData(userId);
      return userData?['role'] == 'adult';
    } catch (e) {
      return false;
    }
  }

  /// Verifica si un usuario está vinculado con algún padre
  Future<bool> isLinkedToParent(String childId) async {
    try {
      final snapshot = await _firestore
          .collection('parent_children')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      return snapshot.docs.isNotEmpty;
    } catch (e) {
      print('Error verificando vinculación: $e');
      return false;
    }
  }
}
