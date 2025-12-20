import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Salir de grupo
///
/// Responsabilidad única: Permitir a un usuario salir de un grupo
///
/// Nota: Cualquier miembro puede salir, incluyendo el creador.
/// Si el último admin sale, se asigna otro miembro como admin.
/// Si el último miembro sale, el grupo se marca como inactivo.
class LeaveGroupService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  LeaveGroupService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Salir del grupo
  ///
  /// [groupId] - ID del grupo
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

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (success: false, message: 'Grupo no encontrado');
      }

      final data = groupDoc.data()!;
      final members = List<String>.from(data['members'] ?? []);
      final admins = List<String>.from(data['admins'] ?? []);

      // Verificar si es miembro
      if (!members.contains(userId)) {
        return (success: true, message: 'No eres miembro del grupo');
      }

      // Verificar si es el último miembro o último admin
      final isAdmin = admins.contains(userId);
      final isLastAdmin = isAdmin && admins.length == 1;
      final isLastMember = members.length == 1;
      final hasOtherMembers = members.length > 1;

      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups_v2').doc(groupId);

      // Si es el último miembro, marcar grupo como inactivo
      // Nota: memberDetails y pendingMemberDetails quedan huérfanos pero es seguro
      // (members array es la fuente de verdad, la UI ya filtra por eso)
      if (isLastMember) {
        batch.update(groupRef, {
          'members': FieldValue.arrayRemove([userId]),
          'admins': FieldValue.arrayRemove([userId]),
          'pendingMembers': FieldValue.arrayRemove([userId]),
          'isActive': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        ReleaseLogger.log(
          'Grupo marcado como inactivo (último miembro salió): $groupId',
          tag: 'LeaveGroup',
        );
      } else {
        // Remover usuario de miembros, admins y pendingMembers
        batch.update(groupRef, {
          'members': FieldValue.arrayRemove([userId]),
          'admins': FieldValue.arrayRemove([userId]),
          'pendingMembers': FieldValue.arrayRemove([userId]),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        // Si era el último admin, asignar nuevo admin
        if (isLastAdmin && hasOtherMembers) {
          // Obtener el primer miembro que no sea el usuario actual
          final newAdmin = members.firstWhere(
            (m) => m != userId,
            orElse: () => '',
          );

          if (newAdmin.isNotEmpty) {
            batch.update(groupRef, {
              'admins': FieldValue.arrayUnion([newAdmin]),
            });

            ReleaseLogger.log(
              'Nuevo admin asignado: $newAdmin',
              tag: 'LeaveGroup',
            );
          }
        }
      }

      await batch.commit();

      ReleaseLogger.log(
        'Usuario salió del grupo: $groupId',
        tag: 'LeaveGroup',
      );

      return (success: true, message: 'Has salido del grupo');
    } catch (e) {
      ReleaseLogger.error('Error saliendo del grupo: $e', tag: 'LeaveGroup');
      return (success: false, message: 'Error al salir del grupo');
    }
  }

  /// Verificar si el usuario puede salir del grupo
  ///
  /// Cualquier miembro puede salir, incluyendo el creador.
  Future<({bool canLeave, String reason})> canLeave({
    required String groupId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (canLeave: false, reason: 'Usuario no autenticado');
      }

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (canLeave: false, reason: 'Grupo no encontrado');
      }

      final data = groupDoc.data()!;
      final members = List<String>.from(data['members'] ?? []);

      if (!members.contains(userId)) {
        return (canLeave: false, reason: 'No eres miembro del grupo');
      }

      return (canLeave: true, reason: 'OK');
    } catch (e) {
      return (canLeave: false, reason: 'Error verificando permisos');
    }
  }
}
