import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Solicitar aprobación de contacto
///
/// Responsabilidad única: Actualizar contacto de potential a pending/approved.
/// Las notificaciones se crean via trigger (onContactApprovalRequested).
class RequestContactApprovalService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RequestContactApprovalService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Solicitar aprobación para un contacto
  /// Retorna (success, message, newStatus)
  Future<({bool success, String message, String? newStatus})> call(
    String contactDocId,
  ) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return (
          success: false,
          message: 'Usuario no autenticado',
          newStatus: null
        );
      }

      ReleaseLogger.log(
        'Solicitando aprobación para: $contactDocId',
        tag: 'RequestApproval',
      );

      // 1. Obtener el contacto
      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        return (
          success: false,
          message: 'Contacto no encontrado',
          newStatus: null
        );
      }

      final data = contactDoc.data()!;

      // 2. Verificar que está en estado 'potential'
      if (data['status'] != 'potential') {
        return (
          success: false,
          message: 'El contacto no está en estado sugerido',
          newStatus: null
        );
      }

      // 3. Verificar que el usuario es parte del contacto
      final users = List<String>.from(data['users'] ?? []);
      if (!users.contains(currentUserId)) {
        return (
          success: false,
          message: 'No eres parte de este contacto',
          newStatus: null
        );
      }

      // 4. Usar datos pre-calculados
      final isUser1 = users[0] == currentUserId;
      final otherUserId = users.firstWhere((u) => u != currentUserId);
      final currentUserParents = List<String>.from(
        isUser1 ? (data['user1Parents'] ?? []) : (data['user2Parents'] ?? []),
      );
      final otherUserParents = List<String>.from(
        isUser1 ? (data['user2Parents'] ?? []) : (data['user1Parents'] ?? []),
      );
      final needsInitiatorApproval = data['needsInitiatorApproval'] ?? false;
      final needsTargetApproval = data['needsTargetApproval'] ?? false;
      final needsApproval = needsInitiatorApproval || needsTargetApproval;

      // 5. Preparar datos de actualización
      final updateData = <String, dynamic>{
        'initiatorId': currentUserId,
        'requestedAt': FieldValue.serverTimestamp(),
      };

      String newStatus;

      if (!needsApproval) {
        // Auto-aprobar
        newStatus = 'approved';
        updateData['status'] = 'approved';
        updateData['approvedAt'] = FieldValue.serverTimestamp();

        ReleaseLogger.log('Auto-aprobando contacto', tag: 'RequestApproval');
      } else {
        // Requiere aprobación parental
        newStatus = 'pending';
        updateData['status'] = 'pending';
        updateData['completedApprovals'] = [];

        // Preparar mapa de approvals
        final approvalsMap = <String, dynamic>{};
        if (needsInitiatorApproval && currentUserParents.isNotEmpty) {
          approvalsMap[currentUserId] = {
            'status': 'pending',
            'parentId': currentUserParents[0],
            'side': 'initiator',
          };
        }
        if (needsTargetApproval && otherUserParents.isNotEmpty) {
          approvalsMap[otherUserId] = {
            'status': 'pending',
            'parentId': otherUserParents[0],
            'side': 'target',
          };
        }
        if (approvalsMap.isNotEmpty) {
          updateData['approvals'] = approvalsMap;
        }

        ReleaseLogger.log(
          'Contacto pendiente de aprobación',
          tag: 'RequestApproval',
        );
      }

      // 6. Actualizar contacto
      await contactRef.update(updateData);

      final message = newStatus == 'approved'
          ? 'Contacto aprobado automáticamente'
          : 'Solicitud enviada. Tu padre/madre debe aprobarla.';

      ReleaseLogger.log(
        'Contacto actualizado: status=$newStatus',
        tag: 'RequestApproval',
      );

      return (success: true, message: message, newStatus: newStatus);
    } catch (e) {
      ReleaseLogger.error(
        'Error solicitando aprobación: $e',
        tag: 'RequestApproval',
      );
      return (
        success: false,
        message: 'Error al solicitar aprobación',
        newStatus: null
      );
    }
  }
}
