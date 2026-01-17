import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/contact.dart';

/// Service atómico: Obtener lista de contactos de un usuario
///
/// Responsabilidad única: Proveer stream/lista de contactos
/// El filtrado por estado se hace en el Controller
class ListContactsService {
  /// Stream de todos los contactos de un usuario (para real-time updates)
  Stream<List<Contact>> watchByUser(String userId) {
    return Contact.watchByUser(userId);
  }

  /// Obtener página de contactos (para lazy loading)
  Future<List<Contact>> getPage(
    String userId, {
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) {
    return Contact.getPagedContacts(userId, limit: limit, startAfter: startAfter);
  }
}
