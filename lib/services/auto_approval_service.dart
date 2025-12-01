import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../notification_service.dart';
import 'user_role_service.dart';
import 'group_chat_service.dart';
import '../utils/release_logger.dart';

class AutoApprovalService {
  static final AutoApprovalService _instance = AutoApprovalService._internal();
  factory AutoApprovalService() => _instance;
  AutoApprovalService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();

  /// Inicializar el servicio de aprobación automática para un padre
  Future<void> startAutoApprovalForParent(String parentId) async {

    // Obtener lista de hijos del padre
    final userRoleService = UserRoleService();
    final childrenIds = await userRoleService.getLinkedChildren(parentId);

    if (childrenIds.isEmpty) {
      return;
    }


    // Escuchar solicitudes de contacto para cada hijo
    for (final childId in childrenIds) {
      _firestore
          .collection('contact_requests')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen(
            (snapshot) async {
              for (final change in snapshot.docChanges) {
                if (change.type == DocumentChangeType.added) {
                  final requestData = change.doc.data() as Map<String, dynamic>;

                  await _processAutoApproval(
                    requestId: change.doc.id,
                    requestData: requestData,
                    parentId: parentId,
                  );
                }
              }
            },
            onError: (error) {
              ReleaseLogger.error(
                '❌ [AutoApproval] Contact requests stream error for child $childId: $error',
              );
            },
            cancelOnError: false,
          );
    }

    // Escuchar nuevas solicitudes de permiso de grupo
    _firestore
        .collection('permission_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen(
          (snapshot) async {
            for (final change in snapshot.docChanges) {
              if (change.type == DocumentChangeType.added) {
                final requestData = change.doc.data() as Map<String, dynamic>;

                await _processGroupPermissionAutoApproval(
                  requestId: change.doc.id,
                  requestData: requestData,
                  parentId: parentId,
                );
              }
            }
          },
          onError: (error) {
            ReleaseLogger.error(
              '❌ [AutoApproval] Permission requests stream error: $error',
            );
          },
          cancelOnError: false,
        );
  }

  /// Procesar aprobación automática si está habilitada
  Future<void> _processAutoApproval({
    required String requestId,
    required Map<String, dynamic> requestData,
    required String parentId,
  }) async {
    try {

      // Verificar si el padre tiene habilitada la aprobación automática
      final parentSettingsDoc = await _firestore
          .collection('parent_settings')
          .doc(parentId)
          .get();

      if (!parentSettingsDoc.exists) {
        return;
      }

      final settings = parentSettingsDoc.data() as Map<String, dynamic>;
      final autoApproveEnabled = settings['autoApproveRequests'] ?? false;

      if (!autoApproveEnabled) {
        return;
      }


      // Procesar la aprobación automática
      await _autoApproveContact(
        requestId: requestId,
        childId: requestData['childId'],
        contactName: requestData['contactName'] ?? 'Desconocido',
        contactPhone: requestData['contactPhone'] ?? '',
        parentId: parentId,
      );
    } catch (e) {
    }
  }

  /// Aprobar automáticamente un contacto
  Future<void> _autoApproveContact({
    required String requestId,
    required String childId,
    required String contactName,
    required String contactPhone,
    required String parentId,
  }) async {
    try {

      // Usar Cloud Function para aprobar
      final callable = FirebaseFunctions.instance.httpsCallable('updateContactRequestStatus');
      await callable.call({
        'requestId': requestId,
        'status': 'approved',
      });


      // Obtener datos de la solicitud para procesar invitaciones de grupo
      final requestDoc = await _firestore.collection('contact_requests').doc(requestId).get();
      final requestData = requestDoc.data();

      if (requestData != null) {
        final contactId = requestData['contactId'];

        // Procesar invitaciones de grupo pendientes
        if (contactId != null) {
          final groupChatService = GroupChatService();
          await groupChatService.processGroupInvitationsAfterContactApproval(
            childId,
            contactId,
          );
        }
      }

      // Enviar notificación al hijo de que su contacto fue aprobado
      await _notificationService.sendContactApprovedNotification(
        childId: childId,
        contactName: contactName,
      );

      // Enviar notificación al padre informando de la aprobación automática
      await _notificationService.sendAutoApprovalNotification(
        parentId: parentId,
        childId: childId,
        contactName: contactName,
      );
    } catch (e) {
    }
  }

  /// Procesar aprobación automática de permisos de grupo
  Future<void> _processGroupPermissionAutoApproval({
    required String requestId,
    required Map<String, dynamic> requestData,
    required String parentId,
  }) async {
    try {

      // Verificar si el padre tiene habilitada la aprobación automática
      final parentSettingsDoc = await _firestore
          .collection('parent_settings')
          .doc(parentId)
          .get();

      if (!parentSettingsDoc.exists) {
        return;
      }

      final settings = parentSettingsDoc.data() as Map<String, dynamic>;
      final autoApproveEnabled = settings['autoApproveRequests'] ?? false;

      if (!autoApproveEnabled) {
        return;
      }


      final childId = requestData['childId'];
      final contactInfo = requestData['contactToApprove'] as Map<String, dynamic>?;
      final contactId = contactInfo?['userId'];
      final contactName = contactInfo?['name'] ?? 'Usuario';

      if (contactId == null) {
        return;
      }

      // Llamar a Cloud Function para crear/actualizar contacto de forma segura
      final callable = FirebaseFunctions.instance.httpsCallable('autoApproveContact');
      await callable.call({
        'childId': childId,
        'contactId': contactId,
        'parentId': parentId,
        'requestId': requestId,
      });


      // Procesar invitaciones de grupo pendientes
      final groupChatService = GroupChatService();
      await groupChatService.processGroupInvitationsAfterContactApproval(
        childId,
        contactId,
      );


      // Enviar notificación al padre informando de la auto-aprobación
      await _notificationService.sendAutoApprovalNotification(
        parentId: parentId,
        childId: childId,
        contactName: contactName,
      );
    } catch (e) {

      // En caso de error, marcar la solicitud con error para revisión manual
      await _firestore.collection('permission_requests').doc(requestId).update({
        'autoApprovalError': e.toString(),
        'autoApprovalFailedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Detener el servicio de aprobación automática
  void stopAutoApproval() {
    // Los listeners se pueden cancelar si se almacenan las referencias
    // Por ahora, el listener se mantendrá activo mientras la app esté abierta
  }
}
