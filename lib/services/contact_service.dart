import 'package:cloud_firestore/cloud_firestore.dart';

/// Servicio para manejar operaciones relacionadas con contactos
///
/// Responsabilidades:
/// - Verificar bloqueos de chats
/// - Verificar revocaciones de contactos
/// - Obtener información de usuarios por teléfono
class ContactService {
  // Singleton pattern
  static final ContactService _instance = ContactService._internal();
  factory ContactService() => _instance;
  ContactService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Verificar si un chat está bloqueado
  /// Retorna un Stream que emite true si el chat está bloqueado
  Stream<bool> watchChatBlocked(String chatId) {
    return _firestore
        .collection('blocked_chats')
        .doc(chatId)
        .snapshots()
        .handleError((error) {
          // Ignorar errores de permisos silenciosamente
          // Esto ocurre cuando el documento no existe aún
          print('⚠️ Error escuchando blocked_chats/$chatId: $error');
        })
        .map((snapshot) {
          if (snapshot.exists) {
            final data = snapshot.data() as Map<String, dynamic>?;
            return data?['isActive'] ?? false;
          }
          return false;
        });
  }

  /// Verificar si un contacto está revocado
  /// Un contacto está revocado si su status en la colección 'contacts' es 'revoked'
  Future<bool> isContactRevoked(String childId, String contactId) async {
    try {
      // Buscar en la colección contacts
      final contactQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: childId)
          .get();

      for (final doc in contactQuery.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);

        // Verificar si este documento incluye el contactId
        if (users.contains(contactId)) {
          final status = data['status'] ?? '';
          return status == 'revoked';
        }
      }

      return false;
    } catch (e) {
      print('❌ Error verificando si contacto está revocado: $e');
      return false;
    }
  }

  /// Obtener ID de usuario por número de teléfono
  /// Retorna el userId si se encuentra, null si no existe
  Future<String?> getUserIdByPhone(String phoneNumber) async {
    try {
      final userQuery = await _firestore
          .collection('users')
          .where('phoneNumber', isEqualTo: phoneNumber)
          .limit(1)
          .get();

      if (userQuery.docs.isNotEmpty) {
        return userQuery.docs.first.id;
      }

      return null;
    } catch (e) {
      print('❌ Error buscando usuario por teléfono: $e');
      return null;
    }
  }

  /// Obtener datos de un usuario por su ID
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (userDoc.exists) {
        return userDoc.data();
      }
      return null;
    } catch (e) {
      print('❌ Error obteniendo datos de usuario $userId: $e');
      return null;
    }
  }

  /// Obtener todos los contactos de un usuario
  /// Retorna una lista de DocumentSnapshot con los contactos
  Future<List<DocumentSnapshot>> getUserContacts(String userId) async {
    try {
      final contactQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .where('status', isEqualTo: 'approved')
          .get();

      return contactQuery.docs;
    } catch (e) {
      print('❌ Error obteniendo contactos del usuario $userId: $e');
      return [];
    }
  }

  /// Stream de contactos de un usuario (con cache automático de Firebase)
  Stream<QuerySnapshot> watchUserContacts(String userId) {
    return _firestore
        .collection('contacts')
        .where('users', arrayContains: userId)
        .where('status', isEqualTo: 'approved')
        .snapshots();
  }

  /// Eliminar un contacto
  /// Cambia el status del contacto a 'deleted'
  Future<void> deleteContact(String currentUserId, String contactId) async {
    try {
      // Buscar el documento de contacto
      final contactQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: currentUserId)
          .get();

      for (final doc in contactQuery.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);

        // Verificar si este documento incluye el contactId
        if (users.contains(contactId)) {
          // Actualizar el status a 'deleted'
          await doc.reference.update({
            'status': 'deleted',
            'deletedAt': FieldValue.serverTimestamp(),
          });
          print('✅ Contacto $contactId eliminado exitosamente');
          return;
        }
      }

      print('⚠️ Contacto no encontrado');
    } catch (e) {
      print('❌ Error eliminando contacto: $e');
      rethrow;
    }
  }
}
