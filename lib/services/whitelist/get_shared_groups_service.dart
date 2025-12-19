import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Obtener grupos compartidos entre hijo y contacto
///
/// Responsabilidad única: Buscar grupos V2 donde ambos son miembros
/// ✅ Actualizado: Usa groups_v2 en lugar de groups legacy
class GetSharedGroupsService {
  final FirebaseFirestore _firestore;

  GetSharedGroupsService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Obtener grupos V2 compartidos entre hijo y contacto
  Future<List<({String id, String name, int memberCount})>> call({
    required String childId,
    required String contactId,
  }) async {
    try {
      // Buscar grupos V2 donde el hijo es miembro
      final groupsSnapshot = await _firestore
          .collection('groups_v2')
          .where('members', arrayContains: childId)
          .get();

      final sharedGroups = <({String id, String name, int memberCount})>[];

      for (final doc in groupsSnapshot.docs) {
        final data = doc.data();
        final members = List<String>.from(data['members'] ?? []);

        // Verificar si el contacto también es miembro
        if (members.contains(contactId)) {
          sharedGroups.add((
            id: doc.id,
            name: data['name'] as String? ?? 'Grupo sin nombre',
            memberCount: data['memberCount'] as int? ?? members.length,
          ));
        }
      }

      return sharedGroups;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo grupos compartidos: $e', tag: 'GetSharedGroups');
      return [];
    }
  }

  /// Remover a hijo de un grupo V2 específico (escritura directa)
  Future<bool> removeChildFromGroup({
    required String groupId,
    required String childId,
  }) async {
    try {
      await _firestore.collection('groups_v2').doc(groupId).update({
        'members': FieldValue.arrayRemove([childId]),
        'memberDetails.$childId': FieldValue.delete(),
        'memberCount': FieldValue.increment(-1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      ReleaseLogger.error('Error removiendo niño del grupo: $e', tag: 'GetSharedGroups');
      return false;
    }
  }
}
