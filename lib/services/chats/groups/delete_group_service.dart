import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Eliminar grupo
///
/// Responsabilidad única: Eliminar un grupo completamente
///
/// Nota: Solo el creador del grupo puede eliminarlo.
/// Esto elimina el grupo para todos los miembros.
class DeleteGroupService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  DeleteGroupService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Eliminar grupo permanentemente
  ///
  /// Solo el creador puede eliminar el grupo.
  /// Esto elimina el documento del grupo y todos sus mensajes.
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String groupId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      // Verificar que el usuario es el creador
      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (success: false, message: 'Grupo no encontrado');
      }

      final data = groupDoc.data()!;
      final createdBy = data['createdBy'] as String?;

      if (createdBy != userId) {
        return (
          success: false,
          message: 'Solo el creador puede eliminar el grupo',
        );
      }

      // Eliminar mensajes del grupo
      final messagesRef = _firestore
          .collection('groups_v2')
          .doc(groupId)
          .collection('messages');

      final messages = await messagesRef.get();

      // Eliminar en batches
      final batches = <WriteBatch>[];
      var currentBatch = _firestore.batch();
      var count = 0;

      for (final doc in messages.docs) {
        currentBatch.delete(doc.reference);
        count++;

        if (count >= 450) {
          batches.add(currentBatch);
          currentBatch = _firestore.batch();
          count = 0;
        }
      }

      // Eliminar documento del grupo
      currentBatch.delete(groupDoc.reference);
      batches.add(currentBatch);

      // Ejecutar todos los batches
      for (final batch in batches) {
        await batch.commit();
      }

      ReleaseLogger.log(
        'Grupo eliminado: $groupId',
        tag: 'DeleteGroup',
      );

      return (success: true, message: 'Grupo eliminado');
    } catch (e) {
      ReleaseLogger.error('Error eliminando grupo: $e', tag: 'DeleteGroup');
      return (success: false, message: 'Error al eliminar grupo');
    }
  }

  /// Verificar si el usuario puede eliminar el grupo
  Future<({bool canDelete, String reason})> canDelete({
    required String groupId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (canDelete: false, reason: 'Usuario no autenticado');
      }

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (canDelete: false, reason: 'Grupo no encontrado');
      }

      final createdBy = groupDoc.data()?['createdBy'] as String?;

      if (createdBy != userId) {
        return (
          canDelete: false,
          reason: 'Solo el creador puede eliminar el grupo',
        );
      }

      return (canDelete: true, reason: 'OK');
    } catch (e) {
      return (canDelete: false, reason: 'Error verificando permisos');
    }
  }
}
