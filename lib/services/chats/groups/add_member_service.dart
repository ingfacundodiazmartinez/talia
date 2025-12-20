import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Agregar miembro a grupo
///
/// Responsabilidad única: Agregar nuevos miembros a un grupo existente
///
/// Nota: Solo admins pueden agregar miembros
class AddMemberService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  AddMemberService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Agregar un miembro al grupo
  ///
  /// [groupId] - ID del grupo
  /// [memberId] - ID del usuario a agregar
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

      // Verificar que el usuario es admin
      final canAdd = await _isAdmin(groupId, userId);
      if (!canAdd) {
        return (
          success: false,
          message: 'Solo los administradores pueden agregar miembros',
        );
      }

      // Verificar si el miembro ya está en el grupo
      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (success: false, message: 'Grupo no encontrado');
      }

      final members = List<String>.from(groupDoc.data()?['members'] ?? []);

      if (members.contains(memberId)) {
        return (success: true, message: 'El usuario ya es miembro del grupo');
      }

      // Agregar miembro
      await _firestore.collection('groups_v2').doc(groupId).update({
        'members': FieldValue.arrayUnion([memberId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Miembro agregado: $memberId a grupo $groupId',
        tag: 'AddMember',
      );

      return (success: true, message: 'Miembro agregado');
    } catch (e) {
      ReleaseLogger.error('Error agregando miembro: $e', tag: 'AddMember');
      return (success: false, message: 'Error al agregar miembro');
    }
  }

  /// Agregar múltiples miembros al grupo
  Future<({bool success, int addedCount, String message})> addMultiple({
    required String groupId,
    required List<String> memberIds,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          addedCount: 0,
          message: 'Usuario no autenticado',
        );
      }

      if (memberIds.isEmpty) {
        return (
          success: true,
          addedCount: 0,
          message: 'No hay miembros que agregar',
        );
      }

      final canAdd = await _isAdmin(groupId, userId);
      if (!canAdd) {
        return (
          success: false,
          addedCount: 0,
          message: 'Solo los administradores pueden agregar miembros',
        );
      }

      // Obtener miembros actuales
      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (
          success: false,
          addedCount: 0,
          message: 'Grupo no encontrado',
        );
      }

      final currentMembers = Set<String>.from(groupDoc.data()?['members'] ?? []);
      final newMembers = memberIds.where((id) => !currentMembers.contains(id)).toList();

      if (newMembers.isEmpty) {
        return (
          success: true,
          addedCount: 0,
          message: 'Todos los usuarios ya son miembros',
        );
      }

      // Agregar nuevos miembros
      await _firestore.collection('groups_v2').doc(groupId).update({
        'members': FieldValue.arrayUnion(newMembers),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        '${newMembers.length} miembros agregados a grupo $groupId',
        tag: 'AddMember',
      );

      return (
        success: true,
        addedCount: newMembers.length,
        message: '${newMembers.length} miembros agregados',
      );
    } catch (e) {
      ReleaseLogger.error('Error agregando miembros: $e', tag: 'AddMember');
      return (
        success: false,
        addedCount: 0,
        message: 'Error al agregar miembros',
      );
    }
  }

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
