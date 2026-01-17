import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Actualizar grupo
///
/// Responsabilidad única: Modificar información del grupo
///
/// Nota: Solo admins pueden actualizar el grupo
class UpdateGroupService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  UpdateGroupService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Actualizar nombre del grupo
  Future<({bool success, String message})> updateName({
    required String groupId,
    required String newName,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      if (newName.trim().isEmpty) {
        return (success: false, message: 'El nombre no puede estar vacío');
      }

      // Verificar permisos de admin
      final canUpdate = await _isAdmin(groupId, userId);
      if (!canUpdate) {
        return (
          success: false,
          message: 'Solo los administradores pueden editar el grupo',
        );
      }

      await _firestore.collection('groups_v2').doc(groupId).update({
        'name': newName.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Nombre de grupo actualizado: $groupId',
        tag: 'UpdateGroup',
      );

      return (success: true, message: 'Nombre actualizado');
    } catch (e) {
      ReleaseLogger.error('Error actualizando nombre: $e', tag: 'UpdateGroup');
      return (success: false, message: 'Error al actualizar nombre');
    }
  }

  /// Actualizar descripción del grupo
  Future<({bool success, String message})> updateDescription({
    required String groupId,
    required String newDescription,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final canUpdate = await _isAdmin(groupId, userId);
      if (!canUpdate) {
        return (
          success: false,
          message: 'Solo los administradores pueden editar el grupo',
        );
      }

      await _firestore.collection('groups_v2').doc(groupId).update({
        'description': newDescription.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Descripción de grupo actualizada: $groupId',
        tag: 'UpdateGroup',
      );

      return (success: true, message: 'Descripción actualizada');
    } catch (e) {
      ReleaseLogger.error('Error actualizando descripción: $e', tag: 'UpdateGroup');
      return (success: false, message: 'Error al actualizar descripción');
    }
  }

  /// Actualizar foto del grupo
  Future<({bool success, String message})> updatePhoto({
    required String groupId,
    required String? photoUrl,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final canUpdate = await _isAdmin(groupId, userId);
      if (!canUpdate) {
        return (
          success: false,
          message: 'Solo los administradores pueden editar el grupo',
        );
      }

      await _firestore.collection('groups_v2').doc(groupId).update({
        'photoURL': photoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Foto de grupo actualizada: $groupId',
        tag: 'UpdateGroup',
      );

      return (success: true, message: 'Foto actualizada');
    } catch (e) {
      ReleaseLogger.error('Error actualizando foto: $e', tag: 'UpdateGroup');
      return (success: false, message: 'Error al actualizar foto');
    }
  }

  /// Actualizar múltiples campos
  Future<({bool success, String message})> update({
    required String groupId,
    String? name,
    String? description,
    String? photoUrl,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final canUpdate = await _isAdmin(groupId, userId);
      if (!canUpdate) {
        return (
          success: false,
          message: 'Solo los administradores pueden editar el grupo',
        );
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null && name.trim().isNotEmpty) {
        updateData['name'] = name.trim();
      }
      if (description != null) {
        updateData['description'] = description.trim();
      }
      if (photoUrl != null) {
        updateData['photoURL'] = photoUrl;
      }

      await _firestore.collection('groups_v2').doc(groupId).update(updateData);

      ReleaseLogger.log(
        'Grupo actualizado: $groupId',
        tag: 'UpdateGroup',
      );

      return (success: true, message: 'Grupo actualizado');
    } catch (e) {
      ReleaseLogger.error('Error actualizando grupo: $e', tag: 'UpdateGroup');
      return (success: false, message: 'Error al actualizar grupo');
    }
  }

  /// Verificar si el usuario es admin del grupo
  Future<bool> _isAdmin(String groupId, String userId) async {
    try {
      final doc = await _firestore.collection('groups_v2').doc(groupId).get();
      if (!doc.exists) return false;

      final admins = List<String>.from(doc.data()?['admins'] ?? []);
      return admins.contains(userId);
    } catch (e) {
      return false;
    }
  }
}
