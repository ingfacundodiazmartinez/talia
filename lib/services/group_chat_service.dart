import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../notification_service.dart';
import 'chat_permission_service.dart';
import 'user_role_service.dart';

class GroupChatService {
  static final GroupChatService _instance = GroupChatService._internal();
  factory GroupChatService() => _instance;
  GroupChatService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();
  final ChatPermissionService _permissionService = ChatPermissionService();

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

      print('🎯 Creando grupo: $name con ${initialMembers.length} miembros');

      // Verificar permisos con el creador para cada miembro
      final approvedMembers = <String>[currentUserId]; // El creador siempre está aprobado
      final pendingMembers = <String>[];

      for (final memberId in initialMembers) {
        final result = await _permissionService.canUsersChat(currentUserId, memberId);
        if (result.isAllowed) {
          approvedMembers.add(memberId);
        } else {
          pendingMembers.add(memberId);
        }
      }

      print('✅ Miembros aprobados: ${approvedMembers.length}, Pendientes: ${pendingMembers.length}');

      if (pendingMembers.isEmpty) {
        // Todos los permisos están otorgados
        final groupId = await _createGroupDocument(
          name: name,
          description: description,
          avatar: avatar,
          members: approvedMembers,
          createdBy: currentUserId,
        );

        return GroupCreationResult.success(groupId, approvedMembers);
      } else {
        // Hay miembros pendientes - crear el grupo con los miembros aprobados
        final groupId = await _createGroupDocument(
          name: name,
          description: description,
          avatar: avatar,
          members: approvedMembers,
          createdBy: currentUserId,
        );

        print('🔔 Creando invitaciones y solicitudes de permiso para ${pendingMembers.length} miembros pendientes');

        // Obtener nombre del creador para las notificaciones
        final creatorDoc = await _firestore.collection('users').doc(currentUserId).get();
        final creatorName = creatorDoc.data()?['name'] ?? 'Usuario';

        // Crear invitaciones pendientes para miembros sin permisos
        for (final pendingMemberId in pendingMembers) {
          // Solo necesitamos la aprobación entre el creador y este miembro pendiente
          final result = await _permissionService.canUsersChat(currentUserId, pendingMemberId);

          // Crear invitación pendiente
          await _createPendingInvitation(
            groupId: groupId,
            invitedUserId: pendingMemberId,
            missingPermissions: [
              MissingPermission(
                fromUserId: currentUserId,
                toUserId: pendingMemberId,
                direction: 'between_creator_and_member',
              ),
            ],
            invitedBy: currentUserId,
          );

          // Solicitar permiso al padre del niño si es necesario
          if (result.missingApprovals != null && result.missingApprovals!.isNotEmpty) {
            final approval = result.missingApprovals!.first;
            await _sendPermissionRequestToParent(
              childId: approval.childId,
              groupId: groupId,
              groupName: name,
              inviterName: creatorName,
              invitedUserId: approval.contactId,
              missingPermissions: [
                MissingPermission(
                  fromUserId: approval.childId,
                  toUserId: approval.contactId,
                  direction: 'needs_approval',
                ),
              ],
            );
          }
        }

        return GroupCreationResult.partialSuccess(
          groupId: groupId,
          approvedMembers: approvedMembers,
          pendingMembers: pendingMembers,
          pendingCount: pendingMembers.length,
        );
      }
    } catch (e) {
      print('❌ Error creando grupo: $e');
      return GroupCreationResult.error('Error creando grupo: $e');
    }
  }

  // DEPRECATED: Métodos antiguos reemplazados por ChatPermissionService
  // Se mantienen temporalmente para compatibilidad, pero ya no se usan

  // Crear documento del grupo en Firestore
  Future<String> _createGroupDocument({
    required String name,
    String? description,
    String? avatar,
    required List<String> members,
    required String createdBy,
  }) async {
    try {
      final groupRef = await _firestore.collection('groups').add({
        'name': name,
        'description': description ?? '',
        'avatar': avatar,
        'createdBy': createdBy,
        'createdAt': FieldValue.serverTimestamp(),
        'isActive': true,
        'members': members,
        'admins': [createdBy],
        'settings': {
          'maxMembers': 10,
          'allowMemberInvites': true,
          'requireAdminApproval': false,
        },
        'lastActivity': FieldValue.serverTimestamp(),
        'messageCount': 0,
      });

      print('✅ Grupo creado con ID: ${groupRef.id}');
      return groupRef.id;
    } catch (e) {
      print('❌ Error creando documento del grupo: $e');
      rethrow;
    }
  }

  // Crear invitación pendiente
  Future<void> _createPendingInvitation({
    required String groupId,
    required String invitedUserId,
    required List<MissingPermission> missingPermissions,
    required String invitedBy,
  }) async {
    try {
      await _firestore.collection('group_invitations').add({
        'groupId': groupId,
        'invitedUserId': invitedUserId,
        'invitedBy': invitedBy,
        'status': 'pending',
        'missingPermissions': missingPermissions
            .map(
              (mp) => {
                'fromUserId': mp.fromUserId,
                'toUserId': mp.toUserId,
                'direction': mp.direction,
                'status': 'pending',
              },
            )
            .toList(),
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(DateTime.now().add(Duration(days: 7))),
      });

      // Enviar notificaciones a padres para aprobar contactos faltantes
      await _sendPermissionRequestsToParents(
        groupId: groupId,
        invitedUserId: invitedUserId,
        missingPermissions: missingPermissions,
        invitedBy: invitedBy,
      );

      print('✅ Invitación pendiente creada para usuario: $invitedUserId');
    } catch (e) {
      print('❌ Error creando invitación pendiente: $e');
      rethrow;
    }
  }

  // Enviar solicitudes de permiso a padres
  Future<void> _sendPermissionRequestsToParents({
    required String groupId,
    required String invitedUserId,
    required List<MissingPermission> missingPermissions,
    required String invitedBy,
  }) async {
    try {
      // Obtener información del grupo e invitador
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();
      final groupData = groupDoc.data();

      final inviterDoc = await _firestore
          .collection('users')
          .doc(invitedBy)
          .get();
      final inviterData = inviterDoc.data();

      // Agrupar permisos faltantes por niño (para evitar múltiples notificaciones)
      final permissionsByChild = <String, List<MissingPermission>>{};

      for (final permission in missingPermissions) {
        final childId = permission.direction == 'outgoing'
            ? permission.fromUserId
            : permission.toUserId;

        if (!permissionsByChild.containsKey(childId)) {
          permissionsByChild[childId] = [];
        }
        permissionsByChild[childId]!.add(permission);
      }

      // Enviar notificación a cada padre
      for (final entry in permissionsByChild.entries) {
        final childId = entry.key;
        final permissions = entry.value;

        await _sendPermissionRequestToParent(
          childId: childId,
          groupId: groupId,
          groupName: groupData?['name'] ?? 'Grupo',
          inviterName: inviterData?['name'] ?? 'Usuario',
          invitedUserId: invitedUserId,
          missingPermissions: permissions,
        );
      }
    } catch (e) {
      print('❌ Error enviando solicitudes a padres: $e');
    }
  }

  // Enviar solicitud individual a todos los padres de un niño
  Future<void> _sendPermissionRequestToParent({
    required String childId,
    required String groupId,
    required String groupName,
    required String inviterName,
    required String invitedUserId,
    required List<MissingPermission> missingPermissions,
  }) async {
    try {
      // Obtener datos del hijo
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childData = childDoc.data();
      final childName = childData?['name'] ?? 'Tu hijo';

      // Obtener todos los padres vinculados
      final userRoleService = UserRoleService();
      final linkedParents = await userRoleService.getLinkedParents(childId);

      if (linkedParents.isEmpty) {
        print('⚠️ No se encontraron padres vinculados para el niño: $childId');
        return;
      }

      // Obtener información del contacto a aprobar
      final contactDoc = await _firestore
          .collection('users')
          .doc(invitedUserId)
          .get();
      final contactData = contactDoc.data();

      // Crear solicitud de permiso para cada padre vinculado
      for (final parentId in linkedParents) {
        await _firestore.collection('permission_requests').add({
          'type': 'group_invitation',
          'childId': childId,
          'parentId': parentId,
          'groupInfo': {
            'groupId': groupId,
            'groupName': groupName,
            'invitedBy': inviterName,
          },
          'contactToApprove': {
            'userId': invitedUserId,
            'name': contactData?['name'] ?? 'Usuario',
            'email': contactData?['email'] ?? '',
          },
          'missingPermissions': missingPermissions
              .map(
                (mp) => {
                  'fromUserId': mp.fromUserId,
                  'toUserId': mp.toUserId,
                  'direction': mp.direction,
                },
              )
              .toList(),
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Enviar notificación push al padre
        await _notificationService.sendGroupInvitationPermissionRequest(
          parentId: parentId,
          childName: childName,
          groupName: groupName,
          contactName: contactData?['name'] ?? 'Usuario',
          inviterName: inviterName,
        );

        print('✅ Solicitud enviada al padre $parentId del niño: $childId');
      }

      print('✅ Solicitudes enviadas a ${linkedParents.length} padre(s)');
    } catch (e) {
      print('❌ Error enviando solicitud a padres: $e');
    }
  }

  // Verificar y procesar invitaciones pendientes cuando se aprueban contactos
  Future<void> processGroupInvitationsAfterContactApproval(
    String childId,
    String contactId,
  ) async {
    try {
      print(
        '🔄 Procesando invitaciones pendientes después de aprobar contacto',
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

      print('✅ Procesadas ${allInvitations.length} invitaciones pendientes');
    } catch (e) {
      print('❌ Error procesando invitaciones pendientes: $e');
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

        print('✅ Usuario agregado al grupo automáticamente: $invitedUserId');
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

        print('⏳ Invitación actualizada, aún faltan permisos: $invitationId');
      }
    } catch (e) {
      print('❌ Error re-validando invitación: $e');
    }
  }

  // Agregar miembro al grupo
  Future<void> _addMemberToGroup(String groupId, String userId) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayUnion([userId]),
        'lastActivity': FieldValue.serverTimestamp(),
      });

      print('✅ Miembro agregado al grupo: $userId');
    } catch (e) {
      print('❌ Error agregando miembro al grupo: $e');
      rethrow;
    }
  }

  // Salir de un grupo
  Future<void> leaveGroup(String groupId, String userId) async {
    try {
      print('👋 Usuario $userId saliendo del grupo $groupId');

      // Remover al usuario usando arrayRemove (operación atómica permitida por Firestore)
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([userId]),
        'lastActivity': FieldValue.serverTimestamp(),
      });

      print('✅ Usuario removido del grupo exitosamente');

      // Nota: Si el grupo queda sin miembros, no aparecerá en las consultas
      // porque usamos arrayContains en la query. No es necesario marcarlo como inactivo.
    } catch (e) {
      print('❌ Error saliendo del grupo: $e');
      rethrow;
    }
  }

  // Obtener grupos del usuario
  Stream<List<GroupChat>> getUserGroups(String userId) {
    return _firestore
        .collection('groups')
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return GroupChat.fromFirestore(data, doc.id);
          }).toList();
        });
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
