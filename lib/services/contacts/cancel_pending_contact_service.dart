import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Cancelar un contacto pendiente
///
/// Responsabilidad única: Actualizar el approval del usuario a 'rejected'.
/// Usa Firestore directamente (validado por rules).
class CancelPendingContactService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CancelPendingContactService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Cancelar un contacto pendiente
  /// Retorna true si se canceló exitosamente
  Future<bool> call(String contactId) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.error(
          'Usuario no autenticado',
          tag: 'CancelContact',
        );
        return false;
      }

      ReleaseLogger.log(
        'Cancelando solicitud: $contactId',
        tag: 'CancelContact',
      );

      // Actualizar el approval del usuario a rejected
      await _firestore.collection('contacts').doc(contactId).update({
        'approvals.$currentUserId.status': 'rejected',
        'approvals.$currentUserId.rejectedAt': FieldValue.serverTimestamp(),
        'approvals.$currentUserId.rejectedBy': currentUserId,
      });

      ReleaseLogger.log(
        'Solicitud cancelada exitosamente',
        tag: 'CancelContact',
      );

      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error cancelando solicitud: $e',
        tag: 'CancelContact',
      );
      return false;
    }
  }
}
