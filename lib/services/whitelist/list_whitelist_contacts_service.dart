import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rxdart/rxdart.dart';
import '../../models/contact.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Listar contactos de hijos para lista blanca
///
/// Responsabilidad única: Proveer stream y paginación de contactos de hijos
class ListWhitelistContactsService {
  final FirebaseFirestore _firestore;

  ListWhitelistContactsService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Stream de todos los contactos visibles para un padre
  /// Query por parentViewers (requerido por Security Rules)
  Stream<List<Contact>> watchByParent(String parentId) {
    ReleaseLogger.log(
      'Creando stream de contactos para padre: $parentId',
      tag: 'ListWhitelistContacts',
    );

    // Query por parentViewers - esto es lo que las Security Rules permiten
    return _firestore
        .collection('contacts')
        .where('parentViewers', arrayContains: parentId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Contact.fromFirestore(doc))
            .where((contact) {
              // Filtrar parent_child_link
              if (!contact.isRealContact) return false;
              // Excluir contactos 'potential' - padres solo ven contactos que hijos solicitaron
              if (contact.isPotential) return false;
              return true;
            })
            .toList());
  }

  /// Stream de todos los contactos de los hijos vinculados
  /// NOTA: Este método es para uso de los propios hijos, no de padres
  Stream<List<Contact>> watchByChildren(List<String> childrenIds) {
    if (childrenIds.isEmpty) {
      return Stream.value(<Contact>[]);
    }

    ReleaseLogger.log(
      'Creando stream para ${childrenIds.length} hijos',
      tag: 'ListWhitelistContacts',
    );

    // Crear un stream por cada hijo
    final streams = childrenIds.map((childId) {
      return _firestore
          .collection('contacts')
          .where('users', arrayContains: childId)
          .snapshots()
          .map((snapshot) => snapshot.docs
              .map((doc) => Contact.fromFirestore(doc))
              .where((contact) {
                // Filtrar parent_child_link
                if (!contact.isRealContact) return false;
                // Excluir contactos 'potential' - padres solo ven contactos que hijos solicitaron
                if (contact.isPotential) return false;
                return true;
              })
              .toList());
    }).toList();

    if (streams.length == 1) {
      return streams.first;
    }

    // Combinar múltiples streams y eliminar duplicados
    return Rx.combineLatestList(streams).map((listOfLists) {
      final allContacts = <String, Contact>{};
      for (final list in listOfLists) {
        for (final contact in list) {
          allContacts[contact.id] = contact;
        }
      }
      return allContacts.values.toList();
    });
  }

  /// Obtener página de contactos de un hijo (para lazy loading)
  Future<List<Contact>> getPage({
    required String childId,
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) async {
    try {
      var query = _firestore
          .collection('contacts')
          .where('users', arrayContains: childId)
          .orderBy('createdAt', descending: true)
          .limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();

      return snapshot.docs
          .map((doc) => Contact.fromFirestore(doc))
          .where((contact) => contact.isRealContact && !contact.isPotential)
          .toList();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo página de contactos: $e', tag: 'ListWhitelistContacts');
      return [];
    }
  }

  /// Obtener todos los contactos de múltiples hijos con paginación
  /// Útil para carga inicial con lazy loading
  Future<List<Contact>> getAllPaged({
    required List<String> childrenIds,
    int limit = 50,
  }) async {
    if (childrenIds.isEmpty) return [];

    final allContacts = <String, Contact>{};

    for (final childId in childrenIds) {
      final contacts = await getPage(childId: childId, limit: limit);
      for (final contact in contacts) {
        allContacts[contact.id] = contact;
      }
    }

    return allContacts.values.toList();
  }
}
