import 'package:cloud_firestore/cloud_firestore.dart';

/// Servicio para determinar el rol del usuario basado en:
/// 1. Edad < 18 = child
/// 2. Tiene padre asociado en parent_child_link = child (incluso si edad >= 18)
/// 3. Caso contrario = adult
///
/// NOTA: El rol 'parent' se mantiene manual y solo se usa para acceder a ParentHomeScreen
class UserRoleService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Determina el rol correcto basado en edad y vinculación con padre
  ///
  /// Retorna:
  /// - 'child': Si edad < 18 O tiene padre vinculado
  /// - 'adult': Si edad >= 18 Y NO tiene padre vinculado
  /// - 'parent': Se mantiene si ya está establecido (para acceso a ParentHomeScreen)
  Future<String> determineUserRole(String userId, int age) async {
    try {
      // Si edad < 18, siempre es child
      if (age < 18) {
        print('👶 Usuario $userId es child por edad < 18');
        return 'child';
      }

      // Verificar si tiene padre asociado en parent_child_link
      final hasParent = await hasParentLink(userId);

      if (hasParent) {
        print('👶 Usuario $userId es child porque tiene padre asociado');
        return 'child';
      }

      // Verificar si el usuario tiene rol 'parent' establecido
      final userDoc = await _firestore.collection('users').doc(userId).get();
      final currentRole = userDoc.data()?['role'];

      if (currentRole == 'parent') {
        print('👨‍👩‍👧 Usuario $userId mantiene rol parent');
        return 'parent';
      }

      // Por defecto: adult
      print('👤 Usuario $userId es adult (edad >= 18 y sin padre)');
      return 'adult';
    } catch (e) {
      print('❌ Error determinando rol del usuario $userId: $e');
      // En caso de error, default a adult si >= 18, child si < 18
      return age < 18 ? 'child' : 'adult';
    }
  }

  /// Verifica si un usuario tiene al menos un padre vinculado (aprobado)
  Future<bool> hasParentLink(String userId) async {
    try {
      final links = await _firestore
          .collection('parent_child_links')
          .where('childId', isEqualTo: userId)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      return links.docs.isNotEmpty;
    } catch (e) {
      print('❌ Error verificando vínculo padre-hijo para $userId: $e');
      return false;
    }
  }

  /// Verifica si existe un vínculo específico entre un padre y un hijo
  Future<bool> hasSpecificParentLink(String childId, String parentId) async {
    try {
      final links = await _firestore
          .collection('parent_child_links')
          .where('childId', isEqualTo: childId)
          .where('parentId', isEqualTo: parentId)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      return links.docs.isNotEmpty;
    } catch (e) {
      print('❌ Error verificando vínculo específico padre-hijo: $e');
      return false;
    }
  }

  /// Obtiene todos los padres vinculados a un usuario
  Future<List<String>> getLinkedParents(String userId) async {
    try {
      final links = await _firestore
          .collection('parent_child_links')
          .where('childId', isEqualTo: userId)
          .where('status', isEqualTo: 'approved')
          .get();

      return links.docs.map((doc) => doc.data()['parentId'] as String).toList();
    } catch (e) {
      print('❌ Error obteniendo padres vinculados para $userId: $e');
      return [];
    }
  }

  /// Obtiene todos los hijos vinculados a un padre
  Future<List<String>> getLinkedChildren(String parentId) async {
    try {
      print('🔍 Consultando hijos vinculados para padre: $parentId');

      final links = await _firestore
          .collection('parent_child_links')
          .where('parentId', isEqualTo: parentId)
          .where('status', isEqualTo: 'approved')
          .get();

      print('📊 Encontrados ${links.docs.length} documentos en parent_child_links');

      for (var doc in links.docs) {
        print('   - Doc ID: ${doc.id}, childId: ${doc.data()['childId']}');
      }

      final childrenIds = links.docs.map((doc) => doc.data()['childId'] as String).toList();
      print('✅ Retornando ${childrenIds.length} hijos: $childrenIds');

      return childrenIds;
    } catch (e) {
      print('❌ Error obteniendo hijos vinculados para $parentId: $e');
      return [];
    }
  }

  /// Calcula y actualiza el rol del usuario en Firestore
  Future<bool> updateUserRole(String userId, int age) async {
    try {
      final newRole = await determineUserRole(userId, age);

      await _firestore.collection('users').doc(userId).update({
        'role': newRole,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ Rol actualizado para usuario $userId: $newRole');
      return true;
    } catch (e) {
      print('❌ Error actualizando rol del usuario $userId: $e');
      return false;
    }
  }
}
