import 'package:cloud_firestore/cloud_firestore.dart';
import 'group_member.dart';

/// Status of a group approval request
enum ApprovalStatus {
  pending,
  approved,
  rejected,
  expired;

  static ApprovalStatus fromString(String? value) {
    switch (value) {
      case 'approved':
        return ApprovalStatus.approved;
      case 'rejected':
        return ApprovalStatus.rejected;
      case 'expired':
        return ApprovalStatus.expired;
      case 'pending':
      default:
        return ApprovalStatus.pending;
    }
  }

  String toValue() {
    switch (this) {
      case ApprovalStatus.pending:
        return 'pending';
      case ApprovalStatus.approved:
        return 'approved';
      case ApprovalStatus.rejected:
        return 'rejected';
      case ApprovalStatus.expired:
        return 'expired';
    }
  }
}

/// Member info snapshot for approval request display
class MemberSnapshot {
  final String userId;
  final String name;
  final String? photoURL;
  final UserRole role;

  const MemberSnapshot({
    required this.userId,
    required this.name,
    this.photoURL,
    required this.role,
  });

  factory MemberSnapshot.fromMap(Map<String, dynamic> data) {
    return MemberSnapshot(
      userId: data['userId'] as String? ?? '',
      name: data['name'] as String? ?? 'Usuario',
      photoURL: data['photoURL'] as String?,
      role: UserRole.fromString(data['role'] as String?),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'name': name,
      'photoURL': photoURL,
      'role': role.toValue(),
    };
  }
}

/// Group approval request
///
/// Represents a pending request for a parent to approve
/// their child joining a group.
class GroupApprovalRequest {
  final String id;
  final String groupId;
  final String childId;
  final String parentId;

  // Group info snapshot
  final String groupName;
  final String? groupDescription;
  final String? groupAvatar;
  final String groupCreatorId;
  final String groupCreatorName;

  // Member list snapshot
  final List<MemberSnapshot> members;

  // Child info
  final String childName;
  final String? childPhotoURL;

  // Request state
  final ApprovalStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? respondedAt;

  // Notifications
  final bool notificationSent;
  final DateTime? lastReminderAt;

  const GroupApprovalRequest({
    required this.id,
    required this.groupId,
    required this.childId,
    required this.parentId,
    required this.groupName,
    this.groupDescription,
    this.groupAvatar,
    required this.groupCreatorId,
    required this.groupCreatorName,
    required this.members,
    required this.childName,
    this.childPhotoURL,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.respondedAt,
    required this.notificationSent,
    this.lastReminderAt,
  });

  factory GroupApprovalRequest.fromFirestore(String id, Map<String, dynamic> data) {
    // Parse members list
    final membersList = <MemberSnapshot>[];
    final rawMembers = data['members'] as List<dynamic>? ?? [];
    for (final member in rawMembers) {
      if (member is Map<String, dynamic>) {
        membersList.add(MemberSnapshot.fromMap(member));
      }
    }

    return GroupApprovalRequest(
      id: id,
      groupId: data['groupId'] as String? ?? '',
      childId: data['childId'] as String? ?? '',
      parentId: data['parentId'] as String? ?? '',
      groupName: data['groupName'] as String? ?? '',
      groupDescription: data['groupDescription'] as String?,
      groupAvatar: data['groupAvatar'] as String?,
      groupCreatorId: data['groupCreatorId'] as String? ?? '',
      groupCreatorName: data['groupCreatorName'] as String? ?? 'Usuario',
      members: membersList,
      childName: data['childName'] as String? ?? 'Usuario',
      childPhotoURL: data['childPhotoURL'] as String?,
      status: ApprovalStatus.fromString(data['status'] as String?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ?? DateTime.now().add(const Duration(days: 7)),
      respondedAt: (data['respondedAt'] as Timestamp?)?.toDate(),
      notificationSent: data['notificationSent'] as bool? ?? false,
      lastReminderAt: (data['lastReminderAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'groupId': groupId,
      'childId': childId,
      'parentId': parentId,
      'groupName': groupName,
      'groupDescription': groupDescription,
      'groupAvatar': groupAvatar,
      'groupCreatorId': groupCreatorId,
      'groupCreatorName': groupCreatorName,
      'members': members.map((m) => m.toMap()).toList(),
      'childName': childName,
      'childPhotoURL': childPhotoURL,
      'status': status.toValue(),
      'createdAt': Timestamp.fromDate(createdAt),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'respondedAt': respondedAt != null ? Timestamp.fromDate(respondedAt!) : null,
      'notificationSent': notificationSent,
      'lastReminderAt': lastReminderAt != null ? Timestamp.fromDate(lastReminderAt!) : null,
    };
  }

  /// Check if the request is still pending
  bool get isPending => status == ApprovalStatus.pending;

  /// Check if the request has been approved
  bool get isApproved => status == ApprovalStatus.approved;

  /// Check if the request has been rejected
  bool get isRejected => status == ApprovalStatus.rejected;

  /// Check if the request has expired
  bool get isExpired => status == ApprovalStatus.expired || DateTime.now().isAfter(expiresAt);

  /// Days remaining until expiration
  int get daysRemaining {
    if (isExpired) return 0;
    final diff = expiresAt.difference(DateTime.now());
    return diff.inDays;
  }

  /// Count of child members in the group
  int get childCount => members.where((m) => m.role == UserRole.child).length;

  /// Count of adult members in the group
  int get adultCount => members.where((m) => m.role != UserRole.child).length;

  GroupApprovalRequest copyWith({
    String? id,
    String? groupId,
    String? childId,
    String? parentId,
    String? groupName,
    String? groupDescription,
    String? groupAvatar,
    String? groupCreatorId,
    String? groupCreatorName,
    List<MemberSnapshot>? members,
    String? childName,
    String? childPhotoURL,
    ApprovalStatus? status,
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? respondedAt,
    bool? notificationSent,
    DateTime? lastReminderAt,
  }) {
    return GroupApprovalRequest(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      childId: childId ?? this.childId,
      parentId: parentId ?? this.parentId,
      groupName: groupName ?? this.groupName,
      groupDescription: groupDescription ?? this.groupDescription,
      groupAvatar: groupAvatar ?? this.groupAvatar,
      groupCreatorId: groupCreatorId ?? this.groupCreatorId,
      groupCreatorName: groupCreatorName ?? this.groupCreatorName,
      members: members ?? this.members,
      childName: childName ?? this.childName,
      childPhotoURL: childPhotoURL ?? this.childPhotoURL,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      respondedAt: respondedAt ?? this.respondedAt,
      notificationSent: notificationSent ?? this.notificationSent,
      lastReminderAt: lastReminderAt ?? this.lastReminderAt,
    );
  }

  @override
  String toString() =>
      'GroupApprovalRequest(id: $id, groupName: $groupName, childName: $childName, status: $status)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupApprovalRequest &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
