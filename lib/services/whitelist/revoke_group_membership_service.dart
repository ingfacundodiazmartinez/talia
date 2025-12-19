import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Revocar membresía de grupo (sacar hijo del grupo)
///
/// Responsabilidad única: Remover hijo del grupo V2
/// ✅ Optimizado: Escritura directa sin Cloud Function (rules ya lo permiten)
class RevokeGroupMembershipService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RevokeGroupMembershipService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Revocar membresía de grupo (sacar al hijo)
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String groupId,
    required String childId,
  }) async {
    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      ReleaseLogger.log(
        'Revocando membresía de grupo: groupId=$groupId, childId=$childId',
        tag: 'RevokeGroupMembership',
      );

      // 1. Verificar que el caller es padre del hijo
      final isParent = await _verifyParentRelationship(parentId, childId);
      if (!isParent) {
        return (success: false, message: 'No eres padre de este usuario');
      }

      // 2. Obtener grupo
      final groupRef = _firestore.collection('groups_v2').doc(groupId);
      final groupDoc = await groupRef.get();

      if (!groupDoc.exists) {
        return (success: false, message: 'Grupo no encontrado');
      }

      final groupData = groupDoc.data()!;
      final members = List<String>.from(groupData['members'] ?? []);

      // 3. Verificar que el hijo es miembro
      if (!members.contains(childId)) {
        return (success: false, message: 'El usuario no es miembro de este grupo');
      }

      // 4. Remover del grupo
      await groupRef.update({
        'members': FieldValue.arrayRemove([childId]),
        'memberDetails.$childId': FieldValue.delete(),
        'memberCount': FieldValue.increment(-1),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Membresía de grupo revocada exitosamente',
        tag: 'RevokeGroupMembership',
      );

      return (success: true, message: 'Membresía revocada');
    } catch (e) {
      ReleaseLogger.error(
        'Error revocando membresía de grupo: $e',
        tag: 'RevokeGroupMembership',
      );

      if (e.toString().contains('PERMISSION_DENIED')) {
        return (success: false, message: 'No tienes permiso para realizar esta acción');
      }

      return (success: false, message: 'Error al revocar membresía');
    }
  }

  /// Verificar si parentId es padre de childId usando parent_children
  Future<bool> _verifyParentRelationship(String parentId, String childId) async {
    // Verificar ambas direcciones del documento (parentId_childId o childId_parentId)
    final link1 = await _firestore
        .collection('parent_children')
        .doc('${parentId}_$childId')
        .get();

    if (link1.exists) return true;

    final link2 = await _firestore
        .collection('parent_children')
        .doc('${childId}_$parentId')
        .get();

    return link2.exists;
  }
}
