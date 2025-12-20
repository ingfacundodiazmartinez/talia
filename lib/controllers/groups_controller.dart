import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../services/chats/groups/group_services.dart';
import '../utils/release_logger.dart';

/// Controller unificado para grupos
///
/// Coordina entre Screen y los servicios atómicos de grupos.
/// Sigue el patrón: Screen → Controller → Service → Model
///
/// Responsabilidades:
/// - Crear y gestionar grupos
/// - Administrar miembros
/// - Gestionar roles de admin
class GroupsController with ChangeNotifier {
  // === DEPENDENCIAS ===
  final FirebaseAuth _auth;
  final CreateGroupService _createService;
  final UpdateGroupService _updateService;
  final DeleteGroupService _deleteService;
  final AddMemberService _addMemberService;
  final RemoveMemberService _removeMemberService;
  final LeaveGroupService _leaveService;
  final ListMembersService _listMembersService;
  final PromoteAdminService _promoteService;
  final DemoteAdminService _demoteService;

  // === ESTADO ===
  bool _isLoading = false;
  String? _error;

  // === GETTERS ===
  String? get currentUserId => _auth.currentUser?.uid;
  bool get isLoading => _isLoading;
  String? get error => _error;

  GroupsController({
    FirebaseAuth? auth,
    CreateGroupService? createService,
    UpdateGroupService? updateService,
    DeleteGroupService? deleteService,
    AddMemberService? addMemberService,
    RemoveMemberService? removeMemberService,
    LeaveGroupService? leaveService,
    ListMembersService? listMembersService,
    PromoteAdminService? promoteService,
    DemoteAdminService? demoteService,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _createService = createService ?? CreateGroupService(),
        _updateService = updateService ?? UpdateGroupService(),
        _deleteService = deleteService ?? DeleteGroupService(),
        _addMemberService = addMemberService ?? AddMemberService(),
        _removeMemberService = removeMemberService ?? RemoveMemberService(),
        _leaveService = leaveService ?? LeaveGroupService(),
        _listMembersService = listMembersService ?? ListMembersService(),
        _promoteService = promoteService ?? PromoteAdminService(),
        _demoteService = demoteService ?? DemoteAdminService();

  // === CREAR GRUPO ===

  /// Crear un nuevo grupo
  Future<({bool success, String? groupId, String message})> createGroup({
    required String name,
    required List<String> memberIds,
    String? description,
    String? photoUrl,
  }) async {
    _setLoading(true);

    try {
      final result = await _createService.call(
        name: name,
        memberIds: memberIds,
        description: description,
        photoUrl: photoUrl,
      );

      _error = result.success ? null : result.message;
      return result;
    } catch (e) {
      _error = 'Error creando grupo: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return (success: false, groupId: null, message: _error!);
    } finally {
      _setLoading(false);
    }
  }

  // === ACTUALIZAR GRUPO ===

  /// Actualizar nombre del grupo
  Future<bool> updateGroupName({
    required String groupId,
    required String newName,
  }) async {
    _setLoading(true);

    try {
      final result = await _updateService.updateName(
        groupId: groupId,
        newName: newName,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error actualizando nombre: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Actualizar descripción del grupo
  Future<bool> updateGroupDescription({
    required String groupId,
    required String newDescription,
  }) async {
    _setLoading(true);

    try {
      final result = await _updateService.updateDescription(
        groupId: groupId,
        newDescription: newDescription,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error actualizando descripción: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Actualizar foto del grupo
  Future<bool> updateGroupPhoto({
    required String groupId,
    required String? photoUrl,
  }) async {
    _setLoading(true);

    try {
      final result = await _updateService.updatePhoto(
        groupId: groupId,
        photoUrl: photoUrl,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error actualizando foto: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // === ELIMINAR GRUPO ===

  /// Eliminar grupo permanentemente
  Future<bool> deleteGroup(String groupId) async {
    _setLoading(true);

    try {
      final result = await _deleteService.call(groupId: groupId);
      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error eliminando grupo: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Verificar si puede eliminar el grupo
  Future<bool> canDeleteGroup(String groupId) async {
    final result = await _deleteService.canDelete(groupId: groupId);
    return result.canDelete;
  }

  // === MIEMBROS ===

  /// Agregar miembro al grupo
  Future<bool> addMember({
    required String groupId,
    required String memberId,
  }) async {
    _setLoading(true);

    try {
      final result = await _addMemberService.call(
        groupId: groupId,
        memberId: memberId,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error agregando miembro: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Agregar múltiples miembros
  Future<({bool success, int addedCount})> addMultipleMembers({
    required String groupId,
    required List<String> memberIds,
  }) async {
    _setLoading(true);

    try {
      final result = await _addMemberService.addMultiple(
        groupId: groupId,
        memberIds: memberIds,
      );

      _error = result.success ? null : result.message;
      return (success: result.success, addedCount: result.addedCount);
    } catch (e) {
      _error = 'Error agregando miembros: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return (success: false, addedCount: 0);
    } finally {
      _setLoading(false);
    }
  }

  /// Remover miembro del grupo
  Future<bool> removeMember({
    required String groupId,
    required String memberId,
  }) async {
    _setLoading(true);

    try {
      final result = await _removeMemberService.call(
        groupId: groupId,
        memberId: memberId,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error removiendo miembro: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Salir del grupo
  Future<bool> leaveGroup(String groupId) async {
    _setLoading(true);

    try {
      final result = await _leaveService.call(groupId: groupId);
      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error saliendo del grupo: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Verificar si puede salir del grupo
  Future<bool> canLeaveGroup(String groupId) async {
    final result = await _leaveService.canLeave(groupId: groupId);
    return result.canLeave;
  }

  /// Obtener lista de miembros
  Future<List<GroupMemberInfo>> getMembers(String groupId) async {
    final result = await _listMembersService.call(groupId: groupId);
    return result.members;
  }

  /// Stream de miembros
  Stream<List<GroupMemberInfo>> watchMembers(String groupId) {
    return _listMembersService.watch(groupId: groupId);
  }

  /// Verificar si el usuario actual es admin
  Future<bool> isCurrentUserAdmin(String groupId) async {
    return await _listMembersService.isAdmin(groupId: groupId);
  }

  /// Verificar si el usuario actual es miembro
  Future<bool> isCurrentUserMember(String groupId) async {
    return await _listMembersService.isMember(groupId: groupId);
  }

  /// Contar miembros del grupo
  Future<int> getMemberCount(String groupId) async {
    return await _listMembersService.count(groupId: groupId);
  }

  // === ADMINISTRADORES ===

  /// Promover miembro a admin
  Future<bool> promoteToAdmin({
    required String groupId,
    required String memberId,
  }) async {
    _setLoading(true);

    try {
      final result = await _promoteService.call(
        groupId: groupId,
        memberId: memberId,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error promoviendo admin: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Quitar admin de miembro
  Future<bool> demoteAdmin({
    required String groupId,
    required String memberId,
  }) async {
    _setLoading(true);

    try {
      final result = await _demoteService.call(
        groupId: groupId,
        memberId: memberId,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error degradando admin: $e';
      ReleaseLogger.error(_error!, tag: 'GroupsController');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Verificar si un admin puede ser degradado
  Future<bool> canDemoteAdmin({
    required String groupId,
    required String memberId,
  }) async {
    final result = await _demoteService.canDemote(
      groupId: groupId,
      memberId: memberId,
    );
    return result.canDemote;
  }

  // === HELPERS ===

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
