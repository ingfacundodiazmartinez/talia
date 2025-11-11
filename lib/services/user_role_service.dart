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
        return 'child';
      }

      // Verificar si tiene padre asociado en parent_child_link
      final hasParent = await hasParentLink(userId);

      if (hasParent) {
        return 'child';
      }

      // Verificar si el usuario tiene rol 'parent' establecido
      final userDoc = await _firestore.collection('users').doc(userId).get();
      final currentRole = userDoc.data()?['role'];

      if (currentRole == 'parent') {
        return 'parent';
      }

      // Por defecto: adult
      return 'adult';
    } catch (e) {
      // En caso de error, default a adult si >= 18, child si < 18
      return age < 18 ? 'child' : 'adult';
    }
  }

  /// Verifica si un usuario tiene al menos un padre vinculado (aprobado)
  Future<bool> hasParentLink(String userId) async {
    try {
      final links = await _firestore
          .collection('parent_children')
          .where('childId', isEqualTo: userId)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      return links.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Verifica si existe un vínculo específico entre un padre y un hijo
  Future<bool> hasSpecificParentLink(String childId, String parentId) async {
    try {
      final links = await _firestore
          .collection('parent_children')
          .where('childId', isEqualTo: childId)
          .where('parentId', isEqualTo: parentId)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      return links.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Obtiene todos los padres vinculados a un usuario
  /// ⚠️ CORREGIDO: Busca en users donde linkedChildrenIds contenga userId
  Future<List<String>> getLinkedParents(String userId) async {
    try {
      final usersSnapshot = await _firestore
          .collection('users')
          .where('linkedChildrenIds', arrayContains: userId)
          .get();

      return usersSnapshot.docs.map((doc) => doc.id).toList();
    } catch (e) {
      return [];
    }
  }

  /// Obtiene todos los hijos vinculados a un padre
  /// ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds en lugar de hacer query
  /// por seguridad (evita permitir list queries en parent_children)
  Future<List<String>> getLinkedChildren(String parentId) async {
    try {

      final userDoc = await _firestore.collection('users').doc(parentId).get();

      if (!userDoc.exists) {
        return [];
      }

      final userData = userDoc.data() as Map<String, dynamic>;
      final linkedChildrenIds = List<String>.from(userData['linkedChildrenIds'] ?? []);


      return linkedChildrenIds;
    } catch (e) {
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

      return true;
    } catch (e) {
      return false;
    }
  }
}
