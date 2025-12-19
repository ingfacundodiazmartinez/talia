import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Eliminar un contacto rechazado
///
/// Responsabilidad única: Eliminar el documento de contacto.
/// Usa Firestore directamente (validado por rules - solo si approval está rejected).
class DeleteContactService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  DeleteContactService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Eliminar un contacto rechazado
  /// Retorna true si se eliminó exitosamente
  Future<bool> call(String contactId) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.error(
          'Usuario no autenticado',
          tag: 'DeleteContact',
        );
        return false;
      }

      ReleaseLogger.log(
        'Eliminando contacto: $contactId',
        tag: 'DeleteContact',
      );

      // Eliminar el documento (rules validan que el approval esté rejected)
      await _firestore.collection('contacts').doc(contactId).delete();

      ReleaseLogger.log(
        'Contacto eliminado exitosamente',
        tag: 'DeleteContact',
      );

      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error eliminando contacto: $e',
        tag: 'DeleteContact',
      );
      return false;
    }
  }
}
