import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../models/contact.dart' as contact_model;
import '../../utils/release_logger.dart';

/// Service atómico: Aprobar contacto de un hijo desde lista blanca
///
/// Responsabilidad única: Actualizar estado de contacto a 'approved'
/// y procesar invitaciones de grupo pendientes.
class ApproveWhitelistContactService {
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  ApproveWhitelistContactService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  /// Aprobar un contacto de hijo
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String contactDocId,
    required String childId,
    required String parentId,
  }) async {
    try {
      ReleaseLogger.log(
        'Aprobando contacto: contactDocId=$contactDocId, childId=$childId',
        tag: 'ApproveWhitelist',
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
          message: 'No tienes permiso para aprobar este contacto'
        );
      }

      // Actualizar aprobación para este hijo
      final updates = <String, dynamic>{
        'approvals.$childId.status': 'approved',
        'approvals.$childId.approvedBy': parentId,
        'approvals.$childId.approvedAt': FieldValue.serverTimestamp(),
      };

      // Verificar si todas las aprobaciones están completas
      final approvals =
          Map<String, contact_model.ApprovalStatus>.from(contact.approvals);
      approvals[childId] = contact_model.ApprovalStatus(
        status: 'approved',
        parentId: approvals[childId]?.parentId,
        approvedBy: parentId,
        approvedAt: DateTime.now(),
      );

      final allApproved = approvals.values.every((a) => a.isApproved);
      if (allApproved) {
        updates['status'] = 'approved';
      }

      await contactRef.update(updates);

      // Procesar invitaciones de grupo pendientes
      await _processGroupInvitations(contact, childId);

      ReleaseLogger.log(
        'Contacto aprobado exitosamente',
        tag: 'ApproveWhitelist',
      );

      return (success: true, message: 'Contacto aprobado');
    } catch (e) {
      ReleaseLogger.error('Error aprobando contacto: $e', tag: 'ApproveWhitelist');
      return (success: false, message: _getErrorMessage(e));
    }
  }

  Future<void> _processGroupInvitations(
    contact_model.Contact contact,
    String childId,
  ) async {
    try {
      final contactUserId = contact.getOtherUserId(childId);
      final contactDoc =
          await _firestore.collection('users').doc(contactUserId).get();
      final contactData = contactDoc.data() ?? {};
      final contactPhone =
          contactData['phoneNumber'] as String? ?? contactData['phone'] as String?;

      if (contactPhone != null && contactPhone.isNotEmpty) {
        await _functions
            .httpsCallable('processGroupInvitationsAfterContactApproval')
            .call({
          'childId': childId,
          'contactPhone': contactPhone,
        });
      }
    } catch (e) {
      // Error no crítico - solo log
      ReleaseLogger.error(
        'Error procesando invitaciones de grupo: $e',
        tag: 'ApproveWhitelist',
      );
    }
  }

  String _getErrorMessage(dynamic error) {
    if (error is FirebaseFunctionsException) {
      switch (error.code) {
        case 'permission-denied':
          return 'No tienes permiso para realizar esta acción';
        case 'not-found':
          return 'Contacto no encontrado';
        default:
          return error.message ?? 'Error al aprobar contacto';
      }
    }
    return 'Error al aprobar contacto';
  }
}
