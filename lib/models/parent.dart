import 'package:cloud_firestore/cloud_firestore.dart';
import 'user.dart';
import 'child.dart';
import '../services/contact_service.dart';

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

  /// Obtiene todos los contactos del padre (con cache)
  Future<List<DocumentSnapshot>> loadAllContacts() async {
    try {
      final contactService = ContactService();
      return await contactService.getUserContacts(id);
    } catch (e) {
      print('❌ Error cargando contactos: $e');
      return [];
    }
  }

  /// Stream de todos los contactos del padre (con cache automático)
  Stream<QuerySnapshot> watchAllContacts() {
    final contactService = ContactService();
    return contactService.watchUserContacts(id);
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

  /// Desvincula un hijo del padre
  ///
  /// Limpia configuraciones específicas de este padre-hijo:
  /// - Solicitudes de aprobación de historias de este padre específico
  /// - Configuraciones de moderación de chats entre este padre e hijo
  /// - Solicitudes de aprobación de padres donde este padre está involucrado
  ///
  /// NO elimina solicitudes de contacto del hijo (pueden ser gestionadas por otro padre)
  Future<bool> unlinkChild(String childId) async {
    try {
      print('🔄 Iniciando desvinculación del hijo $childId del padre $id');

      // 1. Eliminar el enlace padre-hijo
      final querySnapshot = await FirebaseFirestore.instance
          .collection('parent_children')
          .where('parentId', isEqualTo: id)
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in querySnapshot.docs) {
        await doc.reference.delete();
        print('✅ Eliminado enlace padre-hijo: ${doc.id}');
      }

      // 2. Verificar si el hijo tiene otros padres vinculados
      final otherParentsSnapshot = await FirebaseFirestore.instance
          .collection('parent_children')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'approved')
          .get();

      final hasOtherParents = otherParentsSnapshot.docs.isNotEmpty;
      print('👨‍👩‍👧 Hijo tiene ${otherParentsSnapshot.docs.length} padre(s) adicional(es) vinculado(s)');

      // 3. Limpiar solicitudes de aprobación de historias SOLO de este padre
      final pendingStoryApprovals = await FirebaseFirestore.instance
          .collection('story_approval_requests')
          .where('childId', isEqualTo: childId)
          .where('parentId', isEqualTo: id)
          .where('status', isEqualTo: 'pending')
          .get();

      for (var doc in pendingStoryApprovals.docs) {
        await doc.reference.delete();
        print('✅ Eliminada solicitud de historia pendiente de este padre: ${doc.id}');
      }

      // 4. Desactivar configuraciones de moderación de chats entre este padre e hijo
      final chats = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: id)
          .get();

      for (var chatDoc in chats.docs) {
        final chatData = chatDoc.data();
        final participants = List<String>.from(chatData['participants'] ?? []);

        // Si el chat es entre este padre y el hijo desvinculado
        if (participants.contains(childId) && participants.contains(id)) {
          // Desactivar moderación solo para este padre
          await chatDoc.reference.update({
            'moderationEnabled_$id': false,
            'moderationSettings_$id': FieldValue.delete(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          print('✅ Desactivada moderación de este padre en chat: ${chatDoc.id}');
        }
      }

      // 5. Limpiar solicitudes de aprobación de padres donde este padre está involucrado
      final parentApprovalRequests = await FirebaseFirestore.instance
          .collection('parent_approval_requests')
          .where('childId', isEqualTo: childId)
          .where('existingParentId', isEqualTo: id)
          .where('status', isEqualTo: 'pending')
          .get();

      for (var doc in parentApprovalRequests.docs) {
        await doc.reference.delete();
        print('✅ Eliminada solicitud de aprobación donde este padre estaba involucrado: ${doc.id}');
      }

      // NOTA: NO eliminamos solicitudes de contacto del hijo porque:
      // - El hijo puede tener otro padre vinculado que gestiona esas solicitudes
      // - Las solicitudes de contacto son responsabilidad del hijo y sus padres actuales

      // 6. Verificar si este padre tiene más hijos vinculados
      final remainingLinksSnapshot = await FirebaseFirestore.instance
          .collection('parent_children')
          .where('parentId', isEqualTo: id)
          .limit(1)
          .get();

      // 7. Si no quedan hijos, cambiar rol de vuelta a 'adult'
      if (remainingLinksSnapshot.docs.isEmpty) {
        print('👤 No quedan hijos vinculados, cambiando rol de este padre a "adult"');
        await FirebaseFirestore.instance
            .collection('users')
            .doc(id)
            .update({
          'role': 'adult',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        print('👤 Este padre tiene ${remainingLinksSnapshot.docs.length} hijo(s) adicional(es) vinculado(s)');
      }

      if (hasOtherParents) {
        print('✅ Hijo desvinculado de este padre (hijo mantiene vínculos con otros padres)');
      } else {
        print('✅ Hijo desvinculado de su último padre');
      }

      return true;
    } catch (e) {
      print('❌ Error desvinculando hijo: $e');
      return false;
    }
  }

  @override
  String toString() {
    return 'Parent(id: $id, name: $name, age: $age)';
  }
}
