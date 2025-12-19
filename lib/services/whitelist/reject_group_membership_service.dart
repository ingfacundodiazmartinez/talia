import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Rechazar solicitud de membresía de grupo V2
///
/// Responsabilidad única: Actualizar solicitud y grupo para rechazar membresía
/// ✅ Optimizado: Escritura directa sin Cloud Function (rules ya lo permiten)
class RejectGroupMembershipService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RejectGroupMembershipService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Rechazar solicitud de membresía de grupo
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String requestId,
  }) async {
    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      ReleaseLogger.log(
        'Rechazando membresía de grupo: requestId=$requestId',
        tag: 'RejectGroupMembership',
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
        return (success: false, message: 'No tienes permiso para rechazar esta solicitud');
      }

      // 3. Verificar que no esté procesada
      if (requestData['status'] != 'pending') {
        return (success: false, message: 'Esta solicitud ya fue procesada');
      }

      final groupId = requestData['groupId'] as String?;
      final childId = requestData['childId'] as String?;
      final now = FieldValue.serverTimestamp();

      // 4. Remover de pendingMembers del grupo (si existe)
      if (groupId != null && childId != null) {
        final groupRef = _firestore.collection('groups_v2').doc(groupId);
        final groupDoc = await groupRef.get();

        if (groupDoc.exists) {
          final groupData = groupDoc.data()!;
          final pendingMembers = List<String>.from(groupData['pendingMembers'] ?? []);

          if (pendingMembers.contains(childId)) {
            await groupRef.update({
              'pendingMembers': FieldValue.arrayRemove([childId]),
              'updatedAt': now,
            });
          }
        }
      }

      // 5. Actualizar solicitud a rechazada
      await requestRef.update({
        'status': 'rejected',
        'respondedAt': now,
        'respondedBy': parentId,
      });

      ReleaseLogger.log(
        'Membresía de grupo rechazada exitosamente',
        tag: 'RejectGroupMembership',
      );

      return (success: true, message: 'Membresía rechazada');
    } catch (e) {
      ReleaseLogger.error(
        'Error rechazando membresía de grupo: $e',
        tag: 'RejectGroupMembership',
      );

      if (e.toString().contains('PERMISSION_DENIED')) {
        return (success: false, message: 'No tienes permiso para realizar esta acción');
      }

      return (success: false, message: 'Error al rechazar membresía');
    }
  }
}
