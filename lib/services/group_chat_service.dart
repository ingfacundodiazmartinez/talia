import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../notification_service.dart';
import '../utils/release_logger.dart';
import 'chat_permission_service.dart';

class GroupChatService {
  static final GroupChatService _instance = GroupChatService._internal();
  factory GroupChatService() => _instance;
  GroupChatService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();
  final ChatPermissionService _permissionService = ChatPermissionService();

  // Cache en memoria para grupos del usuario
  final Map<String, List<GroupChat>> _cachedUserGroups = {};
  final Map<String, DateTime> _lastGroupsCacheUpdate = {};

  // Crear nuevo grupo
  Future<GroupCreationResult> createGroup({
    required String name,
    String? description,
    String? avatar,
    required List<String> initialMembers,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return GroupCreationResult.error('Usuario no autenticado');
      }

      ReleaseLogger.log('🎯 Creando grupo via Cloud Function: $name con ${initialMembers.length} miembros', tag: 'GroupChatService');

      // ✅ Llamar a Cloud Function en lugar de crear directamente
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createGroup',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );

      final result = await callable.call({
        'name': name,
        'description': description,
        'avatar': avatar,
        'initialMembers': initialMembers,
      });

      final data = result.data as Map<String, dynamic>;

      if (data['success'] == true) {
        final groupId = data['groupId'] as String;
        final approvedMembers = List<String>.from(data['approvedMembers'] ?? []);
        final pendingMembers = List<String>.from(data['pendingMembers'] ?? []);

        ReleaseLogger.log('✅ Grupo creado exitosamente: $groupId', tag: 'GroupChatService');
        ReleaseLogger.log('✅ Miembros aprobados: ${approvedMembers.length}', tag: 'GroupChatService');
        ReleaseLogger.log('⏳ Miembros pendientes: ${pendingMembers.length}', tag: 'GroupChatService');

        if (pendingMembers.isEmpty) {
          return GroupCreationResult.success(groupId, approvedMembers);
        } else {
          return GroupCreationResult.partialSuccess(
            groupId: groupId,
            approvedMembers: approvedMembers,
            pendingMembers: pendingMembers,
            pendingCount: pendingMembers.length,
          );
        }
      } else {
        return GroupCreationResult.error(data['message'] ?? 'Error desconocido');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error creando grupo: $e', tag: 'GroupChatService');
      return GroupCreationResult.error('Error creando grupo: $e');
    }
  }

  // Verificar y procesar invitaciones pendientes cuando se aprueban contactos
  Future<void> processGroupInvitationsAfterContactApproval(
    String childId,
    String contactId,
  ) async {
    try {
      ReleaseLogger.log(
        '🔄 Procesando invitaciones pendientes después de aprobar contacto',
        tag: 'GroupChatService',
      );

      // Buscar invitaciones para el child
      final childInvitations = await _firestore
          .collection('group_invitations')
          .where('invitedUserId', isEqualTo: childId)
          .where('status', isEqualTo: 'pending')
          .get();

      // Buscar invitaciones para el contact
      final contactInvitations = await _firestore
          .collection('group_invitations')
          .where('invitedUserId', isEqualTo: contactId)
          .where('status', isEqualTo: 'pending')
          .get();

      // Combinar ambas listas
      final allInvitations = [...childInvitations.docs, ...contactInvitations.docs];

      for (final invitationDoc in allInvitations) {
        final invitationData = invitationDoc.data();
        final invitedUserId = invitationData['invitedUserId'];
        final groupId = invitationData['groupId'];

        // Re-validar permisos para esta invitación
        await _revalidateGroupInvitation(
          invitationDoc.id,
          groupId,
          invitedUserId,
        );
      }

      ReleaseLogger.log('✅ Procesadas ${allInvitations.length} invitaciones pendientes', tag: 'GroupChatService');
    } catch (e) {
      ReleaseLogger.error('❌ Error procesando invitaciones pendientes: $e', tag: 'GroupChatService');
    }
  }

