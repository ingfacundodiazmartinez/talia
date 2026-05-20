import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/release_logger.dart';

/// Service para que padres gestionen los contactos de sus hijos
///
/// Responsabilidades:
/// - Obtener contactos de un hijo
/// - Encontrar grupos compartidos entre hijo y contacto
/// - Remover hijo de grupos cuando se elimina un contacto
class ChildContactsManagementService {
  static final ChildContactsManagementService _instance = ChildContactsManagementService._internal();
  factory ChildContactsManagementService() => _instance;
  ChildContactsManagementService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Obtener todos los contactos de un hijo
  /// Retorna lista con datos de contacto (id, nombre, foto, status, chatId)
  Future<List<Map<String, dynamic>>> getChildContacts(String childId) async {
    try {
      final contactsSnapshot = await _firestore
          .collection('contacts')
          .where('users', arrayContains: childId)
          .get();

      final contacts = <Map<String, dynamic>>[];

      for (final doc in contactsSnapshot.docs) {
        final data = doc.data();
        final status = data['status'] as String? ?? '';
        if (status != 'approved' && status != 'pending') continue;

        final users = List<String>.from(data['users'] ?? []);
        final otherUserId = users.firstWhere((u) => u != childId, orElse: () => '');
        if (otherUserId.isEmpty) continue;

        // Usar datos desnormalizados del documento de contacto
        final userNames = Map<String, dynamic>.from(data['userNames'] ?? {});
        final userPhotoURLs = Map<String, dynamic>.from(data['userPhotoURLs'] ?? {});

        final contactName = userNames[otherUserId] as String? ?? 'Usuario';
        final contactPhotoURL = userPhotoURLs[otherUserId] as String?;

        final chatId = [childId, otherUserId]..sort();

        contacts.add({
          'contactId': otherUserId,
          'name': contactName,
          'photoURL': contactPhotoURL,
          'status': status,
          'chatId': '${chatId[0]}_${chatId[1]}',
        });
      }

      // Ordenar por nombre
      contacts.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

      return contacts;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo contactos del hijo: $e', tag: 'ChildContactsMgmt');
      rethrow;
    }
  }

  /// Encontrar grupos compartidos entre hijo y contacto
  /// Usa coleccion 'groups' (legacy)
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> getSharedGroups({
    required String childId,
    required String contactId,
  }) async {
    try {
      final groupsQuery = await _firestore
          .collection('groups')
          .where('members', arrayContains: childId)
          .get();

      return groupsQuery.docs.where((doc) {
        final members = List<String>.from(doc.data()['members'] ?? []);
        return members.contains(contactId);
      }).toList();
    } catch (e) {
      ReleaseLogger.error('Error buscando grupos compartidos: $e', tag: 'ChildContactsMgmt');
      return [];
    }
  }

  /// Remover hijo de un grupo especifico
  Future<void> removeChildFromGroup({
    required String groupId,
    required String childId,
  }) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([childId]),
      });
    } catch (e) {
      ReleaseLogger.error('Error removiendo hijo del grupo $groupId: $e', tag: 'ChildContactsMgmt');
      rethrow;
    }
  }

  /// Remover hijo de multiples grupos
  Future<void> removeChildFromGroups({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> groups,
    required String childId,
  }) async {
    for (final group in groups) {
      await removeChildFromGroup(groupId: group.id, childId: childId);
    }
  }
}
