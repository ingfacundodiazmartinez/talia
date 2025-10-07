import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ContactAliasService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Obtener el nombre a mostrar para un contacto (alias si existe, sino nombre real)
  Future<String> getDisplayName(String contactId, String realName) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return realName;

      final userDoc = await _firestore.collection('users').doc(currentUser.uid).get();
      if (!userDoc.exists) return realName;

      final userData = userDoc.data() as Map<String, dynamic>?;
      if (userData == null) return realName;

      final aliases = userData['contactAliases'] as Map<String, dynamic>?;
      if (aliases != null && aliases.containsKey(contactId)) {
        return aliases[contactId] as String;
      }

      return realName;
    } catch (e) {
      print('⚠️ Error obteniendo alias para contacto $contactId: $e');
      return realName;
    }
  }

  /// Stream que escucha cambios en el nombre a mostrar de un contacto
  Stream<String> watchDisplayName(String contactId, String realName) {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return Stream.value(realName);

    return _firestore
        .collection('users')
        .doc(currentUser.uid)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) return realName;

      final userData = snapshot.data() as Map<String, dynamic>?;
      if (userData == null) return realName;

      final aliases = userData['contactAliases'] as Map<String, dynamic>?;
      if (aliases != null && aliases.containsKey(contactId)) {
        return aliases[contactId] as String;
      }

      return realName;
    });
  }

  /// Guardar un alias para un contacto
  Future<void> setAlias(String contactId, String alias) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) throw Exception('Usuario no autenticado');

      await _firestore.collection('users').doc(currentUser.uid).set({
        'contactAliases': {
          contactId: alias,
        },
      }, SetOptions(merge: true));

      print('✅ Alias "$alias" guardado para contacto $contactId');
    } catch (e) {
      print('❌ Error guardando alias: $e');
      rethrow;
    }
  }

  /// Eliminar el alias de un contacto (restaurar nombre original)
  Future<void> removeAlias(String contactId) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) throw Exception('Usuario no autenticado');

      await _firestore.collection('users').doc(currentUser.uid).update({
        'contactAliases.$contactId': FieldValue.delete(),
      });

      print('✅ Alias eliminado para contacto $contactId');
    } catch (e) {
      print('❌ Error eliminando alias: $e');
      rethrow;
    }
  }
}
