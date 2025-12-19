import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Obtener hijos vinculados de un padre
///
/// Responsabilidad única: Leer linkedChildrenIds del documento del padre
class GetLinkedChildrenService {
  final FirebaseFirestore _firestore;

  GetLinkedChildrenService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Obtener IDs de hijos vinculados
  Future<List<String>> getIds(String parentId) async {
    try {
      final parentDoc = await _firestore.collection('users').doc(parentId).get();
      final ids = List<String>.from(parentDoc.data()?['linkedChildrenIds'] ?? []);
      ReleaseLogger.log(
        'linkedChildrenIds para $parentId: $ids',
        tag: 'GetLinkedChildren',
      );
      return ids;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo hijos vinculados: $e', tag: 'GetLinkedChildren');
      return [];
    }
  }

  /// Stream de IDs de hijos vinculados (para detectar cambios)
  Stream<List<String>> watchIds(String parentId) {
    return _firestore.collection('users').doc(parentId).snapshots().map((snapshot) {
      if (!snapshot.exists) return <String>[];
      return List<String>.from(snapshot.data()?['linkedChildrenIds'] ?? []);
    });
  }

  /// Obtener lista de hijos con sus nombres
  Future<List<({String id, String name, String? photoURL})>> getWithNames(
    String parentId,
  ) async {
    try {
      final childrenIds = await getIds(parentId);
      if (childrenIds.isEmpty) return [];

      final results = <({String id, String name, String? photoURL})>[];

      // Batch fetch en grupos de 10 (límite de Firestore)
      const batchSize = 10;
      for (var i = 0; i < childrenIds.length; i += batchSize) {
        final batch = childrenIds.skip(i).take(batchSize).toList();

        final snapshot = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();

        for (final doc in snapshot.docs) {
          final data = doc.data();
          results.add((
            id: doc.id,
            name: data['name'] as String? ?? 'Hijo',
            photoURL: data['photoURL'] as String?,
          ));
        }
      }

      return results;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo hijos con nombres: $e', tag: 'GetLinkedChildren');
      return [];
    }
  }
}
