import 'package:cloud_firestore/cloud_firestore.dart';
import '../../groups/groups.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Listar solicitudes de grupo y membresías
///
/// Responsabilidad única: Proveer streams de grupos pendientes y aprobados
class ListGroupApprovalsService {
  final FirebaseFirestore _firestore;

  ListGroupApprovalsService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Stream de solicitudes de grupo pendientes para el padre
  Stream<List<GroupApprovalRequest>> watchPendingRequests(String parentId) {
    return GroupApprovalRepository().watchPendingRequestsForParent(parentId);
  }

  /// Stream de grupos donde los hijos son miembros aprobados
  Stream<List<GroupMembershipInfo>> watchApprovedMemberships(List<String> childrenIds) {
    if (childrenIds.isEmpty) {
      return Stream.value(<GroupMembershipInfo>[]);
    }

    ReleaseLogger.log(
      'Buscando grupos aprobados para ${childrenIds.length} hijos',
      tag: 'ListGroupApprovals',
    );

    // Una sola query usando arrayContainsAny (hasta 30 valores)
    return _firestore
        .collection('groups_v2')
        .where('members', arrayContainsAny: childrenIds)
        .snapshots()
        .map((snapshot) {
          final results = <GroupMembershipInfo>[];

          for (final doc in snapshot.docs) {
            final data = doc.data();
            final members = List<String>.from(data['members'] ?? []);

            // Para cada hijo que es miembro de este grupo, crear una entrada
            for (final childId in childrenIds) {
              if (members.contains(childId)) {
                results.add(GroupMembershipInfo(
                  groupId: doc.id,
                  groupName: data['name'] as String? ?? 'Grupo',
                  groupAvatar: data['avatar'] as String?,
                  groupDescription: data['description'] as String?,
                  memberCount: data['memberCount'] as int? ?? 0,
                  childId: childId,
                  members: members,
                  memberDetails: Map<String, dynamic>.from(data['memberDetails'] ?? {}),
                ));
              }
            }
          }

          return results;
        });
  }
}

/// Información de membresía de grupo
class GroupMembershipInfo {
  final String groupId;
  final String groupName;
  final String? groupAvatar;
  final String? groupDescription;
  final int memberCount;
  final String childId;
  final List<String> members;
  final Map<String, dynamic> memberDetails;

  GroupMembershipInfo({
    required this.groupId,
    required this.groupName,
    this.groupAvatar,
    this.groupDescription,
    required this.memberCount,
    required this.childId,
    required this.members,
    required this.memberDetails,
  });

  Map<String, dynamic> toMap() => {
        'groupId': groupId,
        'groupName': groupName,
        'groupAvatar': groupAvatar,
        'groupDescription': groupDescription,
        'memberCount': memberCount,
        'childId': childId,
        'members': members,
        'memberDetails': memberDetails,
      };
}
