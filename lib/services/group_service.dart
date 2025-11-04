import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';

/// Servicio para operaciones de grupos
///
/// Responsabilidades:
/// - CRUD operations para grupos
/// - Gestión de miembros
/// - Configuración de grupos
/// - Integración con Firestore
class GroupService {
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  GroupService({
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  /// Obtener información de un grupo
  Future<Map<String, dynamic>?> getGroup(String groupId) async {
    try {
      final doc = await _firestore.collection('groups').doc(groupId).get();
      if (doc.exists) {
        return {'id': doc.id, ...doc.data()!};
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error getting group: $e', tag: 'GroupService');
      rethrow;
    }
  }

  /// Stream de un grupo
  Stream<DocumentSnapshot> getGroupStream(String groupId) {
    return _firestore.collection('groups').doc(groupId).snapshots();
  }

  /// Crear un nuevo grupo
  Future<String> createGroup({
    required String name,
    String? description,
    String? photoURL,
    required List<String> memberIds,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw 'Usuario no autenticado';

      final groupData = {
        'name': name,
        'description': description ?? '',
        'photoURL': photoURL,
        'members': [currentUserId, ...memberIds],
        'admins': [currentUserId],
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': currentUserId,
      };

      final docRef = await _firestore.collection('groups').add(groupData);
      return docRef.id;
    } catch (e) {
      ReleaseLogger.error('Error creating group: $e', tag: 'GroupService');
      rethrow;
    }
  }

  /// Actualizar información del grupo
  Future<void> updateGroup(String groupId, Map<String, dynamic> updates) async {
    try {
      updates['updatedAt'] = FieldValue.serverTimestamp();
      await _firestore.collection('groups').doc(groupId).update(updates);
    } catch (e) {
      ReleaseLogger.error('Error updating group: $e', tag: 'GroupService');
      rethrow;
    }
  }

  /// Agregar miembro al grupo
  Future<void> addMember(String groupId, String userId) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayUnion([userId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error('Error adding member: $e', tag: 'GroupService');
      rethrow;
    }
  }

  /// Remover miembro del grupo
  Future<void> removeMember(String groupId, String userId) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([userId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error('Error removing member: $e', tag: 'GroupService');
      rethrow;
    }
  }

  /// Obtener grupos del usuario actual
  Future<List<Map<String, dynamic>>> getUserGroups() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return [];

      final snapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: currentUserId)
          .get();

      return snapshot.docs.map((doc) => {
        'id': doc.id,
        ...doc.data(),
      }).toList();
    } catch (e) {
      ReleaseLogger.error('Error getting user groups: $e', tag: 'GroupService');
      rethrow;
    }
  }

  /// Eliminar grupo (solo admins)
  Future<void> deleteGroup(String groupId) async {
    try {
      await _firestore.collection('groups').doc(groupId).delete();
    } catch (e) {
      ReleaseLogger.error('Error deleting group: $e', tag: 'GroupService');
      rethrow;
    }
  }
}