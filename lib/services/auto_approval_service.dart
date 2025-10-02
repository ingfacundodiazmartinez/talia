import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../notification_service.dart';
import 'user_role_service.dart';
import 'group_chat_service.dart';

class AutoApprovalService {
  static final AutoApprovalService _instance = AutoApprovalService._internal();
  factory AutoApprovalService() => _instance;
  AutoApprovalService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();

  /// Inicializar el servicio de aprobación automática para un padre
  Future<void> startAutoApprovalForParent(String parentId) async {
    print(
      '🤖 Iniciando servicio de aprobación automática para padre: $parentId',
    );

    // Obtener lista de hijos del padre
    final userRoleService = UserRoleService();
    final childrenIds = await userRoleService.getLinkedChildren(parentId);

    if (childrenIds.isEmpty) {
      print('⚠️ No hay hijos vinculados a este padre');
      return;
    }

    print('👶 Escuchando solicitudes para ${childrenIds.length} hijo(s)');

    // Escuchar solicitudes de contacto para cada hijo
    for (final childId in childrenIds) {
      _firestore
          .collection('contact_requests')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen((snapshot) async {
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
          });
    }

    // Escuchar nuevas solicitudes de permiso de grupo
    _firestore
        .collection('permission_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snapshot) async {
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
        });
  }

  /// Verificar si un hijo pertenece a un padre específico usando parent_child_links
  Future<bool> _isChildOfParent(String childId, String parentId) async {
    try {
      final userRoleService = UserRoleService();
      return await userRoleService.hasSpecificParentLink(childId, parentId);
    } catch (e) {
      print('❌ Error verificando relación padre-hijo: $e');
      return false;
    }
  }

  /// Procesar aprobación automática si está habilitada
  Future<void> _processAutoApproval({
    required String requestId,
    required Map<String, dynamic> requestData,
    required String parentId,
  }) async {
    try {
      print(
        '🔍 Verificando configuración de aprobación automática para padre: $parentId',
      );

      // Verificar si el padre tiene habilitada la aprobación automática
      final parentSettingsDoc = await _firestore
          .collection('parent_settings')
          .doc(parentId)
          .get();

      if (!parentSettingsDoc.exists) {
        print(
          '⚙️ No hay configuración para este padre, saltando aprobación automática',
        );
        return;
      }

      final settings = parentSettingsDoc.data() as Map<String, dynamic>;
      final autoApproveEnabled = settings['autoApproveRequests'] ?? false;

      if (!autoApproveEnabled) {
        print('🔒 Aprobación automática deshabilitada para este padre');
        return;
      }

      print(
        '✅ Aprobación automática habilitada, procesando solicitud: $requestId',
      );

      // Procesar la aprobación automática
      await _autoApproveContact(
        requestId: requestId,
        childId: requestData['childId'],
        contactName: requestData['contactName'] ?? 'Desconocido',
        contactPhone: requestData['contactPhone'] ?? '',
        parentId: parentId,
      );
    } catch (e) {
      print('❌ Error en aprobación automática: $e');
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
      print(
        '🤖 Aprobando automáticamente contacto: $contactName para hijo: $childId',
      );

      // Buscar el usuario contacto (debe existir en el sistema)
      String? contactId;
      final existingUser = await _firestore
          .collection('users')
          .where('email', isEqualTo: contactPhone)
          .limit(1)
          .get();

      if (existingUser.docs.isNotEmpty) {
        contactId = existingUser.docs.first.id;
        print('👤 Usuario contacto existente encontrado: $contactId');
      } else {
        print('⚠️ Usuario contacto no existe en el sistema, no se puede aprobar automáticamente');
        // Marcar la solicitud para revisión manual
        await _firestore.collection('contact_requests').doc(requestId).update({
          'requiresManualApproval': true,
          'autoApprovalSkipped': true,
          'autoApprovalSkipReason': 'Usuario no registrado en el sistema',
        });
        return;
      }

      // Actualizar solicitud a aprobada
      await _firestore.collection('contact_requests').doc(requestId).update({
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
        'contactId': contactId,
        'approvedBy': parentId,
        'autoApproved': true, // Marcar como aprobación automática
      });

      // Agregar a la lista blanca
      await _firestore.collection('whitelist').add({
        'childId': childId,
        'contactId': contactId,
        'addedAt': FieldValue.serverTimestamp(),
        'approvedBy': parentId,
        'autoApproved': true,
      });

      print('✅ Contacto aprobado automáticamente y agregado a whitelist');

      // Procesar invitaciones de grupo pendientes
      final groupChatService = GroupChatService();
      await groupChatService.processGroupInvitationsAfterContactApproval(
        childId,
        contactId,
      );
      print('🔄 Procesando invitaciones de grupo pendientes...');

      // Enviar notificación al hijo de que su contacto fue aprobado
      await _notificationService.sendContactApprovedNotification(
        childId: childId,
        contactName: contactName,
      );

      // Opcionalmente, enviar notificación al padre informando de la aprobación automática
      await _notificationService.sendAutoApprovalNotification(
        parentId: parentId,
        childId: childId,
        contactName: contactName,
      );
    } catch (e) {
      print('❌ Error en aprobación automática de contacto: $e');

      // En caso de error, marcar la solicitud con error para revisión manual
      await _firestore.collection('contact_requests').doc(requestId).update({
        'autoApprovalError': e.toString(),
        'autoApprovalFailedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Procesar aprobación automática de permisos de grupo
  Future<void> _processGroupPermissionAutoApproval({
    required String requestId,
    required Map<String, dynamic> requestData,
    required String parentId,
  }) async {
    try {
      print(
        '🔍 Verificando configuración de auto-aprobación para solicitud de grupo: $requestId',
      );

      // Verificar si el padre tiene habilitada la aprobación automática
      final parentSettingsDoc = await _firestore
          .collection('parent_settings')
          .doc(parentId)
          .get();

      if (!parentSettingsDoc.exists) {
        print('⚙️ No hay configuración para este padre, saltando auto-aprobación');
        return;
      }

      final settings = parentSettingsDoc.data() as Map<String, dynamic>;
      final autoApproveEnabled = settings['autoApproveRequests'] ?? false;

      if (!autoApproveEnabled) {
        print('🔒 Auto-aprobación deshabilitada para este padre');
        return;
      }

      print('✅ Auto-aprobación habilitada, procesando solicitud de grupo: $requestId');

      final childId = requestData['childId'];
      final contactInfo = requestData['contactToApprove'] as Map<String, dynamic>?;
      final contactId = contactInfo?['userId'];
      final contactName = contactInfo?['name'] ?? 'Usuario';

      if (contactId == null) {
        print('❌ No se encontró contactId en la solicitud');
        return;
      }

      // Agregar a la lista blanca
      await _firestore.collection('whitelist').add({
        'childId': childId,
        'contactId': contactId,
        'addedAt': FieldValue.serverTimestamp(),
        'approvedBy': parentId,
        'autoApproved': true,
        'approvedForGroup': true,
      });

      // Actualizar solicitud a aprobada
      await _firestore.collection('permission_requests').doc(requestId).update({
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
        'autoApproved': true,
      });

      print('✅ Permiso de grupo aprobado automáticamente');

      // Procesar invitaciones de grupo pendientes
      final groupChatService = GroupChatService();
      await groupChatService.processGroupInvitationsAfterContactApproval(
        childId,
        contactId,
      );

      print('🔄 Procesando invitaciones de grupo pendientes...');

      // Opcionalmente, enviar notificación al padre informando de la auto-aprobación
      await _notificationService.sendAutoApprovalNotification(
        parentId: parentId,
        childId: childId,
        contactName: contactName,
      );
    } catch (e) {
      print('❌ Error en auto-aprobación de permiso de grupo: $e');

      // En caso de error, marcar la solicitud con error para revisión manual
      await _firestore.collection('permission_requests').doc(requestId).update({
        'autoApprovalError': e.toString(),
        'autoApprovalFailedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Detener el servicio de aprobación automática
  void stopAutoApproval() {
    print('🛑 Deteniendo servicio de aprobación automática');
    // Los listeners se pueden cancelar si se almacenan las referencias
    // Por ahora, el listener se mantendrá activo mientras la app esté abierta
  }
}
