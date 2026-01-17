import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Remover miembro de grupo
///
/// Responsabilidad única: Quitar un miembro del grupo
///
/// Nota: Solo admins pueden remover miembros.
/// El creador del grupo no puede ser removido.
class RemoveMemberService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RemoveMemberService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Remover un miembro del grupo
  ///
  /// [groupId] - ID del grupo
  /// [memberId] - ID del usuario a remover
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String groupId,
    required String memberId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (success: false, message: 'Grupo no encontrado');
      }

      final data = groupDoc.data()!;
      final admins = List<String>.from(data['admins'] ?? []);
      final createdBy = data['createdBy'] as String?;
      final members = List<String>.from(data['members'] ?? []);

      // Verificar que el usuario es admin
      if (!admins.contains(userId)) {
        return (
          success: false,
          message: 'Solo los administradores pueden remover miembros',
        );
      }

      // No se puede remover al creador
      if (memberId == createdBy) {
        return (
          success: false,
          message: 'No puedes remover al creador del grupo',
        );
      }

      // Verificar si el miembro está en el grupo
      if (!members.contains(memberId)) {
        return (success: true, message: 'El usuario no es miembro del grupo');
      }

      // Remover de miembros y admins si aplica
      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups_v2').doc(groupId);

      batch.update(groupRef, {
        'members': FieldValue.arrayRemove([memberId]),
        'admins': FieldValue.arrayRemove([memberId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();

      ReleaseLogger.log(
        'Miembro removido: $memberId de grupo $groupId',
        tag: 'RemoveMember',
      );

      return (success: true, message: 'Miembro removido');
    } catch (e) {
      ReleaseLogger.error('Error removiendo miembro: $e', tag: 'RemoveMember');
      return (success: false, message: 'Error al remover miembro');
    }
  }

  /// Verificar si un miembro puede ser removido
  Future<({bool canRemove, String reason})> canRemove({
    required String groupId,
    required String memberId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (canRemove: false, reason: 'Usuario no autenticado');
      }

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (canRemove: false, reason: 'Grupo no encontrado');
      }

      final data = groupDoc.data()!;
      final admins = List<String>.from(data['admins'] ?? []);
      final createdBy = data['createdBy'] as String?;

      if (!admins.contains(userId)) {
        return (canRemove: false, reason: 'No eres administrador');
      }

      if (memberId == createdBy) {
        return (canRemove: false, reason: 'No puedes remover al creador');
      }

      if (memberId == userId) {
        return (canRemove: false, reason: 'Usa "Salir del grupo" para irte');
      }

      return (canRemove: true, reason: 'OK');
    } catch (e) {
      return (canRemove: false, reason: 'Error verificando permisos');
    }
  }
}
