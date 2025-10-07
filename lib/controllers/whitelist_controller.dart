import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/contact_request.dart';
import '../models/permission_request.dart';
import '../services/chat_block_service.dart';

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

  /// Aprobar un contacto via Cloud Function
  Future<void> _approveContact({
    required String requestId,
    required String childId,
    required String contactName,
    required String contactPhone,
  }) async {
    print('📞 Llamando a Cloud Function updateContactRequestStatus...');

    final result = await _functions.httpsCallable('updateContactRequestStatus').call({
      'requestId': requestId,
      'status': 'approved',
    });

    print('✅ Contacto aprobado: ${result.data}');

    // Procesar invitaciones de grupo pendientes
    await _processGroupInvitations(
      childId: childId,
      contactPhone: contactPhone,
    );
  }

  /// Aprobar permiso de grupo via Cloud Function
  Future<void> _approveGroupPermission({
    required String requestId,
    required String childId,
    required String contactId,
    required String contactName,
  }) async {
    print('📞 Llamando a Cloud Function approveGroupPermission...');

    await _functions.httpsCallable('approveGroupPermission').call({
      'requestId': requestId,
      'childId': childId,
      'contactId': contactId,
      'contactName': contactName,
    });

    print('✅ Permiso de grupo aprobado');
  }

  /// Procesar invitaciones de grupo pendientes después de aprobar un contacto
  Future<void> _processGroupInvitations({
    required String childId,
    required String contactPhone,
  }) async {
    try {
      print('🔄 Procesando invitaciones de grupo pendientes...');

      await _functions.httpsCallable('processGroupInvitationsAfterContactApproval').call({
        'childId': childId,
        'contactPhone': contactPhone,
      });

      print('✅ Invitaciones de grupo procesadas');
    } catch (e) {
      print('❌ Error procesando invitaciones pendientes: $e');
      rethrow;
    }
  }

  /// Rechazar una solicitud individual
  Future<Map<String, dynamic>> rejectSingleRequest({
    required String requestId,
    required String type,
  }) async {
    try {
      if (type == 'contact') {
        print('📞 Llamando a Cloud Function updateContactRequestStatus para rechazar...');
        await _functions.httpsCallable('updateContactRequestStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });
        print('✅ Solicitud de contacto rechazada via Cloud Function');
      } else if (type == 'group') {
        // Usar Cloud Function para permission_requests también
        await _functions.httpsCallable('updateGroupPermissionStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });
        print('✅ Solicitud de grupo rechazada via Cloud Function');
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
  Future<Map<String, dynamic>> revokeApproval({
    required String requestId,
    required String childId,
    required String type,
    required Map<String, dynamic> data,
  }) async {
    processingRequests.add(requestId);

    try {
      // Llamar al Cloud Function para cambiar el estado a rejected
      if (type == 'contact') {
        await _functions.httpsCallable('updateContactRequestStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });

        print('✅ Contacto revocado');

        // Obtener el contactId para bloquear el chat
        final contactPhone = data['contactPhone'] as String?;
        if (contactPhone != null) {
          await _blockChatByPhone(childId: childId, contactPhone: contactPhone);
        }
      } else if (type == 'group') {
        await _functions.httpsCallable('updateGroupPermissionStatus').call({
          'requestId': requestId,
          'status': 'rejected',
        });

        print('✅ Permiso de grupo revocado');
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
    // Buscar el usuario por teléfono
    final userQuery = await _firestore
        .collection('users')
        .where('phone', isEqualTo: contactPhone)
        .limit(1)
        .get();

    if (userQuery.docs.isNotEmpty) {
      final contactId = userQuery.docs.first.id;

      // Bloquear chat
      final chatBlockService = ChatBlockService();
      await chatBlockService.blockChat(
        childId: childId,
        contactId: contactId,
        reason: 'Contacto revocado por el padre',
        blockedBy: _auth.currentUser?.uid,
      );
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
  Stream<List<String>> getLinkedChildrenIdsStream() {
    return _firestore
        .collection('parent_children')
        .where('parentId', isEqualTo: parentId)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => doc.data()['childId'] as String)
          .where((id) => id.isNotEmpty)
          .toList();
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

  /// Combinar solicitudes pendientes de contactos y permisos
  List<Map<String, dynamic>> combinePendingRequests({
    required List<ContactRequest> contactRequests,
    required List<PermissionRequest> permissionRequests,
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

    // Agregar permission_requests
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
