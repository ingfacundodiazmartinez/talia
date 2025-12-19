import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/contact.dart';
import '../../utils/release_logger.dart';
import 'request_contact_approval_service.dart';

/// Service atómico: Reenviar solicitud de contacto
///
/// Responsabilidad única: Resetear el contacto a 'potential' y solicitar
/// aprobación nuevamente.
/// Usa Firestore directamente (validado por rules).
class ResendContactRequestService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final RequestContactApprovalService _requestApprovalService;

  ResendContactRequestService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    RequestContactApprovalService? requestApprovalService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _requestApprovalService =
            requestApprovalService ?? RequestContactApprovalService();

  /// Reenviar solicitud de contacto
  ///
  /// Acepta otherUserId para mantener compatibilidad con el controller.
  /// Internamente encuentra el contactId y hace:
  /// 1. Reset a 'potential'
  /// 2. Solicita aprobación
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call(String otherUserId) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return (
          success: false,
          message: 'Usuario no autenticado',
        );
      }

      // Generar el contactId a partir de los dos userIds
      final contactId = Contact.generateId(currentUserId, otherUserId);

      ReleaseLogger.log(
        'Reenviando solicitud: $contactId',
        tag: 'ResendRequest',
      );

      // Verificar que el contacto existe
      final contactDoc =
          await _firestore.collection('contacts').doc(contactId).get();

      if (!contactDoc.exists) {
        return (
          success: false,
          message: 'Contacto no encontrado',
        );
      }

      final data = contactDoc.data()!;
      final status = data['status'] as String?;

      // Si ya está en potential, solo solicitar aprobación
      if (status == 'potential') {
        ReleaseLogger.log(
          'Contacto ya en potential, solicitando aprobación',
          tag: 'ResendRequest',
        );
        final result = await _requestApprovalService.call(contactId);
        return (success: result.success, message: result.message);
      }

      // Verificar que el approval del usuario está rejected o el status permite resend
      final approvals = data['approvals'] as Map<String, dynamic>?;
      final myApproval = approvals?[currentUserId] as Map<String, dynamic>?;

      if (myApproval == null || myApproval['status'] != 'rejected') {
        // Si no hay approval rejected pero el status es pending/rejected general
        if (status != 'pending' && status != 'rejected' && status != 'cancelled') {
          return (
            success: false,
            message: 'No puedes reenviar esta solicitud',
          );
        }
      }

      // Resetear el contacto a 'potential' y limpiar approvals
      await _firestore.collection('contacts').doc(contactId).update({
        'status': 'potential',
        'approvals': FieldValue.delete(),
      });

      ReleaseLogger.log(
        'Contacto reseteado a potential, solicitando aprobación',
        tag: 'ResendRequest',
      );

      // Solicitar aprobación inmediatamente
      final result = await _requestApprovalService.call(contactId);
      return (success: result.success, message: result.message);
    } catch (e) {
      ReleaseLogger.error(
        'Error reenviando solicitud: $e',
        tag: 'ResendRequest',
      );

      String errorMsg = 'Error al reenviar solicitud';
      if (e.toString().contains('PERMISSION_DENIED')) {
        errorMsg = 'No tienes permiso para reenviar esta solicitud';
      }

      return (success: false, message: errorMsg);
    }
  }
}
