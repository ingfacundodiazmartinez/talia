import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import '../repositories/chat_repository.dart';
import '../models/group_member.dart';
import '../managers/chat_cache_manager.dart';
import '../utils/chat_exceptions.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado para gestión de grupos y miembros
///
/// Responsabilidades:
/// - Gestión de estados de miembros (pending/approved/blocked/admin)
/// - Validación de permisos por estado de miembro
/// - Promoción/degradación de miembros
/// - Workflow de aprobación parental
/// - Streams reactivos de cambios en miembros
class GroupManagementService {
  final ChatRepository _chatRepository;
  final ChatCacheManager _cacheManager;
  final FirebaseAuth _auth;

  // Stream controllers para notificaciones reactivas
  final Map<String, StreamController<GroupMemberList>> _memberControllers = {};

  GroupManagementService({
    required ChatRepository chatRepository,
    required ChatCacheManager cacheManager,
    FirebaseAuth? auth,
  }) : _chatRepository = chatRepository,
       _cacheManager = cacheManager,
       _auth = auth ?? FirebaseAuth.instance;

  // ═══════════════════════════════════════════════════════════════
  // MEMBER MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Obtener lista de miembros de un grupo
  Future<GroupMemberList> getGroupMembers(String groupId) async {
    try {
      final members = await _chatRepository.getGroupMembers(groupId);
      return GroupMemberList(members);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo miembros del grupo $groupId: $e');
      throw Exception('Error obteniendo miembros del grupo');
    }
  }

  /// Stream reactivo de cambios en miembros de un grupo
  Stream<GroupMemberList> getGroupMembersStream(String groupId) {
    if (!_memberControllers.containsKey(groupId)) {
      _memberControllers[groupId] = StreamController<GroupMemberList>.broadcast();

      // Iniciar escucha de cambios en Firestore
      _startListeningToMemberChanges(groupId);
    }

    return Stream.multi((controller) {
      // Emitir estado inicial
      getGroupMembers(groupId).then((members) {
        controller.add(members);
      }).catchError((e) {
        controller.addError(e);
      });

      // Escuchar cambios futuros
      final subscription = _memberControllers[groupId]!.stream.listen(
        controller.add,
        onError: controller.addError,
      );

      controller.onCancel = () => subscription.cancel();
    });
  }

