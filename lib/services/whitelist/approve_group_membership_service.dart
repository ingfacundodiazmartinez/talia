import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Aprobar solicitud de membresía de grupo V2
///
/// Responsabilidad única: Actualizar grupo y solicitud para aprobar membresía
/// ✅ Optimizado: Escritura directa sin Cloud Function (rules ya lo permiten)
class ApproveGroupMembershipService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  ApproveGroupMembershipService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Aprobar solicitud de membresía de grupo
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String requestId,
    required String groupId,
    required String childId,
  }) async {
    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      ReleaseLogger.log(
        'Aprobando membresía de grupo: requestId=$requestId, groupId=$groupId',
        tag: 'ApproveGroupMembership',
      );

      // 1. Verificar y obtener la solicitud
      final requestRef = _firestore.collection('group_approval_requests').doc(requestId);
      final requestDoc = await requestRef.get();

      if (!requestDoc.exists) {
        return (success: false, message: 'Solicitud no encontrada');
      }

      final requestData = requestDoc.data()!;

      // 2. Verificar que el caller es el padre
      if (requestData['parentId'] != parentId) {
        return (success: false, message: 'No tienes permiso para aprobar esta solicitud');
      }

      // 3. Verificar que no esté procesada
      if (requestData['status'] != 'pending') {
        return (success: false, message: 'Esta solicitud ya fue procesada');
      }

      // 4. Verificar que no esté expirada
      final expiresAt = (requestData['expiresAt'] as Timestamp?)?.toDate();
      if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
        return (success: false, message: 'La solicitud ha expirado');
      }

      // 5. Obtener datos del hijo para memberDetails
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childData = childDoc.data() ?? {};
      final childName = childData['displayName'] as String? ??
                        childData['name'] as String? ??
                        'Usuario';
      final childPhotoUrl = childData['photoURL'] as String? ??
                           childData['avatar'] as String?;

      // 6. Obtener grupo
      final groupRef = _firestore.collection('groups_v2').doc(groupId);
      final groupDoc = await groupRef.get();

      if (!groupDoc.exists) {
        return (success: false, message: 'Grupo no encontrado');
      }

      final now = FieldValue.serverTimestamp();

      // 7. Actualizar grupo: agregar miembro, remover de pendientes
      await groupRef.update({
        'members': FieldValue.arrayUnion([childId]),
        'memberDetails.$childId': {
          'name': childName,
          'photoUrl': childPhotoUrl,
          'joinedAt': now,
          'role': 'member',
        },
        'memberCount': FieldValue.increment(1),
        'pendingMembers': FieldValue.arrayRemove([childId]),
        'updatedAt': now,
      });

      // 8. Actualizar solicitud a aprobada
      await requestRef.update({
        'status': 'approved',
        'respondedAt': now,
        'respondedBy': parentId,
      });

      ReleaseLogger.log(
        'Membresía de grupo aprobada exitosamente',
        tag: 'ApproveGroupMembership',
      );

      return (success: true, message: 'Membresía aprobada');
    } catch (e) {
      ReleaseLogger.error(
        'Error aprobando membresía de grupo: $e',
        tag: 'ApproveGroupMembership',
      );

      if (e.toString().contains('PERMISSION_DENIED')) {
        return (success: false, message: 'No tienes permiso para realizar esta acción');
      }

      return (success: false, message: 'Error al aprobar membresía');
    }
  }
}
