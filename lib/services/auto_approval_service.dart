import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

      // Usar Cloud Function para aprobar
      print('📞 Llamando a Cloud Function updateContactRequestStatus (auto-approval)...');
      final callable = FirebaseFunctions.instance.httpsCallable('updateContactRequestStatus');
      await callable.call({
        'requestId': requestId,
        'status': 'approved',
      });

      print('✅ Cloud Function ejecutada exitosamente (auto-approval)');

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
          print('🔄 Procesando invitaciones de grupo pendientes...');
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
      print('❌ Error en aprobación automática de contacto: $e');
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

      // Crear o actualizar entrada en contacts
      final participants = [childId, contactId]..sort();

      // Verificar si ya existe el contacto
      final existingContacts = await _firestore
          .collection('contacts')
          .where('users', arrayContains: childId)
          .get();

      bool contactExists = false;
      String? contactDocId;

      for (final doc in existingContacts.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);
        if (users.contains(contactId)) {
          contactExists = true;
          contactDocId = doc.id;
          break;
        }
      }

      if (!contactExists) {
        // Crear nuevo contacto
        final newContact = await _firestore.collection('contacts').add({
          'users': participants,
          'user1Name': '',
          'user2Name': '',
          'user1Email': '',
          'user2Email': '',
          'status': 'approved',
          'autoApproved': true,
          'addedAt': FieldValue.serverTimestamp(),
          'addedBy': parentId,
          'addedVia': 'group_approval',
          'approvedForGroup': true,
        });
        contactDocId = newContact.id;
        print('✅ Nuevo contacto creado para grupo: $contactDocId');
      } else {
        // Actualizar existente a approved
        await _firestore.collection('contacts').doc(contactDocId).update({
          'status': 'approved',
          'approvedForGroup': true,
          'autoApproved': true,
        });
        print('✅ Contacto existente actualizado: $contactDocId');
      }

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

      // Enviar notificación al padre informando de la auto-aprobación
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