  // Re-validar una invitación específica
  Future<void> _revalidateGroupInvitation(
    String invitationId,
    String groupId,
    String invitedUserId,
  ) async {
    try {
      // Obtener miembros actuales del grupo
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();
      final groupData = groupDoc.data();
      final currentMembers = List<String>.from(groupData?['members'] ?? []);

      // Verificar si el usuario invitado puede unirse al grupo usando el nuevo servicio
      final canJoin = await _permissionService.canUserJoinGroup(
        invitedUserId,
        currentMembers,
      );

      if (canJoin) {
        // Todos los permisos están otorgados, agregar al grupo
        await _addMemberToGroup(groupId, invitedUserId);

        // Marcar invitación como aprobada
        await _firestore
            .collection('group_invitations')
            .doc(invitationId)
            .update({
              'status': 'approved',
              'approvedAt': FieldValue.serverTimestamp(),
            });

        // Notificar al usuario que fue agregado al grupo
        await _notificationService.sendGroupMembershipApproved(
          userId: invitedUserId,
          groupName: groupData?['name'] ?? 'Grupo',
        );

        ReleaseLogger.log('✅ Usuario agregado al grupo automáticamente: $invitedUserId', tag: 'GroupChatService');
      } else {
        // Obtener permisos faltantes específicos
        final missingApprovals = <Map<String, dynamic>>[];

        for (final memberId in currentMembers) {
          final permissionResult = await _permissionService.canUsersChat(
            invitedUserId,
            memberId,
          );
          if (!permissionResult.isAllowed &&
              permissionResult.missingApprovals != null) {
            for (final approval in permissionResult.missingApprovals!) {
              missingApprovals.add({
                'fromUserId': approval.childId,
                'toUserId': approval.contactId,
                'direction': approval.childId == invitedUserId
                    ? 'outgoing'
                    : 'incoming',
                'status': 'pending',
              });
            }
          }
        }

        // Actualizar permisos faltantes en la invitación
        await _firestore
            .collection('group_invitations')
            .doc(invitationId)
            .update({
              'missingPermissions': missingApprovals,
              'updatedAt': FieldValue.serverTimestamp(),
            });

        ReleaseLogger.log('⏳ Invitación actualizada, aún faltan permisos: $invitationId', tag: 'GroupChatService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error re-validando invitación: $e', tag: 'GroupChatService');
    }
  }

  // Agregar miembro al grupo
  Future<void> _addMemberToGroup(String groupId, String userId) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayUnion([userId]),
        'lastActivity': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('✅ Miembro agregado al grupo: $userId', tag: 'GroupChatService');
    } catch (e) {
      ReleaseLogger.error('❌ Error agregando miembro al grupo: $e', tag: 'GroupChatService');
      rethrow;
    }
  }

  // Salir de un grupo (Groups V2)
  Future<void> leaveGroup(String groupId, String userId) async {
    try {
      ReleaseLogger.log('👋 Usuario $userId saliendo del grupo $groupId via Cloud Function', tag: 'GroupChatService');

      // ✅ FIX: Usar Cloud Function leaveGroupV2 en lugar de escritura directa
      // La Cloud Function maneja:
      // - Validación de permisos
      // - Eliminar grupo si es el último miembro
      // - Actualización atómica de members array
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('leaveGroupV2').call({
        'groupId': groupId,
      });

      final data = result.data as Map<String, dynamic>;
      if (data['success'] == true) {
        final groupDeleted = data['groupDeleted'] == true;
        if (groupDeleted) {
          ReleaseLogger.log('✅ Grupo eliminado (era el último miembro)', tag: 'GroupChatService');
        } else {
          ReleaseLogger.log('✅ Usuario removido del grupo exitosamente', tag: 'GroupChatService');
        }
      } else {
        throw Exception(data['error'] ?? 'Error desconocido al salir del grupo');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error saliendo del grupo: $e', tag: 'GroupChatService');
      rethrow;
    }
  }

  // Obtener grupos del usuario
  Stream<List<GroupChat>> getUserGroups(String userId) async* {
    // Emitir cache inmediatamente si existe para este usuario
    if (_cachedUserGroups.containsKey(userId)) {
      ReleaseLogger.log('📦 Emitiendo grupos desde cache para usuario $userId', tag: 'GroupChatService');
      yield _cachedUserGroups[userId]!;
    }

    // Escuchar cambios en grupos
    // ✅ handleError evita crashes cuando el usuario es removido de un grupo
    await for (final snapshot in _firestore
        .collection('groups')
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.log('Stream de grupos cerrado para $userId (sin permisos)', tag: 'GroupChatService');
        })) {

      final groups = snapshot.docs.map((doc) {
        final data = doc.data();
        return GroupChat.fromFirestore(data, doc.id);
      }).toList();

      // Actualizar cache para este usuario
      _cachedUserGroups[userId] = groups;
      _lastGroupsCacheUpdate[userId] = DateTime.now();

      ReleaseLogger.log('🔄 Grupos actualizados desde Firestore para usuario $userId (${groups.length} grupos)', tag: 'GroupChatService');
      yield groups;
    }
  }

  // Obtener grupos del usuario (una sola vez con cache)
  Future<QuerySnapshot> getUserGroupsSnapshot(String userId) async {
    // Si hay cache reciente (menos de 5 segundos), devolverlo
    final cachedGroups = _cachedUserGroups[userId];
    final lastUpdate = _lastGroupsCacheUpdate[userId];

    if (cachedGroups != null && lastUpdate != null) {
      final cacheAge = DateTime.now().difference(lastUpdate);
      if (cacheAge.inSeconds < 5) {
        ReleaseLogger.log('📦 Usando grupos desde cache (${cachedGroups.length} grupos)', tag: 'GroupChatService');
        // Convertir de vuelta a QuerySnapshot simulado
        // Por ahora, hacemos fetch pero silenciosamente
      }
    }

    // Fetch desde Firestore
    final snapshot = await _firestore
        .collection('groups')
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .get();

    // Actualizar cache
    final groups = snapshot.docs.map((doc) {
      final data = doc.data();
      return GroupChat.fromFirestore(data, doc.id);
    }).toList();

    _cachedUserGroups[userId] = groups;
    _lastGroupsCacheUpdate[userId] = DateTime.now();

    return snapshot;
  }

  // Obtener invitaciones pendientes del usuario
  Stream<List<GroupInvitation>> getUserPendingInvitations(String userId) {
    return _firestore
        .collection('group_invitations')
        .where('invitedUserId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return GroupInvitation.fromFirestore(data, doc.id);
          }).toList();
        });
  }
}

