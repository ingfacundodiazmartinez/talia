import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/contact_request.dart';
import '../models/permission_request.dart';
import '../groups/groups.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio del Control Parental (Lista Blanca)
///
/// Responsabilidades:
/// - Aprobar/rechazar/revocar solicitudes de contactos y grupos
/// - Coordinar llamadas a Cloud Functions y modelos
/// - Manejar errores y proveer mensajes amigables
/// - Gestionar estado de procesamiento de requests
class WhitelistController {
  final String parentId;
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  // Estado de procesamiento
  final Set<String> processingRequests = {};
  final Set<String> selectedRequests = {};

  WhitelistController({
    required this.parentId,
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Aprobar una solicitud individual (contacto o grupo)
  Future<Map<String, dynamic>> approveSingleRequest({
    required String requestId,
    required String childId,
    required Map<String, dynamic> data,
    required String type,
  }) async {
    processingRequests.add(requestId);

    try {
      if (type == 'contact') {
        await _approveContact(
          requestId: requestId,
          childId: childId,
          contactName: data['contactName'] ?? '',
          contactPhone: data['contactPhone'] ?? '',
        );
      } else if (type == 'group') {
        final contactInfo = data['contactToApprove'] as Map<String, dynamic>?;
        await _approveGroupPermission(
          requestId: requestId,
          childId: childId,
          contactId: contactInfo?['userId'] ?? '',
          contactName: contactInfo?['name'] ?? '',
        );
      } else if (type == 'group_v2') {
        await _approveGroupV2Request(
          requestId: requestId,
          groupId: data['groupId'] ?? '',
          childId: childId,
        );
      }

      selectedRequests.remove(requestId);
      processingRequests.remove(requestId);

      return {'success': true};
    } catch (e) {
      processingRequests.remove(requestId);
      return {
        'success': false,
        'error': _getErrorMessage(e),
      };
    }
  }

  /// Aprobar solicitud de grupo V2
  Future<void> _approveGroupV2Request({
    required String requestId,
    required String groupId,
    required String childId,
  }) async {
    ReleaseLogger.log('📞Llamando a Cloud Function approveGroupMembership (Groups V2)...');

    await _functions.httpsCallable('approveGroupMembership').call({
      'requestId': requestId,
      'groupId': groupId,
      'childId': childId,
    });

    ReleaseLogger.log('✅Membresía de grupo V2 aprobada');
  }

  /// Aprobar un contacto via Cloud Function
  Future<void> _approveContact({
    required String requestId,
    required String childId,
    required String contactName,
    required String contactPhone,
  }) async {
    ReleaseLogger.log('📞Llamando a Cloud Function updateContactRequestStatus...');

    final result = await _functions.httpsCallable('updateContactRequestStatus').call({
      'requestId': requestId,
      'status': 'approved',
    });

    ReleaseLogger.log('✅Contacto aprobado: ${result.data}');

    // Procesar invitaciones de grupo pendientes solo si tenemos los datos necesarios
    if (childId.isNotEmpty && contactPhone.isNotEmpty) {
      try {
        ReleaseLogger.log('📨Procesando invitaciones de grupo para el contacto aprobado...');
        ReleaseLogger.log('childId: $childId');
        ReleaseLogger.log('contactPhone: $contactPhone');
        await _functions.httpsCallable('processGroupInvitationsAfterContactApproval').call({
          'childId': childId,
          'contactPhone': contactPhone,
        });
        ReleaseLogger.log('✅Invitaciones de grupo procesadas');
      } catch (e) {
        ReleaseLogger.error('⚠️Error procesando invitaciones de grupo: $e');
        // No lanzar error, es opcional
      }
    } else {
      ReleaseLogger.error('⚠️No se pueden procesar invitaciones: datos faltantes (childId: ${childId.isEmpty ? 'vacío' : 'ok'}, contactPhone: ${contactPhone.isEmpty ? 'vacío' : 'ok'})');
    }
  }

  /// Aprobar permiso de grupo via Cloud Function
  Future<void> _approveGroupPermission({
    required String requestId,
    required String childId,
    required String contactId,
    required String contactName,
  }) async {
    ReleaseLogger.log('📞Llamando a Cloud Function approveGroupPermission...');

    await _functions.httpsCallable('approveGroupPermission').call({
      'requestId': requestId,
      'childId': childId,
      'contactId': contactId,
      'contactName': contactName,
    });

    ReleaseLogger.log('✅Permiso de grupo aprobado');
  }

  /// Rechazar una solicitud individual
  Future<Map<String, dynamic>> rejectSingleRequest({
    required String requestId,
    required String type,
  }) async {
    try {
      if (type == 'contact') {
        ReleaseLogger.log('📞Llamando a Cloud Function updateContactRequestStatus para rechazar...');
        await _functions.httpsCallable('updateContactRequestStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });
        ReleaseLogger.log('✅Solicitud de contacto rechazada via Cloud Function');
      } else if (type == 'group') {
        // Usar Cloud Function para permission_requests también
        await _functions.httpsCallable('updateGroupPermissionStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });
        ReleaseLogger.log('✅Solicitud de grupo rechazada via Cloud Function');
      } else if (type == 'group_v2') {
        // Rechazar solicitud de grupo V2
        await _functions.httpsCallable('rejectGroupMembership').call({
          'requestId': requestId,
        });
        ReleaseLogger.log('✅Solicitud de grupo V2 rechazada');
      }

      selectedRequests.remove(requestId);

      return {'success': true};
    } catch (e) {
      return {
        'success': false,
        'error': _getErrorMessage(e),
      };
    }
  }

  /// Revocar aprobación de una solicitud
  /// Obtener grupos que comparten childId y contactId
  Future<List<Map<String, dynamic>>> getSharedGroups({
    required String childId,
    required String contactId,
  }) async {
    try {
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: childId)
          .where('isActive', isEqualTo: true)
          .get();

      final sharedGroups = <Map<String, dynamic>>[];

      for (final doc in groupsSnapshot.docs) {
        final data = doc.data();
        final members = List<String>.from(data['members'] ?? []);

        // Verificar si el contactId también es miembro
        if (members.contains(contactId)) {
          sharedGroups.add({
            'id': doc.id,
            'name': data['name'] ?? 'Grupo sin nombre',
            'memberCount': members.length,
          });
        }
      }

      return sharedGroups;
    } catch (e) {
      ReleaseLogger.error('❌Error obteniendo grupos compartidos: $e');
      return [];
    }
  }

  /// Remover a childId de un grupo
  Future<void> removeChildFromGroup({
    required String groupId,
    required String childId,
  }) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([childId]),
      });

      ReleaseLogger.log('✅Niño removido del grupo: $groupId');
    } catch (e) {
      ReleaseLogger.error('❌Error removiendo niño del grupo: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> revokeApproval({
    required String requestId,
    required String childId,
    required String type,
    required Map<String, dynamic> data,
    List<String>? groupsToRemove,
  }) async {
    processingRequests.add(requestId);

    try {
      // Llamar al Cloud Function para cambiar el estado a rejected
      if (type == 'contact') {
        ReleaseLogger.log('🔄Revocando contacto...');
        ReleaseLogger.log('requestId: $requestId');
        ReleaseLogger.log('childId: $childId');
        ReleaseLogger.log('data: $data');

        await _functions.httpsCallable('updateContactRequestStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });

        ReleaseLogger.log('✅Contacto revocado');

        // Remover de grupos si se especificaron
        if (groupsToRemove != null && groupsToRemove.isNotEmpty) {
          for (final groupId in groupsToRemove) {
            await removeChildFromGroup(groupId: groupId, childId: childId);
          }
        }

        // Obtener el contactId para bloquear el chat
        final contactPhone = data['contactPhone'] as String?;
        ReleaseLogger.log('📞contactPhone desde data: $contactPhone');

        if (contactPhone != null) {
          await _blockChatByPhone(childId: childId, contactPhone: contactPhone);
        } else {
          ReleaseLogger.error('⚠️No se encontró contactPhone en data, intentando con contactId directamente');

          // Si no hay contactPhone, intentar con contactId directamente
          final contactId = data['contactId'] as String?;
          if (contactId != null) {
            final currentUserId = _auth.currentUser?.uid;
            ReleaseLogger.log('🔍Bloqueando directamente con contactId: $contactId');
            ReleaseLogger.log('👤Usuario actual (blockedBy): $currentUserId');

            if (currentUserId == null) {
              ReleaseLogger.error('❌ERROR: No hay usuario autenticado');
              throw Exception('Usuario no autenticado');
            }

            // Usar Cloud Function para bloquear el chat
            ReleaseLogger.log('📞Llamando a Cloud Function blockChat...');
            await _functions.httpsCallable('blockChat').call({
              'childId': childId,
              'contactId': contactId,
              'reason': 'Contacto revocado por el padre',
              'blockedBy': currentUserId,
            });
            ReleaseLogger.log('✅Chat bloqueado via Cloud Function');
          } else {
            ReleaseLogger.error('❌ERROR: No se encontró ni contactPhone ni contactId en data');
          }
        }
      } else if (type == 'group') {
        await _functions.httpsCallable('updateGroupPermissionStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });

        ReleaseLogger.log('✅Permiso de grupo revocado');
      }

      processingRequests.remove(requestId);

      return {'success': true};
    } catch (e) {
      processingRequests.remove(requestId);
      return {
        'success': false,
        'error': _getErrorMessage(e),
      };
    }
  }

  /// Re-aprobar una solicitud rechazada
  Future<Map<String, dynamic>> reApproveRequest({
    required String requestId,
    required String childId,
    required Map<String, dynamic> data,
    required String type,
  }) async {
    processingRequests.add(requestId);

    try {
      if (type == 'contact') {
        await _approveContact(
          requestId: requestId,
          childId: childId,
          contactName: data['contactName'] ?? '',
          contactPhone: data['contactPhone'] ?? '',
        );

        // Desbloquear el chat si estaba bloqueado
        final contactId = data['contactId'] as String?;
        if (contactId != null) {
          ReleaseLogger.log('🔓Desbloqueando chat entre $childId y $contactId');
          try {
            await _functions.httpsCallable('unblockChat').call({
              'childId': childId,
              'contactId': contactId,
            });
            ReleaseLogger.log('✅Chat desbloqueado exitosamente');
          } catch (e) {
            ReleaseLogger.error('⚠️Error desbloqueando chat: $e');
            // No lanzar error, el chat puede no haber estado bloqueado
          }
        }
      } else if (type == 'group') {
        final contactInfo = data['contactToApprove'] as Map<String, dynamic>?;
        await _approveGroupPermission(
          requestId: requestId,
          childId: childId,
          contactId: contactInfo?['userId'] ?? '',
          contactName: contactInfo?['name'] ?? '',
        );
      }

      processingRequests.remove(requestId);

      return {'success': true};
    } catch (e) {
      processingRequests.remove(requestId);
      return {
        'success': false,
        'error': _getErrorMessage(e),
      };
    }
  }

  /// Bloquear chat por teléfono de contacto
  Future<void> _blockChatByPhone({
    required String childId,
    required String contactPhone,
  }) async {
    try {
      ReleaseLogger.log('🔍Buscando usuario con teléfono: $contactPhone');

      // Buscar el usuario por teléfono (intentar ambos campos)
      var userQuery = await _firestore
          .collection('users')
          .where('phoneNumber', isEqualTo: contactPhone)
          .limit(1)
          .get();

      // Si no encuentra con phoneNumber, intentar con phone
      if (userQuery.docs.isEmpty) {
        userQuery = await _firestore
            .collection('users')
            .where('phone', isEqualTo: contactPhone)
            .limit(1)
            .get();
      }

      if (userQuery.docs.isNotEmpty) {
        final contactId = userQuery.docs.first.id;
        ReleaseLogger.log('✅Usuario encontrado: $contactId');

        // Bloquear chat usando Cloud Function
        final currentUserId = _auth.currentUser?.uid;
        ReleaseLogger.log('👤Usuario actual (blockedBy) en _blockChatByPhone: $currentUserId');

        if (currentUserId == null) {
          ReleaseLogger.error('❌ERROR: No hay usuario autenticado en _blockChatByPhone');
          throw Exception('Usuario no autenticado');
        }

        ReleaseLogger.log('📞Llamando a Cloud Function blockChat...');
        await _functions.httpsCallable('blockChat').call({
          'childId': childId,
          'contactId': contactId,
          'reason': 'Contacto revocado por el padre',
          'blockedBy': currentUserId,
        });

        ReleaseLogger.log('✅Chat bloqueado exitosamente via Cloud Function');
      } else {
        ReleaseLogger.error('⚠️No se encontró usuario con teléfono: $contactPhone');
      }
    } catch (e) {
      ReleaseLogger.error('❌Error bloqueando chat por teléfono: $e');
    }
  }

  /// Obtener mensaje de error amigable
  String _getErrorMessage(dynamic error) {
    if (error is FirebaseFunctionsException) {
      switch (error.code) {
        case 'failed-precondition':
          return 'Esta solicitud ya fue procesada';
        case 'permission-denied':
          return 'No tienes permiso para realizar esta acción';
        case 'not-found':
          return 'Solicitud no encontrada';
        case 'unauthenticated':
          return 'Debes iniciar sesión nuevamente';
        default:
          return error.message ?? 'Error al procesar solicitud';
      }
    }
    return error.toString();
  }

  /// Obtener IDs de hijos vinculados
  /// ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds por seguridad
  Stream<List<String>> getLinkedChildrenIdsStream() {
    return _firestore
        .collection('users')
        .doc(parentId)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) return <String>[];
      final userData = snapshot.data();
      return List<String>.from(userData?['linkedChildrenIds'] ?? []);
    });
  }

  /// Obtener solicitudes de contacto pendientes
  Stream<List<ContactRequest>> getPendingContactRequests() {
    return ContactRequest.getPendingByParent(parentId);
  }

  /// Obtener solicitudes de permisos pendientes
  Stream<List<PermissionRequest>> getPendingPermissionRequests() {
    return PermissionRequest.getPendingByParent(parentId);
  }

  /// Obtener solicitudes de contacto aprobadas
  Stream<List<ContactRequest>> getApprovedContactRequests() {
    return ContactRequest.getApprovedByParent(parentId);
  }

  /// Obtener solicitudes de permisos aprobadas
  Stream<List<PermissionRequest>> getApprovedPermissionRequests() {
    return PermissionRequest.getApprovedByParent(parentId);
  }

  /// Obtener solicitudes de contacto rechazadas
  Stream<List<ContactRequest>> getRejectedContactRequests() {
    return ContactRequest.getRejectedByParent(parentId);
  }

  /// Obtener solicitudes de permisos rechazadas
  Stream<List<PermissionRequest>> getRejectedPermissionRequests() {
    return PermissionRequest.getRejectedByParent(parentId);
  }

  // ============== Groups V2 Approval Requests ==============

  final GroupApprovalRepository _groupApprovalRepository = GroupApprovalRepository();

  /// Obtener solicitudes de grupos V2 pendientes
  Stream<List<GroupApprovalRequest>> getPendingGroupApprovalRequests() {
    return _groupApprovalRepository.watchPendingRequestsForParent(parentId);
  }

  /// Combinar solicitudes pendientes de contactos, permisos y grupos V2
  List<Map<String, dynamic>> combinePendingRequests({
    required List<ContactRequest> contactRequests,
    required List<PermissionRequest> permissionRequests,
    List<GroupApprovalRequest>? groupApprovalRequests,
  }) {
    final requests = <Map<String, dynamic>>[];

    // Agregar contact_requests
    for (final request in contactRequests) {
      requests.add({
        'requestId': request.id,
        'childId': request.childId,
        'type': 'contact',
        'data': request.toMap()..['childId'] = request.childId,
      });
    }

    // Agregar permission_requests (legacy)
    for (final request in permissionRequests) {
      requests.add({
        'requestId': request.id,
        'childId': request.childId,
        'type': 'group',
        'data': request.toMap()..['childId'] = request.childId,
      });
    }

    // Agregar group_approval_requests (Groups V2)
    if (groupApprovalRequests != null) {
      for (final request in groupApprovalRequests) {
        requests.add({
          'requestId': request.id,
          'childId': request.childId,
          'type': 'group_v2',
          'data': {
            'groupId': request.groupId,
            'groupName': request.groupName,
            'groupAvatar': request.groupAvatar,
            'groupDescription': request.groupDescription,
            'childId': request.childId,
            'childName': request.childName,
            'invitedBy': request.groupCreatorId,
            'inviterName': request.groupCreatorName,
            'createdAt': request.createdAt,
            'members': request.members.map((m) => m.toMap()).toList(),
          },
        });
      }
    }

    return requests;
  }

  /// Combinar solicitudes aprobadas de contactos y permisos
  List<Map<String, dynamic>> combineApprovedRequests({
    required List<ContactRequest> contactRequests,
    required List<PermissionRequest> permissionRequests,
  }) {
    final requests = <Map<String, dynamic>>[];

    // Agregar contact_requests aprobados
    for (final request in contactRequests) {
      requests.add({
        'requestId': request.id,
        'type': 'contact',
        'data': request.toMap()..['childId'] = request.childId,
      });
    }

    // Agregar permission_requests aprobados
    for (final request in permissionRequests) {
      requests.add({
        'requestId': request.id,
        'type': 'group',
        'data': request.toMap()..['childId'] = request.childId,
      });
    }

    return requests;
  }

  /// Combinar solicitudes rechazadas de contactos y permisos
  List<Map<String, dynamic>> combineRejectedRequests({
    required List<ContactRequest> contactRequests,
    required List<PermissionRequest> permissionRequests,
  }) {
    final requests = <Map<String, dynamic>>[];

    // Agregar contact_requests rechazados
    for (final request in contactRequests) {
      requests.add({
        'requestId': request.id,
        'childId': request.childId,
        'type': 'contact',
        'data': request.toMap()..['childId'] = request.childId,
      });
    }

    // Agregar permission_requests rechazados
    for (final request in permissionRequests) {
      requests.add({
        'requestId': request.id,
        'childId': request.childId,
        'type': 'group',
        'data': request.toMap()..['childId'] = request.childId,
      });
    }

    return requests;
  }

  /// Limpiar recursos
  void dispose() {
    processingRequests.clear();
    selectedRequests.clear();
  }
}
