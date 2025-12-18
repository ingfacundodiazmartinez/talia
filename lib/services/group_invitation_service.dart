import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';

/// Servicio para manejar invitaciones a grupos con aprobación en cascada
///
/// Flujo:
/// 1. Se crea invitación cuando alguien quiere agregar un miembro
/// 2. Se detectan contactos no aprobados entre el invitado y miembros del grupo
/// 3. Se envían notificaciones a todos los padres involucrados
/// 4. El padre del invitado debe aprobar primero
/// 5. Los padres de los miembros tienen 48h para aprobar/rechazar
/// 6. Si todos aprueban o timeout expira → miembro se agrega al grupo
class GroupInvitationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Crear una invitación a grupo
  ///
  /// Verifica qué miembros del grupo no son contactos aprobados del invitado
  /// y crea una solicitud de invitación con aprobaciones requeridas
  Future<Map<String, dynamic>> createGroupInvitation({
    required String groupId,
    required String invitedChildId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return {'success': false, 'error': 'Usuario no autenticado'};
      }

      // ✅ FIX #5: Use groups_v2 collection (not legacy 'groups')
      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();
      if (!groupDoc.exists) {
        return {'success': false, 'error': 'Grupo no encontrado'};
      }

      final groupData = groupDoc.data()!;
      final groupName = groupData['name'] ?? 'Grupo';
      final members = List<String>.from(groupData['members'] ?? []);

      // Verificar que el invitado no sea ya miembro
      if (members.contains(invitedChildId)) {
        return {'success': false, 'error': 'El usuario ya es miembro del grupo'};
      }

      // Obtener información del invitado
      final invitedUserDoc = await _firestore.collection('users').doc(invitedChildId).get();
      final invitedUserData = invitedUserDoc.data();

      if (invitedUserData == null) {
        return {'success': false, 'error': 'Usuario no encontrado'};
      }

      final userRole = invitedUserData['role'] ?? 'child';
      final isParentOrAdult = userRole == 'parent' || userRole == 'adult';

      // Si el invitado es padre/adulto, agregarlo directamente sin requerir aprobaciones
      if (isParentOrAdult) {
        await _firestore.collection('groups_v2').doc(groupId).update({
          'members': FieldValue.arrayUnion([invitedChildId]),
        });


        return {
          'success': true,
          'requiresApprovals': false,
          'addedDirectly': true,
        };
      }

      // Si es un child, verificar que tenga padre
      final invitedParentId = invitedUserData['parentId'] as String?;

      if (invitedParentId == null) {
        return {'success': false, 'error': 'El niño no tiene padre asignado'};
      }

      // Verificar contactos no aprobados
      final requiredApprovals = await _checkRequiredApprovals(
        invitedChildId: invitedChildId,
        groupMembers: members,
      );

      // Si no hay aprobaciones requeridas, agregar directamente al grupo
      if (requiredApprovals.isEmpty) {
        ReleaseLogger.log(
          '[GroupInvitation] No approvals required, adding directly to group',
          tag: 'GroupInvitationService',
        );
        try {
          await _firestore.collection('groups_v2').doc(groupId).update({
            'members': FieldValue.arrayUnion([invitedChildId]),
          });
        } catch (e) {
          ReleaseLogger.error(
            '[GroupInvitation] Error updating groups.members: $e',
            tag: 'GroupInvitationService',
          );
          return {'success': false, 'error': e.toString()};
        }

        return {
          'success': true,
          'requiresApprovals': false,
          'addedDirectly': true,
        };
      }

      // Hay aprobaciones requeridas - crear invitación y agregar a pendingMembers
      ReleaseLogger.log(
        '[GroupInvitation] Approvals required: ${requiredApprovals.length}, adding to pendingMembers',
        tag: 'GroupInvitationService',
      );

      // Agregar a pendingMembers en el grupo
      try {
        await _firestore.collection('groups_v2').doc(groupId).update({
          'pendingMembers': FieldValue.arrayUnion([invitedChildId]),
        });
      } catch (e) {
        ReleaseLogger.error(
          '[GroupInvitation] Error updating groups.pendingMembers: $e',
          tag: 'GroupInvitationService',
        );
        return {'success': false, 'error': e.toString()};
      }

      // Calcular fecha de expiración (48 horas)
      final expiresAt = DateTime.now().add(const Duration(hours: 48));

      // Crear documento de invitación
      ReleaseLogger.log(
        '[GroupInvitation] Creating invitation document',
        tag: 'GroupInvitationService',
      );

      late DocumentReference invitationRef;
      try {
        // ✅ FIX: Usar 'invitedBy' para coincidir con las reglas de Firestore
        invitationRef = await _firestore.collection('groupInvitations').add({
          'groupId': groupId,
          'groupName': groupName,
          'invitedBy': currentUserId, // ✅ Firestore rule expects 'invitedBy'
          'inviterId': currentUserId, // Keep for backwards compatibility
          'invitedChildId': invitedChildId,
          'status': 'pending_approvals',
          'createdAt': FieldValue.serverTimestamp(),
          'expiresAt': Timestamp.fromDate(expiresAt),
          'requiredApprovals': requiredApprovals,
          'invitedParentApproval': {
            'parentId': invitedParentId,
            'status': 'pending',
            'approvedAt': null,
          },
        });
        ReleaseLogger.log(
          '[GroupInvitation] Invitation created: ${invitationRef.id}',
          tag: 'GroupInvitationService',
        );
      } catch (e) {
        ReleaseLogger.error(
          '[GroupInvitation] Error creating invitation: $e',
          tag: 'GroupInvitationService',
        );
        return {'success': false, 'error': e.toString()};
      }

      // Enviar notificaciones push
      await _sendInvitationNotifications(
        invitationId: invitationRef.id,
        groupName: groupName,
        invitedChildId: invitedChildId,
        invitedParentId: invitedParentId,
        requiredApprovals: requiredApprovals,
      );

      return {
        'success': true,
        'invitationId': invitationRef.id,
        'requiresApprovals': true,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Verificar qué contactos necesitan aprobación
  Future<Map<String, dynamic>> _checkRequiredApprovals({
    required String invitedChildId,
    required List<String> groupMembers,
  }) async {
    final requiredApprovals = <String, dynamic>{};

    for (final memberId in groupMembers) {
      // Verificar si ya son contactos aprobados bidireccionales
      final isApproved = await _areContactsApproved(invitedChildId, memberId);

      if (!isApproved) {
        // Obtener padre del miembro
        final memberDoc = await _firestore.collection('users').doc(memberId).get();
        final parentId = memberDoc.data()?['parentId'] as String?;

        if (parentId != null) {
          requiredApprovals[memberId] = {
            'status': 'pending',
            'parentId': parentId,
            'approvedAt': null,
            'notifiedAt': FieldValue.serverTimestamp(),
          };
        }
      }
    }

    return requiredApprovals;
  }

  /// Verificar si dos usuarios son contactos aprobados bidireccionales
  Future<bool> _areContactsApproved(String userId1, String userId2) async {
    try {
      final contactsSnapshot = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId1)
          .get();

      for (final doc in contactsSnapshot.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);
        final status = data['status'] ?? '';

        if (users.contains(userId2) && status == 'approved') {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Padre del invitado aprueba la invitación
  Future<Map<String, dynamic>> approveInvitationByInvitedParent({
    required String invitationId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return {'success': false, 'error': 'Usuario no autenticado'};
      }

      final invitationDoc = await _firestore
          .collection('groupInvitations')
          .doc(invitationId)
          .get();

      if (!invitationDoc.exists) {
        return {'success': false, 'error': 'Invitación no encontrada'};
      }

      final data = invitationDoc.data()!;
      final invitedParentApproval = data['invitedParentApproval'] as Map<String, dynamic>;

      // Verificar que el usuario actual es el padre del invitado
      if (invitedParentApproval['parentId'] != currentUserId) {
        return {'success': false, 'error': 'No tienes permiso para aprobar esta invitación'};
      }

      // Actualizar aprobación del padre del invitado
      await _firestore.collection('groupInvitations').doc(invitationId).update({
        'invitedParentApproval.status': 'approved',
        'invitedParentApproval.approvedAt': FieldValue.serverTimestamp(),
      });

      // Crear contactos aprobados unilateralmente con los miembros requeridos
      final requiredApprovals = data['requiredApprovals'] as Map<String, dynamic>;
      final invitedChildId = data['invitedChildId'] as String;

      for (final memberId in requiredApprovals.keys) {
        await _createContactApproval(invitedChildId, memberId);
      }


      // El Cloud Function procesará si todos aprobaron
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Padre de un miembro aprueba el contacto con el invitado
  Future<Map<String, dynamic>> approveMemberContact({
    required String invitationId,
    required String memberId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return {'success': false, 'error': 'Usuario no autenticado'};
      }

      final invitationDoc = await _firestore
          .collection('groupInvitations')
          .doc(invitationId)
          .get();

      if (!invitationDoc.exists) {
        return {'success': false, 'error': 'Invitación no encontrada'};
      }

      final data = invitationDoc.data()!;
      final requiredApprovals = data['requiredApprovals'] as Map<String, dynamic>;

      if (!requiredApprovals.containsKey(memberId)) {
        return {'success': false, 'error': 'Miembro no encontrado en aprobaciones'};
      }

      final approval = requiredApprovals[memberId] as Map<String, dynamic>;

      // Verificar que el usuario actual es el padre del miembro
      if (approval['parentId'] != currentUserId) {
        return {'success': false, 'error': 'No tienes permiso para aprobar este contacto'};
      }

      // Actualizar aprobación
      await _firestore.collection('groupInvitations').doc(invitationId).update({
        'requiredApprovals.$memberId.status': 'approved',
        'requiredApprovals.$memberId.approvedAt': FieldValue.serverTimestamp(),
      });


      // El Cloud Function procesará si todos aprobaron
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Rechazar invitación (puede ser padre del invitado o de algún miembro)
  Future<Map<String, dynamic>> rejectInvitation({
    required String invitationId,
    String? memberId, // Si es padre de miembro, especificar memberId
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return {'success': false, 'error': 'Usuario no autenticado'};
      }

      if (memberId != null) {
        // Padre de miembro rechaza
        await _firestore.collection('groupInvitations').doc(invitationId).update({
          'requiredApprovals.$memberId.status': 'rejected',
          'requiredApprovals.$memberId.approvedAt': FieldValue.serverTimestamp(),
          'status': 'rejected',
        });
      } else {
        // Padre del invitado rechaza
        await _firestore.collection('groupInvitations').doc(invitationId).update({
          'invitedParentApproval.status': 'rejected',
          'invitedParentApproval.approvedAt': FieldValue.serverTimestamp(),
          'status': 'rejected',
        });
      }

      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Crear aprobación de contacto unilateral (desde el invitado hacia el miembro)
  /// 🔒 SEGURIDAD: Usa Cloud Function para validación server-side
  Future<void> _createContactApproval(String invitedChildId, String memberId) async {
    try {
      // Obtener parentId del invitado para verificación
      final invitedDoc = await _firestore.collection('users').doc(invitedChildId).get();
      final parentId = invitedDoc.data()?['parentId'] as String?;

      if (parentId == null) {
        ReleaseLogger.error(
          '❌ [GroupInvitation] No parentId found for child $invitedChildId',
          tag: 'GroupInvitationService',
        );
        return;
      }

      // Llamar a Cloud Function para crear contacto de forma segura
      final callable = FirebaseFunctions.instance.httpsCallable('createContactFromGroupInvitation');
      await callable.call({
        'invitedChildId': invitedChildId,
        'memberId': memberId,
        'parentId': parentId,
      });

      ReleaseLogger.log(
        '✅ [GroupInvitation] Contact created via CF: $invitedChildId <-> $memberId',
        tag: 'GroupInvitationService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [GroupInvitation] Error creating contact via CF: $e',
        tag: 'GroupInvitationService',
      );
    }
  }

  /// Obtener invitaciones pendientes para un padre
  Stream<QuerySnapshot> watchPendingInvitationsForParent(String parentId) {
    return _firestore
        .collection('groupInvitations')
        .where('invitedParentApproval.parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending_approvals')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  /// Obtener solicitudes de aprobación de contacto para un padre
  Stream<QuerySnapshot> watchMemberApprovalRequestsForParent(String parentId) {
    // Esto requiere una query compleja, lo implementaremos en el Cloud Function
    // Por ahora retornamos stream vacío
    return _firestore
        .collection('groupInvitations')
        .where('status', isEqualTo: 'pending_approvals')
        .snapshots();
  }

  /// Enviar notificaciones de invitación
  Future<void> _sendInvitationNotifications({
    required String invitationId,
    required String groupName,
    required String invitedChildId,
    required String invitedParentId,
    required Map<String, dynamic> requiredApprovals,
  }) async {
    try {
      // Obtener nombre del invitado
      final invitedDoc = await _firestore.collection('users').doc(invitedChildId).get();
      final invitedName = invitedDoc.data()?['name'] ?? 'Usuario';

      // Notificar al padre del invitado
      await _firestore.collection('notifications').add({
        'userId': invitedParentId,
        'type': 'group_invitation',
        'title': 'Invitación a Grupo',
        'message': 'Tu hijo ha sido invitado al grupo "$groupName"',
        'data': {
          'invitationId': invitationId,
          'groupName': groupName,
          'invitedChildId': invitedChildId,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'read': false,
      });

      // Notificar a padres de miembros que necesitan aprobar
      for (final entry in requiredApprovals.entries) {
        final memberId = entry.key;
        final approval = entry.value as Map<String, dynamic>;
        final parentId = approval['parentId'] as String;

        await _firestore.collection('notifications').add({
          'userId': parentId,
          'type': 'group_member_approval',
          'title': 'Solicitud de Contacto',
          'message': '$invitedName quiere unirse al grupo "$groupName"',
          'data': {
            'invitationId': invitationId,
            'groupName': groupName,
            'invitedChildId': invitedChildId,
            'invitedName': invitedName,
            'memberId': memberId,
          },
          'createdAt': FieldValue.serverTimestamp(),
          'read': false,
        });
      }

    } catch (e) {
    }
  }

  /// Cancelar invitación (solo el creador o padre del invitado)
  Future<Map<String, dynamic>> cancelInvitation(String invitationId) async {
    try {
      await _firestore.collection('groupInvitations').doc(invitationId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });

      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
}
