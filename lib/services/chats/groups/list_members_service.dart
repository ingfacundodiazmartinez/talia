import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Modelo de miembro de grupo
class GroupMemberInfo {
  final String id;
  final bool isAdmin;
  final bool isCreator;

  const GroupMemberInfo({
    required this.id,
    required this.isAdmin,
    required this.isCreator,
  });
}

/// Servicio atómico: Listar miembros de grupo
///
/// Responsabilidad única: Obtener lista de miembros con sus roles
class ListMembersService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  ListMembersService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Obtener lista de miembros del grupo
  ///
  /// [groupId] - ID del grupo
  ///
  /// Retorna (success, members, message)
  Future<({bool success, List<GroupMemberInfo> members, String message})> call({
    required String groupId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          members: <GroupMemberInfo>[],
          message: 'Usuario no autenticado',
        );
      }

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) {
        return (
          success: false,
          members: <GroupMemberInfo>[],
          message: 'Grupo no encontrado',
        );
      }

      final data = groupDoc.data()!;
      final members = List<String>.from(data['members'] ?? []);
      final admins = Set<String>.from(data['admins'] ?? []);
      final createdBy = data['createdBy'] as String?;

      // Verificar que el usuario es miembro
      if (!members.contains(userId)) {
        return (
          success: false,
          members: <GroupMemberInfo>[],
          message: 'No eres miembro del grupo',
        );
      }

      // Construir lista de miembros con roles
      final memberList = members.map((memberId) {
        return GroupMemberInfo(
          id: memberId,
          isAdmin: admins.contains(memberId),
          isCreator: memberId == createdBy,
        );
      }).toList();

      // Ordenar: creador primero, luego admins, luego el resto
      memberList.sort((a, b) {
        if (a.isCreator) return -1;
        if (b.isCreator) return 1;
        if (a.isAdmin && !b.isAdmin) return -1;
        if (b.isAdmin && !a.isAdmin) return 1;
        return 0;
      });

      return (
        success: true,
        members: memberList,
        message: 'OK',
      );
    } catch (e) {
      ReleaseLogger.error('Error listando miembros: $e', tag: 'ListMembers');
      return (
        success: false,
        members: <GroupMemberInfo>[],
        message: 'Error al listar miembros',
      );
    }
  }

  /// Stream de miembros del grupo
  Stream<List<GroupMemberInfo>> watch({required String groupId}) {
    return _firestore
        .collection('groups_v2')
        .doc(groupId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) return <GroupMemberInfo>[];

      final data = doc.data()!;
      final members = List<String>.from(data['members'] ?? []);
      final admins = Set<String>.from(data['admins'] ?? []);
      final createdBy = data['createdBy'] as String?;

      final memberList = members.map((memberId) {
        return GroupMemberInfo(
          id: memberId,
          isAdmin: admins.contains(memberId),
          isCreator: memberId == createdBy,
        );
      }).toList();

      memberList.sort((a, b) {
        if (a.isCreator) return -1;
        if (b.isCreator) return 1;
        if (a.isAdmin && !b.isAdmin) return -1;
        if (b.isAdmin && !a.isAdmin) return 1;
        return 0;
      });

      return memberList;
    });
  }

  /// Contar miembros del grupo
  Future<int> count({required String groupId}) async {
    try {
      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) return 0;

      final members = List<String>.from(groupDoc.data()?['members'] ?? []);
      return members.length;
    } catch (e) {
      return 0;
    }
  }

  /// Verificar si un usuario es miembro del grupo
  Future<bool> isMember({
    required String groupId,
    String? userId,
  }) async {
    try {
      final checkUserId = userId ?? _auth.currentUser?.uid;
      if (checkUserId == null) return false;

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) return false;

      final members = List<String>.from(groupDoc.data()?['members'] ?? []);
      return members.contains(checkUserId);
    } catch (e) {
      return false;
    }
  }

  /// Verificar si un usuario es admin del grupo
  Future<bool> isAdmin({
    required String groupId,
    String? userId,
  }) async {
    try {
      final checkUserId = userId ?? _auth.currentUser?.uid;
      if (checkUserId == null) return false;

      final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();

      if (!groupDoc.exists) return false;

      final admins = List<String>.from(groupDoc.data()?['admins'] ?? []);
      return admins.contains(checkUserId);
    } catch (e) {
      return false;
    }
  }
}
