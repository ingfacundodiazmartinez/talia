import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
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

  /// Padres vinculados del hijo.
  ///
  /// Hay DOS verdades en juego, cada una con su proyección de lectura:
  ///
  ///  • RELACIÓN — verdad: colección `parent_children`. Pero sus rules solo
  ///    dejan leer el vínculo en el que el viewer participa, y Firestore rechaza
  ///    queries que puedan devolver docs no legibles. Proyección permission-safe:
  ///    `linkedParentIds` en el doc del hijo (mantenida por el trigger
  ///    `onParentChildLinkCreated`).
  ///
  ///  • PERFIL del padre (nombre/foto) — verdad: doc `users/{parentId}`.
  ///    Proyección: `linkedParentsData` en el doc del hijo. La proyección puede
  ///    quedar STALE (ej: el padre recambia su foto → Firebase Storage revoca el
  ///    token viejo → la URL guardada da 403). Por eso leemos el doc real del
  ///    padre cuando el viewer tiene permiso, y caemos a la proyección si no.
  ///
  /// Estrategia: proyección para resolver QUIÉNES son los padres (permission-safe),
  /// doc real para resolver nombre/foto FRESCOS, proyección como fallback de perfil.
  Future<List<Map<String, dynamic>>> getParents() async {
    final db = FirebaseFirestore.instance;
    try {
      final childDoc = await db.collection('users').doc(id).get();
      if (!childDoc.exists) {
        ReleaseLogger.log('👨‍👩‍👧 [getParents] Documento del hijo no existe', tag: 'Child');
        return [];
      }
      final childData = childDoc.data()!;

      var parentIds = List<String>.from(childData['linkedParentIds'] ?? const []);
      final projection = childData['linkedParentsData'] is Map
          ? Map<String, dynamic>.from(childData['linkedParentsData'] as Map)
          : const <String, dynamic>{};

      // Fallback a la FUENTE DE VERDAD de la relación si la proyección está vacía.
      if (parentIds.isEmpty) {
        if (childData['role'] != 'child') return [];
        parentIds = await _parentIdsFromSourceOfTruth();
        if (parentIds.isNotEmpty) {
          ReleaseLogger.error(
            '⚠️ [getParents] Proyección linkedParentIds vacía para hijo $id pero '
            'existe vínculo en parent_children. Trigger onParentChildLinkCreated '
            'desincronizado — revisar.',
            tag: 'Child',
          );
        }
      }
      if (parentIds.isEmpty) return [];

      // Resolver nombre/foto: doc real (fresco) si se puede, sino proyección.
      final result = <Map<String, dynamic>>[];
      for (final parentId in parentIds) {
        String? name;
        String? photoURL;
        try {
          final pDoc = await db.collection('users').doc(parentId).get();
          if (pDoc.exists) {
            name = pDoc.data()!['name'] as String?;
            photoURL = pDoc.data()!['photoURL'] as String?;
          }
        } catch (_) {
          // Sin permiso para leer el doc del padre → usar proyección.
        }
        if (name == null || photoURL == null) {
          final p = projection[parentId];
          if (p is Map) {
            name ??= p['name'] as String?;
            photoURL ??= p['photoURL'] as String?;
          }
        }
        result.add({
          'id': parentId,
          'name': (name != null && name.isNotEmpty) ? name : 'Padre/Madre',
          'photoURL': photoURL,
        });
      }
      return result;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo padres del hijo: $e', tag: 'Child');
      return [];
    }
  }

  /// Devuelve los parentId del hijo leyendo la fuente de verdad (parent_children).
  /// Las rules solo dejan leer el vínculo donde el viewer participa, así que esto
  /// recupera al padre que está mirando a su propio hijo (self-heal).
  Future<List<String>> _parentIdsFromSourceOfTruth() async {
    final db = FirebaseFirestore.instance;
    final selfId = FirebaseAuth.instance.currentUser?.uid;
    if (selfId == null) return [];
    final ids = <String>[];
    for (final linkId in ['${selfId}_$id', '${id}_$selfId']) {
      try {
        final link = await db.collection('parent_children').doc(linkId).get();
        if (link.exists && link.data()?['status'] == 'approved') {
          final pid = link.data()!['parentId'] as String?;
          if (pid != null && pid != id) ids.add(pid);
        }
      } catch (_) {
        // Sin permiso para ese vínculo: ignorar.
      }
    }
    return ids;
  }

  @override
  String toString() {
    return 'Child(id: $id, name: $name, age: $age)';
  }
}
