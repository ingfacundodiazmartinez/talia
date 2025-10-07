import 'package:cloud_firestore/cloud_firestore.dart';
import 'user.dart';
import 'child.dart';

/// Modelo para usuarios con rol de Padre/Madre
class Parent extends User {
  Parent({
    required super.id,
    required super.name,
    super.birthDate,
    super.photoURL,
    super.isOnline,
  }) : super(role: 'parent');

  /// Crea una instancia de Parent desde un documento de Firestore
  factory Parent.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Document data is null');
    }

    return Parent(
      id: doc.id,
      name: data['name'] ?? 'Padre/Madre',
      birthDate: User.parseBirthDate(data['birthDate'] ?? data['age']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'],
    );
  }

  /// Crea una instancia de Parent desde un Map
  factory Parent.fromMap(String id, Map<String, dynamic> data) {
    return Parent(
      id: id,
      name: data['name'] ?? 'Padre/Madre',
      birthDate: User.parseBirthDate(data['birthDate'] ?? data['age']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'],
    );
  }

  /// Obtiene un padre específico por su ID desde Firestore
  static Future<Parent?> getById(String parentId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(parentId)
          .get();

      if (!doc.exists) return null;

      return Parent.fromFirestore(doc);
    } catch (e) {
      print('❌ Error obteniendo padre: $e');
      return null;
    }
  }

  /// Stream de los datos del padre
  Stream<DocumentSnapshot> getUserDataStream() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(id)
        .snapshots();
  }

  /// Obtiene todos los contactos del padre
  Future<List<DocumentSnapshot>> loadAllContacts() async {
    try {
      final query = await FirebaseFirestore.instance
          .collection('contacts')
          .where('users', arrayContains: id)
          .get();

      return query.docs;
    } catch (e) {
      print('❌ Error cargando contactos: $e');
      return [];
    }
  }

  /// Stream de solicitudes de aprobación pendientes
  Stream<QuerySnapshot> getApprovalRequestsStream() {
    return FirebaseFirestore.instance
        .collection('parent_approval_requests')
        .where('existingParentId', isEqualTo: id)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  /// Obtiene una emergencia específica
  Future<DocumentSnapshot?> getEmergency(String emergencyId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('emergencies')
          .doc(emergencyId)
          .get();

      return doc.exists ? doc : null;
    } catch (e) {
      print('❌ Error obteniendo emergencia: $e');
      return null;
    }
  }

  /// Desvincula un hijo del padre
  Future<bool> unlinkChild(String childId) async {
    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('parent_children')
          .where('parentId', isEqualTo: id)
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in querySnapshot.docs) {
        await doc.reference.delete();
      }

      return true;
    } catch (e) {
      print('❌ Error desvinculando hijo: $e');
      return false;
    }
  }

  /// Obtiene los hijos vinculados como objetos Child
  Future<List<Child>> getLinkedChildren() async {
    return Child.getLinkedChildren(id);
  }

  /// Stream de IDs de hijos vinculados
  Stream<List<String>> getLinkedChildrenIdsStream() {
    return Child.getLinkedChildrenIdsStream(id);
  }

  /// Stream de la configuración del padre
  Stream<DocumentSnapshot> getParentSettingsStream() {
    return FirebaseFirestore.instance
        .collection('parent_settings')
        .doc(id)
        .snapshots();
  }

  /// Actualiza la configuración de aprobación automática
  Future<void> updateAutoApprovalSetting(bool enabled) async {
    await FirebaseFirestore.instance
        .collection('parent_settings')
        .doc(id)
        .set({
      'autoApproveRequests': enabled,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Stream de alertas del padre
  Stream<QuerySnapshot> getAlertsStream() {
    return FirebaseFirestore.instance
        .collection('alerts')
        .where('parentId', isEqualTo: id)
        .snapshots();
  }

  /// Stream de contactos aprobados
  Stream<QuerySnapshot> getApprovedContactsStream() {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: id)
        .where('status', isEqualTo: 'approved')
        .snapshots();
  }

  /// Calcula los días activos desde la creación de la cuenta
  static int calculateDaysActive(Timestamp? createdAt) {
    if (createdAt == null) return 0;
    final now = DateTime.now();
    final created = createdAt.toDate();
    return now.difference(created).inDays;
  }

  /// Actualiza la foto de perfil
  Future<void> updatePhotoURL(String photoURL) async {
    await FirebaseFirestore.instance.collection('users').doc(id).update({
      'photoURL': photoURL,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Elimina la foto de perfil
  Future<void> deletePhotoURL() async {
    await FirebaseFirestore.instance.collection('users').doc(id).update({
      'photoURL': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Realiza logout actualizando el estado del usuario
  Future<void> logout() async {
    await FirebaseFirestore.instance.collection('users').doc(id).update({
      'isOnline': false,
      'lastSeen': FieldValue.serverTimestamp(),
      'fcmToken': null,
    });
  }

  /// Actualiza los datos de perfil del usuario
  Future<void> updateProfile({
    required String name,
    required String phone,
    required DateTime birthDate,
    required String role,
  }) async {
    await FirebaseFirestore.instance.collection('users').doc(id).update({
      'name': name,
      'phone': phone,
      'birthDate': Timestamp.fromDate(birthDate),
      'role': role,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Obtiene los datos actuales del usuario
  Future<Map<String, dynamic>?> getUserData() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(id)
          .get();

      if (!doc.exists) return null;

      return doc.data();
    } catch (e) {
      print('❌ Error obteniendo datos de usuario: $e');
      return null;
    }
  }

  @override
  String toString() {
    return 'Parent(id: $id, name: $name, age: $age)';
  }
}
