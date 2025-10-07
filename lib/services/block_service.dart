import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class BlockService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Bloquear un contacto
  Future<void> blockContact(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      // Crear documento de bloqueo
      await _firestore.collection('blocked_contacts').add({
        'userId': user.uid,
        'blockedUserId': contactId,
        'blockedAt': FieldValue.serverTimestamp(),
        'createdAt': DateTime.now().toIso8601String(),
      });

      print('🚫 Usuario $contactId bloqueado exitosamente');
    } catch (e) {
      throw Exception('Error bloqueando contacto: $e');
    }
  }

  // Desbloquear un contacto
  Future<void> unblockContact(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      // Buscar el documento de bloqueo
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: user.uid)
          .where('blockedUserId', isEqualTo: contactId)
          .get();

      // Eliminar todos los documentos encontrados
      for (final doc in blockQuery.docs) {
        await doc.reference.delete();
      }

      print('✅ Usuario $contactId desbloqueado exitosamente');
    } catch (e) {
      throw Exception('Error desbloqueando contacto: $e');
    }
  }

  // Verificar si un contacto está bloqueado
  Future<bool> isBlocked(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: user.uid)
          .where('blockedUserId', isEqualTo: contactId)
          .limit(1)
          .get();

      return blockQuery.docs.isNotEmpty;
    } catch (e) {
      print('Error verificando bloqueo: $e');
      return false;
    }
  }

  // Verificar si el usuario actual fue bloqueado por otro usuario
  Future<bool> isBlockedBy(String userId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: userId)
          .where('blockedUserId', isEqualTo: user.uid)
          .limit(1)
          .get();

      return blockQuery.docs.isNotEmpty;
    } catch (e) {
      print('Error verificando si fue bloqueado: $e');
      return false;
    }
  }

  // Obtener lista de contactos bloqueados
  Stream<List<String>> getBlockedContactsStream() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    return _firestore
        .collection('blocked_contacts')
        .where('userId', isEqualTo: user.uid)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => doc.data()['blockedUserId'] as String)
          .toList();
    });
  }

  // Obtener lista de contactos bloqueados (Future)
  Future<List<String>> getBlockedContacts() async {
    final user = _auth.currentUser;
    if (user == null) return [];

    try {
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: user.uid)
          .get();

      return blockQuery.docs
          .map((doc) => doc.data()['blockedUserId'] as String)
          .toList();
    } catch (e) {
      print('Error obteniendo contactos bloqueados: $e');
      return [];
    }
  }

  // Verificar si existe bloqueo mutuo (ambos se bloquearon)
  Future<bool> isMutualBlock(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final blocked = await isBlocked(contactId);
      final blockedBy = await isBlockedBy(contactId);

      return blocked && blockedBy;
    } catch (e) {
      print('Error verificando bloqueo mutuo: $e');
      return false;
    }
  }
}
