import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../notification_service.dart';
import 'group_chat_service.dart';
import '../utils/release_logger.dart';

/// Servicio de aprobación automática de contactos
///
/// Escucha contactos pendientes donde el padre tiene auto-approve habilitado
/// y los aprueba automáticamente.
class AutoApprovalService {
  static final AutoApprovalService _instance = AutoApprovalService._internal();
  factory AutoApprovalService() => _instance;
  AutoApprovalService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();

  // Subscriptions para cancelar al detener
  final List<StreamSubscription> _subscriptions = [];

  // Track de contactos ya procesados para evitar duplicados
  final Set<String> _processedContactIds = {};

  /// Inicializar el servicio de aprobación automática para un padre
  Future<void> startAutoApprovalForParent(String parentId) async {
    ReleaseLogger.log(
      '🚀 [AutoApproval] Iniciando para padre: $parentId',
      tag: 'AutoApproval',
    );

    // Escuchar contactos donde el padre puede aprobar
    // Query: parentViewers contains parentId
    final subscription = _firestore
        .collection('contacts')
        .where('parentViewers', arrayContains: parentId)
        .snapshots()
        .listen(
          (snapshot) async {
            for (final change in snapshot.docChanges) {
              if (change.type == DocumentChangeType.added ||
                  change.type == DocumentChangeType.modified) {
                final contactId = change.doc.id;
                final contactData = change.doc.data();

                if (contactData == null) continue;

                // Verificar si hay aprobaciones pendientes para este padre
                final approvals = contactData['approvals'] as Map<String, dynamic>? ?? {};

                for (final entry in approvals.entries) {
                  final childId = entry.key;
                  final approval = entry.value as Map<String, dynamic>?;

                  if (approval == null) continue;

                  final status = approval['status'] as String?;
                  final assignedParentId = approval['parentId'] as String?;

                  // Solo procesar si está pendiente y asignado a este padre
                  if (status == 'pending' && assignedParentId == parentId) {
                    final processKey = '${contactId}_$childId';

                    // Evitar procesar el mismo contacto múltiples veces
                    if (_processedContactIds.contains(processKey)) continue;
                    _processedContactIds.add(processKey);

                    await _processAutoApproval(
                      contactId: contactId,
                      contactData: contactData,
                      childId: childId,
                      parentId: parentId,
                    );
                  }
                }
              }
            }
          },
          onError: (error) {
            ReleaseLogger.error(
              '❌ [AutoApproval] Error en stream de contactos: $error',
              tag: 'AutoApproval',
            );
          },
          cancelOnError: false,
        );

    _subscriptions.add(subscription);

    // Escuchar nuevas solicitudes de permiso de grupo (mantener para grupos)
    final groupSubscription = _firestore
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
              '❌ [AutoApproval] Error en stream de permisos de grupo: $error',
              tag: 'AutoApproval',
            );
          },
          cancelOnError: false,
        );

    _subscriptions.add(groupSubscription);
  }

  /// Resuelve la auto-aprobación de contactos para un hijo: usa el valor por
  /// hijo si existe (padres con >1 hijo) y cae al flag global si no.
  bool _resolveContactAutoApprove(Map<String, dynamic> settings, String? childId) {
    final perChild = settings['childAutoApproveRequests'];
    if (childId != null && perChild is Map && perChild.containsKey(childId)) {
      return perChild[childId] == true;
    }
    return settings['autoApproveRequests'] == true;
  }

  /// Procesar aprobación automática si está habilitada
  Future<void> _processAutoApproval({
    required String contactId,
    required Map<String, dynamic> contactData,
    required String childId,
    required String parentId,
  }) async {
    try {
      // Verificar si el padre tiene habilitada la aprobación automática
      final parentSettingsDoc = await _firestore
          .collection('parent_settings')
          .doc(parentId)
          .get();

      if (!parentSettingsDoc.exists) {
        ReleaseLogger.log(
          '⏭️ [AutoApproval] No hay settings para padre $parentId',
          tag: 'AutoApproval',
        );
        return;
      }

      final settings = parentSettingsDoc.data() as Map<String, dynamic>;
      final autoApproveEnabled = _resolveContactAutoApprove(settings, childId);

      if (!autoApproveEnabled) {
        ReleaseLogger.log(
          '⏭️ [AutoApproval] Auto-approve deshabilitado para padre $parentId / hijo $childId',
          tag: 'AutoApproval',
        );
        return;
      }

      // Obtener el otro usuario del contacto
      final users = List<String>.from(contactData['users'] ?? []);
      final otherUserId = users.firstWhere(
        (id) => id != childId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) {
        ReleaseLogger.error(
          '❌ [AutoApproval] No se encontró otro usuario en contacto $contactId',
          tag: 'AutoApproval',
        );
        return;
      }

      // Obtener nombre del contacto
      final otherUserDoc = await _firestore.collection('users').doc(otherUserId).get();
      final contactName = (otherUserDoc.data()?['name'] as String?) ?? 'Usuario';

      // Aprobar el contacto
      await _autoApproveContact(
        contactId: contactId,
        childId: childId,
        otherUserId: otherUserId,
        contactName: contactName,
        parentId: parentId,
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AutoApproval] Error procesando auto-aprobación: $e',
        tag: 'AutoApproval',
      );
    }
  }

  /// Aprobar automáticamente un contacto
  Future<void> _autoApproveContact({
    required String contactId,
    required String childId,
    required String otherUserId,
    required String contactName,
    required String parentId,
  }) async {
    try {
      ReleaseLogger.log(
        '✅ [AutoApproval] Auto-aprobando contacto $contactId para hijo $childId',
        tag: 'AutoApproval',
      );

      // Actualizar directamente el documento contacts
      await _firestore.collection('contacts').doc(contactId).update({
        'approvals.$childId.status': 'approved',
        'approvals.$childId.approvedBy': parentId,
        'approvals.$childId.approvedAt': FieldValue.serverTimestamp(),
      });

      // Verificar si todas las aprobaciones están completas para actualizar status general
      final updatedDoc = await _firestore.collection('contacts').doc(contactId).get();
      final updatedData = updatedDoc.data();

      if (updatedData != null) {
        final approvals = updatedData['approvals'] as Map<String, dynamic>? ?? {};
        final allApproved = approvals.values.every((a) {
          final approval = a as Map<String, dynamic>?;
          return approval?['status'] == 'approved';
        });

        if (allApproved && approvals.isNotEmpty) {
          await _firestore.collection('contacts').doc(contactId).update({
            'status': 'approved',
          });
        }
      }

      // Procesar invitaciones de grupo pendientes
      final groupChatService = GroupChatService();
      await groupChatService.processGroupInvitationsAfterContactApproval(
        childId,
        otherUserId,
      );

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

      ReleaseLogger.log(
        '✅ [AutoApproval] Contacto $contactId auto-aprobado exitosamente',
        tag: 'AutoApproval',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AutoApproval] Error auto-aprobando contacto: $e',
        tag: 'AutoApproval',
      );
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
      final childIdForSettings = requestData['childId'] as String?;
      final autoApproveEnabled =
          _resolveContactAutoApprove(settings, childIdForSettings);

      if (!autoApproveEnabled) {
        return;
      }

      final childId = requestData['childId'];
      final contactInfo = requestData['contactToApprove'] as Map<String, dynamic>?;
      final contactId = contactInfo?['userId'];
      final contactName = contactInfo?['name'] ?? 'Usuario';

      if (contactId == null || childId == null) {
        return;
      }

      // Generar ID de contacto y verificar/crear
      final users = [childId as String, contactId as String]..sort();
      final contactDocId = '${users[0]}_${users[1]}';

      // Verificar si ya existe el contacto
      final existingContact = await _firestore.collection('contacts').doc(contactDocId).get();

      if (existingContact.exists) {
        // Actualizar approval existente
        await _firestore.collection('contacts').doc(contactDocId).update({
          'approvals.$childId.status': 'approved',
          'approvals.$childId.approvedBy': parentId,
          'approvals.$childId.approvedAt': FieldValue.serverTimestamp(),
        });
      } else {
        // Crear nuevo contacto aprobado
        await _firestore.collection('contacts').doc(contactDocId).set({
          'users': users,
          'status': 'approved',
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': childId,
          'createdVia': 'group_auto_approval',
          'autoApproved': true,
          'parentViewers': [parentId],
          'approvals': {
            childId: {
              'status': 'approved',
              'parentId': parentId,
              'approvedBy': parentId,
              'approvedAt': FieldValue.serverTimestamp(),
            },
          },
        });
      }

      // Marcar permission_request como procesado
      await _firestore.collection('permission_requests').doc(requestId).update({
        'status': 'approved',
        'approvedBy': parentId,
        'approvedAt': FieldValue.serverTimestamp(),
        'autoApproved': true,
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

      ReleaseLogger.log(
        '✅ [AutoApproval] Permiso de grupo auto-aprobado para $contactName',
        tag: 'AutoApproval',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AutoApproval] Error en auto-aprobación de grupo: $e',
        tag: 'AutoApproval',
      );

      // En caso de error, marcar la solicitud con error para revisión manual
      await _firestore.collection('permission_requests').doc(requestId).update({
        'autoApprovalError': e.toString(),
        'autoApprovalFailedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Detener el servicio de aprobación automática
  void stopAutoApproval() {
    ReleaseLogger.log(
      '🛑 [AutoApproval] Deteniendo servicio',
      tag: 'AutoApproval',
    );

    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _processedContactIds.clear();
  }
}