  /// Agregar miembro a grupo con estado específico
  Future<void> addMemberToGroup({
    required String groupId,
    required String userId,
    required String displayName,
    GroupMemberStatus initialStatus = GroupMemberStatus.pending,
    String? photoUrl,
    Map<String, dynamic>? metadata,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // Verificar que el usuario actual es admin del grupo
    await _validateUserIsAdmin(groupId, currentUserId);

    try {
      final newMember = GroupMember(
        userId: userId,
        displayName: displayName,
        photoUrl: photoUrl,
        status: initialStatus,
        joinedAt: DateTime.now(),
        metadata: metadata,
      );

      await _chatRepository.addGroupMember(groupId, newMember);

      ReleaseLogger.info('✅ Miembro $userId agregado al grupo $groupId con estado ${initialStatus.value}');

      // Invalidar cache
      _cacheManager.invalidateChatCache(groupId);

      // Notificar cambios
      _notifyMemberChanges(groupId);

    } catch (e) {
      ReleaseLogger.error('Error agregando miembro $userId al grupo $groupId: $e');
      rethrow;
    }
  }

  /// Actualizar estado de miembro
  Future<void> updateMemberStatus({
    required String groupId,
    required String userId,
    required GroupMemberStatus newStatus,
    String? reason,
    String? approvedBy,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    try {
      final membersList = await getGroupMembers(groupId);
      final member = membersList.findMember(userId);

      if (member == null) {
        throw Exception('Miembro $userId no encontrado en grupo $groupId');
      }

      // Validar permisos para cambio de estado
      await _validateStatusChange(groupId, currentUserId, member, newStatus);

      final updatedMember = member.copyWith(
        status: newStatus,
        approvedAt: newStatus == GroupMemberStatus.approved ? DateTime.now() : member.approvedAt,
        approvedBy: newStatus == GroupMemberStatus.approved ? (approvedBy ?? currentUserId) : member.approvedBy,
        blockedAt: newStatus == GroupMemberStatus.blocked ? DateTime.now() : member.blockedAt,
        blockedBy: newStatus == GroupMemberStatus.blocked ? currentUserId : member.blockedBy,
        blockReason: newStatus == GroupMemberStatus.blocked ? reason : member.blockReason,
      );

      await _chatRepository.updateGroupMember(groupId, updatedMember);

      ReleaseLogger.info('✅ Estado de miembro $userId actualizado a ${newStatus.value} en grupo $groupId');

      // Invalidar cache y notificar
      _cacheManager.invalidateChatCache(groupId);
      _notifyMemberChanges(groupId);

    } catch (e) {
      ReleaseLogger.error('Error actualizando estado de miembro $userId: $e');
      rethrow;
    }
  }

  /// Remover miembro del grupo
  Future<void> removeMemberFromGroup({
    required String groupId,
    required String userId,
    String? reason,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // Verificar permisos
    await _validateUserIsAdmin(groupId, currentUserId);

    try {
      await _chatRepository.removeGroupMember(groupId, userId);

      ReleaseLogger.info('✅ Miembro $userId removido del grupo $groupId');

      // Invalidar cache y notificar
      _cacheManager.invalidateChatCache(groupId);
      _notifyMemberChanges(groupId);

    } catch (e) {
      ReleaseLogger.error('Error removiendo miembro $userId: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PERMISSION VALIDATION
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si usuario puede ver grupo
  Future<bool> canViewGroup(String userId, String groupId) async {
    try {
      final members = await getGroupMembers(groupId);
      return members.canUserViewMessages(userId);
    } catch (e) {
      ReleaseLogger.error('Error verificando permisos de vista para $userId en grupo $groupId: $e');
      return false;
    }
  }

  /// Verificar si usuario puede enviar mensajes al grupo
  Future<bool> canSendToGroup(String userId, String groupId) async {
    try {
      final members = await getGroupMembers(groupId);
      return members.canUserSendMessages(userId);
    } catch (e) {
      ReleaseLogger.error('Error verificando permisos de envío para $userId en grupo $groupId: $e');
      return false;
    }
  }

  /// Verificar si usuario es admin del grupo
  Future<bool> isUserGroupAdmin(String userId, String groupId) async {
    try {
      final members = await getGroupMembers(groupId);
      return members.isUserAdmin(userId);
    } catch (e) {
      ReleaseLogger.error('Error verificando admin para $userId en grupo $groupId: $e');
      return false;
    }
  }

  /// Obtener estado de miembro específico
  Future<GroupMemberStatus?> getMemberStatus(String groupId, String userId) async {
    try {
      final members = await getGroupMembers(groupId);
      return members.findMember(userId)?.status;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo estado de miembro $userId: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PARENTAL APPROVAL WORKFLOW
  // ═══════════════════════════════════════════════════════════════

  /// Aprobar miembro pendiente (por parent)
  Future<void> approvePendingMember({
    required String groupId,
    required String userId,
    required String parentId,
  }) async {
    try {
      await updateMemberStatus(
        groupId: groupId,
        userId: userId,
        newStatus: GroupMemberStatus.approved,
        approvedBy: parentId,
      );

      ReleaseLogger.info('✅ Miembro $userId aprobado por parent $parentId en grupo $groupId');

    } catch (e) {
      ReleaseLogger.error('Error aprobando miembro $userId: $e');
      rethrow;
    }
  }

  /// Rechazar/bloquear miembro pendiente (por parent)
  Future<void> rejectPendingMember({
    required String groupId,
    required String userId,
    required String parentId,
    String? reason,
  }) async {
    try {
      await updateMemberStatus(
        groupId: groupId,
        userId: userId,
        newStatus: GroupMemberStatus.blocked,
        reason: reason ?? 'Rechazado por control parental',
      );

      ReleaseLogger.info('✅ Miembro $userId rechazado por parent $parentId en grupo $groupId');

    } catch (e) {
      ReleaseLogger.error('Error rechazando miembro $userId: $e');
      rethrow;
    }
  }

  /// Obtener miembros pendientes de aprobación de un parent específico
  Future<List<GroupMember>> getPendingMembersForParent(String parentId) async {
    try {
      // TODO: Implementar query específico por parent cuando tengamos contactRepository
      // Por ahora retornamos lista vacía
      return <GroupMember>[];
    } catch (e) {
      ReleaseLogger.error('Error obteniendo miembros pendientes para parent $parentId: $e');
      return <GroupMember>[];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ADMIN OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Promover miembro a admin
  Future<void> promoteToAdmin({
    required String groupId,
    required String userId,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    await _validateUserIsAdmin(groupId, currentUserId);

    await updateMemberStatus(
      groupId: groupId,
      userId: userId,
      newStatus: GroupMemberStatus.admin,
    );

    ReleaseLogger.info('✅ Miembro $userId promovido a admin en grupo $groupId');
  }

  /// Degradar admin a miembro regular
  Future<void> demoteFromAdmin({
    required String groupId,
    required String userId,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    await _validateUserIsAdmin(groupId, currentUserId);

    await updateMemberStatus(
      groupId: groupId,
      userId: userId,
      newStatus: GroupMemberStatus.approved,
    );

    ReleaseLogger.info('✅ Admin $userId degradado a miembro en grupo $groupId');
  }

  // ═══════════════════════════════════════════════════════════════
  // PRIVATE VALIDATION METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Validar que usuario es admin del grupo
  Future<void> _validateUserIsAdmin(String groupId, String userId) async {
    if (!await isUserGroupAdmin(userId, groupId)) {
      throw InsufficientPermissionsException(
        'Usuario $userId no es admin del grupo $groupId',
        userId: userId,
        requiredPermission: 'admin',
        operation: 'group_management',
      );
    }
  }

  /// Validar cambio de estado de miembro
  Future<void> _validateStatusChange(
    String groupId,
    String currentUserId,
    GroupMember member,
    GroupMemberStatus newStatus,
  ) async {
    // Solo admins pueden cambiar estados
    await _validateUserIsAdmin(groupId, currentUserId);

    // No se puede cambiar el estado del creador del grupo
    if (member.status == GroupMemberStatus.admin && member.userId != currentUserId) {
      // Solo el propio admin puede cambiar su estado
      throw InsufficientPermissionsException(
        'No puedes cambiar el estado de otro administrador',
        userId: currentUserId,
        requiredPermission: 'self_admin',
        operation: 'change_admin_status',
      );
    }
  }

  /// Iniciar escucha de cambios en miembros
  void _startListeningToMemberChanges(String groupId) {
    // TODO: Implementar listener real de Firestore
    // Por ahora usamos polling básico
    Timer.periodic(Duration(seconds: 30), (timer) {
      if (_memberControllers[groupId]?.isClosed == true) {
        timer.cancel();
        return;
      }

      getGroupMembers(groupId).then((members) {
        _notifyMemberChanges(groupId, members);
      }).catchError((e) {
        ReleaseLogger.error('Error en polling de miembros para grupo $groupId: $e');
      });
    });
  }

  /// Notificar cambios en miembros
  void _notifyMemberChanges(String groupId, [GroupMemberList? members]) {
    if (_memberControllers[groupId] != null && !_memberControllers[groupId]!.isClosed) {
      if (members != null) {
        _memberControllers[groupId]!.add(members);
      } else {
        // Obtener miembros actualizados
        getGroupMembers(groupId).then((updatedMembers) {
          if (!_memberControllers[groupId]!.isClosed) {
            _memberControllers[groupId]!.add(updatedMembers);
          }
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar recursos
  void dispose() {
    for (final controller in _memberControllers.values) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    _memberControllers.clear();
  }
}