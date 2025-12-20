import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Quitar admin de miembro
///
/// Responsabilidad única: Quitar privilegios de admin a un miembro
///
/// Nota: El creador del grupo no puede ser degradado.
/// Un admin puede degradarse a sí mismo si hay otros admins.
class DemoteAdminService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  DemoteAdminService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Quitar admin de un miembro
  ///
  /// [groupId] - ID del grupo
  /// [memberId] - ID del usuario a degradar
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

      // Verificar que el usuario actual es admin
      if (!admins.contains(userId)) {
        return (
          success: false,
          message: 'Solo los administradores pueden degradar miembros',
        );
      }

      // No se puede degradar al creador
      if (memberId == createdBy) {
        return (
          success: false,
          message: 'No puedes quitar admin al creador del grupo',
        );
      }

      // Verificar si el miembro es admin
      if (!admins.contains(memberId)) {
        return (success: true, message: 'El usuario no es administrador');
      }

      // Si es el mismo usuario, verificar que haya otros admins
      if (memberId == userId && admins.length <= 1) {
        return (
          success: false,
          message: 'Debe haber al menos un administrador en el grupo',
        );
      }

      // Quitar admin
      await _firestore.collection('groups_v2').doc(groupId).update({
        'admins': FieldValue.arrayRemove([memberId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Admin removido: $memberId de grupo $groupId',
        tag: 'DemoteAdmin',
      );

      return (success: true, message: 'Administrador degradado');
    } catch (e) {
      ReleaseLogger.error('Error degradando admin: $e', tag: 'DemoteAdmin');
      return (success: false, message: 'Error al quitar administrador');
    }
  }

  /// Verificar si un admin puede ser degradado
  Future<({bool canDemote, String reason})> canDemote({
    required String groupId,
    required String memberId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (canDemote: false, reason: 'Usuario no autenticado');
      }

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (canDemote: false, reason: 'Grupo no encontrado');
      }

      final data = groupDoc.data()!;
      final admins = List<String>.from(data['admins'] ?? []);
      final createdBy = data['createdBy'] as String?;

      if (!admins.contains(userId)) {
        return (canDemote: false, reason: 'No eres administrador');
      }

      if (memberId == createdBy) {
        return (canDemote: false, reason: 'No puedes degradar al creador');
      }

      if (!admins.contains(memberId)) {
        return (canDemote: false, reason: 'El usuario no es administrador');
      }

      if (memberId == userId && admins.length <= 1) {
        return (canDemote: false, reason: 'Debe haber al menos un admin');
      }

      return (canDemote: true, reason: 'OK');
    } catch (e) {
      return (canDemote: false, reason: 'Error verificando permisos');
    }
  }
}
