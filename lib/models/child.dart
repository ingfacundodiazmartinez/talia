import 'package:cloud_firestore/cloud_firestore.dart';
import 'user.dart';
import '../utils/release_logger.dart';

class Child extends User {
  Child({
    required super.id,
    required super.name,
    super.birthDate,
    super.photoURL,
    super.isOnline,
  }) : super(role: 'child');

  /// Obtiene las iniciales del nombre del hijo
  @override
  String get initials {
    if (name.isEmpty) return 'H';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  /// Crea una instancia de Child desde un documento de Firestore
  factory Child.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Document data is null');
    }

    return Child(
      id: doc.id,
      name: data['name'] ?? 'Hijo',
      birthDate: User.parseBirthDate(data['birthDate'] ?? data['age']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'],
    );
  }

  /// Crea una instancia de Child desde un Map
  factory Child.fromMap(String id, Map<String, dynamic> data) {
    return Child(
      id: id,
      name: data['name'] ?? 'Hijo',
      birthDate: User.parseBirthDate(data['birthDate'] ?? data['age']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'],
    );
  }

  /// Obtiene un hijo específico por su ID desde Firestore
  static Future<Child?> getById(String childId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(childId)
          .get();

      if (!doc.exists) return null;

      return Child.fromFirestore(doc);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo hijo: $e', tag: 'Child');
      return null;
    }
  }

  /// Obtiene los hijos vinculados de un padre
  /// ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds por seguridad
  static Future<List<Child>> getLinkedChildren(String parentId) async {
    try {
      // Leer linkedChildrenIds desde el documento del usuario
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(parentId)
          .get();

      if (!userDoc.exists) {
        ReleaseLogger.log('Usuario $parentId no existe', tag: 'Child');
        return [];
      }

      final userData = userDoc.data() as Map<String, dynamic>;
      final linkedChildrenIds = List<String>.from(userData['linkedChildrenIds'] ?? []);

      final children = <Child>[];

      for (final childId in linkedChildrenIds) {
        final child = await getById(childId);
        if (child != null) {
          children.add(child);
        }
      }

      return children;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo hijos vinculados: $e', tag: 'Child');
      return [];
    }
  }

  /// Stream de hijos vinculados de un padre
  /// ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds por seguridad
  static Stream<List<String>> getLinkedChildrenIdsStream(String parentId) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(parentId)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) {
        return <String>[];
      }
      final userData = snapshot.data() as Map<String, dynamic>;
      return List<String>.from(userData['linkedChildrenIds'] ?? []);
    });
  }

  /// Obtiene el conteo de contactos aprobados del hijo
  Future<int> getContactsCount() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('contacts')
          .where('users', arrayContains: id)
          .where('status', isEqualTo: 'approved')
          .get();

      return snapshot.docs.length;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo contactos: $e', tag: 'Child');
      return 0;
    }
  }

  /// Stream del conteo de contactos aprobados
  Stream<int> getContactsCountStream() {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: id)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Obtiene el conteo de mensajes enviados hoy
  Future<int> getMessagesCountToday() async {
    try {
      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      final snapshot = await FirebaseFirestore.instance
          .collection('messages')
          .where('senderId', isEqualTo: id)
          .where('timestamp', isGreaterThanOrEqualTo: startOfDay)
          .get();

      return snapshot.docs.length;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo mensajes: $e', tag: 'Child');
      return 0;
    }
  }

  /// Stream del conteo de mensajes enviados hoy
  Stream<int> getMessagesCountTodayStream() {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);

    return FirebaseFirestore.instance
        .collection('messages')
        .where('senderId', isEqualTo: id)
        .where('timestamp', isGreaterThanOrEqualTo: startOfDay)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Obtiene el conteo de alertas sin leer para un padre específico
  Stream<int> getUnreadAlertsCountStream(String parentId) {
    return FirebaseFirestore.instance
        .collection('alerts')
        .where('childId', isEqualTo: id)
        .where('parentId', isEqualTo: parentId)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .map((snapshot) {
      ReleaseLogger.log('🚨 [ALERTS BADGE] Query for childId=$id, parentId=$parentId', tag: 'Child');
      ReleaseLogger.log('🚨 [ALERTS BADGE] Found ${snapshot.docs.length} unread alerts', tag: 'Child');
      if (snapshot.docs.isNotEmpty) {
        ReleaseLogger.log('🚨 [ALERTS BADGE] Alert IDs: ${snapshot.docs.map((d) => d.id).toList()}', tag: 'Child');
        ReleaseLogger.log('🚨 [ALERTS BADGE] First alert data: ${snapshot.docs.first.data()}', tag: 'Child');
      }
      return snapshot.docs.length;
    });
  }

  /// Obtiene los padres vinculados del hijo
  /// ✅ FIX: Usa parent_children en lugar de users.linkedChildrenIds (permisos)
  Future<List<Map<String, dynamic>>> getParents() async {
    try {
      // 1. Obtener parentIds desde parent_children
      final linksSnapshot = await FirebaseFirestore.instance
          .collection('parent_children')
          .where('childId', isEqualTo: id)
          .where('status', isEqualTo: 'approved')
          .get();

      final parentIds = linksSnapshot.docs
          .map((doc) => doc.data()['parentId'] as String)
          .toList();

      if (parentIds.isEmpty) {
        return [];
      }

      // 2. Obtener datos de cada padre
      List<Map<String, dynamic>> parents = [];

      for (var parentId in parentIds) {
        final parentDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(parentId)
            .get();

        if (parentDoc.exists) {
          final parentData = parentDoc.data()!;
          parentData['id'] = parentDoc.id;
          parents.add(parentData);
        }
      }

      return parents;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo padres del hijo: $e', tag: 'Child');
      return [];
    }
  }

  @override
  String toString() {
    return 'Child(id: $id, name: $name, age: $age)';
  }
}
