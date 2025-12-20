import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Promover miembro a admin
///
/// Responsabilidad única: Hacer admin a un miembro del grupo
///
/// Nota: Solo admins existentes pueden promover
class PromoteAdminService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  PromoteAdminService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Promover miembro a admin
  ///
  /// [groupId] - ID del grupo
  /// [memberId] - ID del usuario a promover
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
      final members = List<String>.from(data['members'] ?? []);
      final admins = List<String>.from(data['admins'] ?? []);

      // Verificar que el usuario actual es admin
      if (!admins.contains(userId)) {
        return (
          success: false,
          message: 'Solo los administradores pueden promover miembros',
        );
      }

      // Verificar que el miembro está en el grupo
      if (!members.contains(memberId)) {
        return (success: false, message: 'El usuario no es miembro del grupo');
      }

      // Verificar si ya es admin
      if (admins.contains(memberId)) {
        return (success: true, message: 'El usuario ya es administrador');
      }

      // Promover a admin
      await _firestore.collection('groups_v2').doc(groupId).update({
        'admins': FieldValue.arrayUnion([memberId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log(
        'Miembro promovido a admin: $memberId en grupo $groupId',
        tag: 'PromoteAdmin',
      );

      return (success: true, message: 'Miembro promovido a administrador');
    } catch (e) {
      ReleaseLogger.error('Error promoviendo admin: $e', tag: 'PromoteAdmin');
      return (success: false, message: 'Error al promover administrador');
    }
  }
}
