import 'package:cloud_firestore/cloud_firestore.dart';
import 'user.dart';

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
      print('❌ Error obteniendo hijo: $e');
      return null;
    }
  }

  /// Obtiene los hijos vinculados de un padre
  static Future<List<Child>> getLinkedChildren(String parentId) async {
    try {
      final linksSnapshot = await FirebaseFirestore.instance
          .collection('parent_child_links')
          .where('parentId', isEqualTo: parentId)
          .where('status', isEqualTo: 'approved')
          .get();

      final children = <Child>[];

      for (final linkDoc in linksSnapshot.docs) {
        final childId = linkDoc.data()['childId'] as String;
        final child = await getById(childId);
        if (child != null) {
          children.add(child);
        }
      }

      return children;
    } catch (e) {
      print('❌ Error obteniendo hijos vinculados: $e');
      return [];
    }
  }

  /// Stream de hijos vinculados de un padre
  static Stream<List<String>> getLinkedChildrenIdsStream(String parentId) {
    return FirebaseFirestore.instance
        .collection('parent_child_links')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => doc.data()['childId'] as String)
          .toList();
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
      print('❌ Error obteniendo contactos: $e');
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
      print('❌ Error obteniendo mensajes: $e');
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
        .map((snapshot) => snapshot.docs.length);
  }

  /// Obtiene los padres vinculados del hijo
  Future<List<Map<String, dynamic>>> getParents() async {
    try {
      final linksSnapshot = await FirebaseFirestore.instance
          .collection('parent_child_links')
          .where('childId', isEqualTo: id)
          .where('status', isEqualTo: 'approved')
          .get();

      List<Map<String, dynamic>> parents = [];

      for (var doc in linksSnapshot.docs) {
        final parentId = doc.data()['parentId'];
        final parentDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(parentId)
            .get();

        if (parentDoc.exists) {
          final parentData = parentDoc.data()!;
          parentData['id'] = parentId;
          parents.add(parentData);
        }
      }

      return parents;
    } catch (e) {
      print('❌ Error obteniendo padres del hijo: $e');
      return [];
    }
  }

  @override
  String toString() {
    return 'Child(id: $id, name: $name, age: $age)';
  }
}
