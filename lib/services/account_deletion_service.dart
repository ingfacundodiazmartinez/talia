import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../utils/release_logger.dart';

class AccountDeletionService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static final AccountDeletionService _instance = AccountDeletionService._internal();
  factory AccountDeletionService() => _instance;
  AccountDeletionService._internal();

  /// Método principal que coordina toda la eliminación de cuenta
  Future<void> deleteAccount(String password) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      // 1. Reautenticar usuario
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: password,
      );
      await user.reauthenticateWithCredential(credential);

      // 2. Eliminar datos de Firestore
      await _deleteUserDataFromFirestore(user.uid);

      // 3. Eliminar imágenes de Storage
      await _deleteUserImagesFromStorage(user.uid);

      // 4. Eliminar cuenta de Authentication
      await user.delete();
    } catch (e) {
      throw Exception('Error al eliminar cuenta: ${e.toString()}');
    }
  }

  /// Elimina todos los datos del usuario de Firestore
  Future<void> _deleteUserDataFromFirestore(String userId) async {
    final batch = _firestore.batch();

    try {
      // Eliminar documento del usuario
      batch.delete(_firestore.collection('users').doc(userId));

      // Eliminar de contactos
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .get();
      for (var doc in contactsQuery.docs) {
        batch.delete(doc.reference);
      }

      // Eliminar chats y mensajes
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .get();

      for (var chatDoc in chatsQuery.docs) {
        // Eliminar mensajes del chat
        final messagesQuery = await chatDoc.reference
            .collection('messages')
            .get();
        for (var msgDoc in messagesQuery.docs) {
          batch.delete(msgDoc.reference);
        }
        // Eliminar el chat
        batch.delete(chatDoc.reference);
      }

      // Eliminar reportes de soporte
      final reportsQuery = await _firestore
          .collection('support_reports')
          .where('userId', isEqualTo: userId)
          .get();
      for (var doc in reportsQuery.docs) {
        batch.delete(doc.reference);
      }

      // Eliminar solicitudes de contacto
      final contactRequestsQuery = await _firestore
          .collection('contact_requests')
          .where('childId', isEqualTo: userId)
          .get();
      for (var doc in contactRequestsQuery.docs) {
        batch.delete(doc.reference);
      }

      // Ejecutar todas las eliminaciones
      await batch.commit();
    } catch (e) {
      throw Exception('Error eliminando datos de Firestore: $e');
    }
  }

  /// Elimina las imágenes del usuario de Firebase Storage
  Future<void> _deleteUserImagesFromStorage(String userId) async {
    try {
      // Eliminar carpeta de imágenes de perfil del usuario
      final storageRef = FirebaseStorage.instance.ref('profile_images');
      final listResult = await storageRef.listAll();

      for (var item in listResult.items) {
        if (item.name.contains(userId)) {
          try {
            await item.delete();
          } catch (e) {
            ReleaseLogger.error('Error eliminando imagen $userId: $e', tag: 'AccountDeletion');
          }
        }
      }
    } catch (e) {
      // No lanzar error aquí para no bloquear la eliminación de la cuenta
      ReleaseLogger.error('Error eliminando imágenes de Storage: $e', tag: 'AccountDeletion');
    }
  }
}
