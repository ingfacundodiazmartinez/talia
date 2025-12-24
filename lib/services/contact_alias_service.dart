import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'user_cache_service.dart';

class ContactAliasService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserCacheService _userCacheService = UserCacheService();

  /// Obtener el nombre a mostrar para un contacto (alias si existe, sino nombre real)
  Future<String> getDisplayName(String contactId, String realName) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return realName;

      final userDoc = await _firestore.collection('users').doc(currentUser.uid).get();
      if (!userDoc.exists) return realName;

      final userData = userDoc.data();
      if (userData == null) return realName;

      final aliases = userData['contactAliases'] as Map<String, dynamic>?;
      if (aliases != null && aliases.containsKey(contactId)) {
        return aliases[contactId] as String;
      }

      return realName;
    } catch (e) {
      return realName;
    }
  }

  /// Stream que escucha cambios en el nombre a mostrar de un contacto
  /// ✅ Usa distinct() para evitar rebuilds innecesarios cuando otros campos
  /// del documento cambian (como lastSeen, isOnline, etc.)
  Stream<String> watchDisplayName(String contactId, String realName) {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return Stream.value(realName);

    return _firestore
        .collection('users')
        .doc(currentUser.uid)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) return realName;

      final userData = snapshot.data();
      if (userData == null) return realName;

      final aliases = userData['contactAliases'] as Map<String, dynamic>?;
      if (aliases != null && aliases.containsKey(contactId)) {
        return aliases[contactId] as String;
      }

      return realName;
    }).distinct(); // ✅ Solo emite cuando el valor del alias realmente cambia
  }

  /// Guardar un alias para un contacto
  /// Actualiza tanto Firestore como el cache local
  Future<void> setAlias(String contactId, String alias) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) throw Exception('Usuario no autenticado');

      // Actualizar Firestore
      await _firestore.collection('users').doc(currentUser.uid).update({
        'contactAliases.$contactId': alias,
      });

      // Actualizar cache local para que getDisplayName() refleje el cambio inmediatamente
      await _userCacheService.setAlias(contactId, alias);
    } catch (e) {
      rethrow;
    }
  }

  /// Eliminar el alias de un contacto (restaurar nombre original)
  /// Actualiza tanto Firestore como el cache local
  Future<void> removeAlias(String contactId) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) throw Exception('Usuario no autenticado');

      // Eliminar de Firestore
      await _firestore.collection('users').doc(currentUser.uid).update({
        'contactAliases.$contactId': FieldValue.delete(),
      });

      // Eliminar del cache local
      await _userCacheService.setAlias(contactId, null);
    } catch (e) {
      rethrow;
    }
  }
}
