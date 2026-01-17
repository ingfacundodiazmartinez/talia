import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/contact.dart' as contact_model;
import '../../utils/release_logger.dart';

/// Service atómico: Rechazar contacto de un hijo desde lista blanca
///
/// Responsabilidad única: Actualizar estado de contacto a 'rejected'
class RejectWhitelistContactService {
  final FirebaseFirestore _firestore;

  RejectWhitelistContactService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Rechazar un contacto de hijo
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String contactDocId,
    required String childId,
    required String parentId,
  }) async {
    try {
      ReleaseLogger.log(
        'Rechazando contacto: contactDocId=$contactDocId, childId=$childId',
        tag: 'RejectWhitelist',
      );

      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        return (success: false, message: 'Contacto no encontrado');
      }

      final contact = contact_model.Contact.fromFirestore(contactDoc);

      // Verificar permiso
      if (!contact.parentViewers.contains(parentId)) {
        return (
          success: false,
          message: 'No tienes permiso para rechazar este contacto'
        );
      }

      // Actualizar aprobación para este hijo
      await contactRef.update({
        'approvals.$childId.status': 'rejected',
        'approvals.$childId.rejectedBy': parentId,
        'approvals.$childId.rejectedAt': FieldValue.serverTimestamp(),
        'status': 'rejected',
      });

      ReleaseLogger.log(
        'Contacto rechazado exitosamente',
        tag: 'RejectWhitelist',
      );

      return (success: true, message: 'Contacto rechazado');
    } catch (e) {
      ReleaseLogger.error('Error rechazando contacto: $e', tag: 'RejectWhitelist');
      return (success: false, message: 'Error al rechazar contacto');
    }
  }
}
