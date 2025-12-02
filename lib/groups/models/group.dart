import 'package:cloud_firestore/cloud_firestore.dart';
import 'group_member.dart';

/// Group model for Groups V2
///
/// Represents a group chat with parent approval for children.
class Group {
  final String id;
  final String name;
  final String? description;
  final String? avatar;

  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  final List<String> memberIds;
  final List<String> pendingMemberIds;
  final List<String> adminIds;

  final Map<String, GroupMember> memberDetails;
  final Map<String, PendingMember> pendingMemberDetails;

  final bool isActive;
  final int memberCount;
  final int pendingCount;
  final DateTime lastActivity;

  // Last message info for group list
  final String? lastMessage;
  final String? lastMessageSender;
  final DateTime? lastMessageTime;

  const Group({
    required this.id,
    required this.name,
    this.description,
    this.avatar,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.memberIds,
    required this.pendingMemberIds,
    required this.adminIds,
    required this.memberDetails,
    required this.pendingMemberDetails,
    required this.isActive,
    required this.memberCount,
    required this.pendingCount,
    required this.lastActivity,
    this.lastMessage,
    this.lastMessageSender,
    this.lastMessageTime,
  });

  /// Create from Firestore document
  factory Group.fromFirestore(String id, Map<String, dynamic> data) {
    // Parse member details
    final memberDetailsMap = <String, GroupMember>{};
    final rawMemberDetails = data['memberDetails'] as Map<String, dynamic>? ?? {};
    for (final entry in rawMemberDetails.entries) {
      memberDetailsMap[entry.key] = GroupMember.fromMap(
        entry.key,
        entry.value as Map<String, dynamic>,
      );
    }

    // Parse pending member details
    final pendingMemberDetailsMap = <String, PendingMember>{};
    final rawPendingDetails = data['pendingMemberDetails'] as Map<String, dynamic>? ?? {};
    for (final entry in rawPendingDetails.entries) {
      pendingMemberDetailsMap[entry.key] = PendingMember.fromMap(
        entry.key,
        entry.value as Map<String, dynamic>,
      );
    }

    return Group(
      id: id,
      name: data['name'] as String? ?? '',
      description: data['description'] as String?,
      avatar: data['avatar'] as String?,
      createdBy: data['createdBy'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      memberIds: List<String>.from(data['members'] ?? []),
      pendingMemberIds: List<String>.from(data['pendingMembers'] ?? []),
      adminIds: List<String>.from(data['admins'] ?? []),
      memberDetails: memberDetailsMap,
      pendingMemberDetails: pendingMemberDetailsMap,
      isActive: data['isActive'] as bool? ?? true,
      memberCount: data['memberCount'] as int? ?? 0,
      pendingCount: data['pendingCount'] as int? ?? 0,
      lastActivity: (data['lastActivity'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastMessage: data['lastMessage'] as String?,
      lastMessageSender: data['lastMessageSender'] as String?,
      lastMessageTime: (data['lastMessageTime'] as Timestamp?)?.toDate(),
    );
  }

  /// Convert to Firestore map
  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'description': description,
      'avatar': avatar,
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'members': memberIds,
      'pendingMembers': pendingMemberIds,
      'admins': adminIds,
      'memberDetails': memberDetails.map((k, v) => MapEntry(k, v.toMap())),
      'pendingMemberDetails': pendingMemberDetails.map((k, v) => MapEntry(k, v.toMap())),
      'isActive': isActive,
      'memberCount': memberCount,
      'pendingCount': pendingCount,
      'lastActivity': Timestamp.fromDate(lastActivity),
      if (lastMessage != null) 'lastMessage': lastMessage,
      if (lastMessageSender != null) 'lastMessageSender': lastMessageSender,
      if (lastMessageTime != null) 'lastMessageTime': Timestamp.fromDate(lastMessageTime!),
    };
  }

  /// Check if user is a member
  bool isMember(String userId) => memberIds.contains(userId);

  /// Check if user is pending
  bool isPending(String userId) => pendingMemberIds.contains(userId);

  /// Check if user is an admin
  bool isAdmin(String userId) => adminIds.contains(userId);

  /// Get member details by ID
  GroupMember? getMember(String userId) => memberDetails[userId];

  /// Get pending member details by ID
  PendingMember? getPendingMember(String userId) => pendingMemberDetails[userId];

  /// Get all members as a list
  List<GroupMember> get members => memberDetails.values.toList();

  /// Get all pending members as a list
  List<PendingMember> get pendingMembers => pendingMemberDetails.values.toList();

  /// Copy with updated fields
  Group copyWith({
    String? id,
    String? name,
    String? description,
    String? avatar,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? memberIds,
    List<String>? pendingMemberIds,
    List<String>? adminIds,
    Map<String, GroupMember>? memberDetails,
    Map<String, PendingMember>? pendingMemberDetails,
    bool? isActive,
    int? memberCount,
    int? pendingCount,
    DateTime? lastActivity,
    String? lastMessage,
    String? lastMessageSender,
    DateTime? lastMessageTime,
  }) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      avatar: avatar ?? this.avatar,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      memberIds: memberIds ?? this.memberIds,
      pendingMemberIds: pendingMemberIds ?? this.pendingMemberIds,
      adminIds: adminIds ?? this.adminIds,
      memberDetails: memberDetails ?? this.memberDetails,
      pendingMemberDetails: pendingMemberDetails ?? this.pendingMemberDetails,
      isActive: isActive ?? this.isActive,
      memberCount: memberCount ?? this.memberCount,
      pendingCount: pendingCount ?? this.pendingCount,
      lastActivity: lastActivity ?? this.lastActivity,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageSender: lastMessageSender ?? this.lastMessageSender,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
    );
  }

  @override
  String toString() => 'Group(id: $id, name: $name, members: $memberCount)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Group && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