// Modelos de datos
class GroupChat {
  final String id;
  final String name;
  final String description;
  final String? avatar;
  final String createdBy;
  final List<String> members;
  final List<String> admins;
  final DateTime createdAt;
  final DateTime lastActivity;
  final int messageCount;
  final bool isActive;

  GroupChat({
    required this.id,
    required this.name,
    required this.description,
    this.avatar,
    required this.createdBy,
    required this.members,
    required this.admins,
    required this.createdAt,
    required this.lastActivity,
    required this.messageCount,
    required this.isActive,
  });

  factory GroupChat.fromFirestore(Map<String, dynamic> data, String id) {
    return GroupChat(
      id: id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      avatar: data['avatar'],
      createdBy: data['createdBy'] ?? '',
      members: List<String>.from(data['members'] ?? []),
      admins: List<String>.from(data['admins'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastActivity:
          (data['lastActivity'] as Timestamp?)?.toDate() ?? DateTime.now(),
      messageCount: data['messageCount'] ?? 0,
      isActive: data['isActive'] ?? true,
    );
  }
}

class GroupInvitation {
  final String id;
  final String groupId;
  final String invitedUserId;
  final String invitedBy;
  final String status;
  final List<MissingPermission> missingPermissions;
  final DateTime createdAt;
  final DateTime expiresAt;

  GroupInvitation({
    required this.id,
    required this.groupId,
    required this.invitedUserId,
    required this.invitedBy,
    required this.status,
    required this.missingPermissions,
    required this.createdAt,
    required this.expiresAt,
  });

  factory GroupInvitation.fromFirestore(Map<String, dynamic> data, String id) {
    final missingPermsList =
        (data['missingPermissions'] as List<dynamic>?)?.map((mp) {
          return MissingPermission(
            fromUserId: mp['fromUserId'] ?? '',
            toUserId: mp['toUserId'] ?? '',
            direction: mp['direction'] ?? '',
          );
        }).toList() ??
        [];

    return GroupInvitation(
      id: id,
      groupId: data['groupId'] ?? '',
      invitedUserId: data['invitedUserId'] ?? '',
      invitedBy: data['invitedBy'] ?? '',
      status: data['status'] ?? '',
      missingPermissions: missingPermsList,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

// Clases de resultado
class GroupCreationResult {
  final GroupCreationStatus status;
  final String? groupId;
  final List<String>? approvedMembers;
  final List<String>? pendingMembers;
  final int pendingCount;
  final String? error;

  GroupCreationResult._({
    required this.status,
    this.groupId,
    this.approvedMembers,
    this.pendingMembers,
    this.pendingCount = 0,
    this.error,
  });

  factory GroupCreationResult.success(String groupId, List<String> members) {
    return GroupCreationResult._(
      status: GroupCreationStatus.success,
      groupId: groupId,
      approvedMembers: members,
    );
  }

  factory GroupCreationResult.partialSuccess({
    required String groupId,
    required List<String> approvedMembers,
    required List<String> pendingMembers,
    required int pendingCount,
  }) {
    return GroupCreationResult._(
      status: GroupCreationStatus.partialSuccess,
      groupId: groupId,
      approvedMembers: approvedMembers,
      pendingMembers: pendingMembers,
      pendingCount: pendingCount,
    );
  }

  factory GroupCreationResult.error(String error) {
    return GroupCreationResult._(
      status: GroupCreationStatus.error,
      error: error,
    );
  }

  bool get isSuccess => status == GroupCreationStatus.success;
  bool get isPartialSuccess => status == GroupCreationStatus.partialSuccess;
  bool get isError => status == GroupCreationStatus.error;
}

enum GroupCreationStatus { success, partialSuccess, error }

class GroupPermissionsResult {
  final bool allPermissionsGranted;
  final List<String> approvedMembers;
  final List<PendingMember> pendingMembers;

  GroupPermissionsResult({
    required this.allPermissionsGranted,
    required this.approvedMembers,
    required this.pendingMembers,
  });
}

class UserPermissionsResult {
  final bool hasAllPermissions;
  final List<MissingPermission> missingPermissions;

  UserPermissionsResult({
    required this.hasAllPermissions,
    required this.missingPermissions,
  });
}

class PendingMember {
  final String userId;
  final List<MissingPermission> missingPermissions;

  PendingMember({required this.userId, required this.missingPermissions});
}

class MissingPermission {
  final String fromUserId;
  final String toUserId;
  final String direction; // 'outgoing' o 'incoming'

  MissingPermission({
    required this.fromUserId,
    required this.toUserId,
    required this.direction,
  });
}
