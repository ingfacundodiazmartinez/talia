import 'package:cloud_firestore/cloud_firestore.dart';

/// User role in the system
enum UserRole {
  parent,
  child,
  adult;

  static UserRole fromString(String? value) {
    switch (value) {
      case 'parent':
        return UserRole.parent;
      case 'child':
        return UserRole.child;
      case 'adult':
      default:
        return UserRole.adult;
    }
  }

  String toValue() {
    switch (this) {
      case UserRole.parent:
        return 'parent';
      case UserRole.child:
        return 'child';
      case UserRole.adult:
        return 'adult';
    }
  }
}

/// Approved group member
class GroupMember {
  final String userId;
  final String name;
  final String? photoURL;
  final UserRole role;
  final DateTime joinedAt;
  final String addedBy;

  const GroupMember({
    required this.userId,
    required this.name,
    this.photoURL,
    required this.role,
    required this.joinedAt,
    required this.addedBy,
  });

  factory GroupMember.fromMap(String id, Map<String, dynamic> data) {
    return GroupMember(
      userId: id,
      name: data['name'] as String? ?? 'Usuario',
      photoURL: data['photoURL'] as String?,
      role: UserRole.fromString(data['role'] as String?),
      joinedAt: (data['joinedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      addedBy: data['addedBy'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'photoURL': photoURL,
      'role': role.toValue(),
      'joinedAt': Timestamp.fromDate(joinedAt),
      'addedBy': addedBy,
    };
  }

  /// Check if this member is a child
  bool get isChild => role == UserRole.child;

  /// Check if this member is a parent
  bool get isParent => role == UserRole.parent;

  /// Check if this member is an adult (non-parent)
  bool get isAdult => role == UserRole.adult;

  GroupMember copyWith({
    String? userId,
    String? name,
    String? photoURL,
    UserRole? role,
    DateTime? joinedAt,
    String? addedBy,
  }) {
    return GroupMember(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      photoURL: photoURL ?? this.photoURL,
      role: role ?? this.role,
      joinedAt: joinedAt ?? this.joinedAt,
      addedBy: addedBy ?? this.addedBy,
    );
  }

  @override
  String toString() => 'GroupMember(userId: $userId, name: $name, role: $role)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMember &&
          runtimeType == other.runtimeType &&
          userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}

/// Pending group member (awaiting parent approval)
class PendingMember {
  final String userId;
  final String name;
  final String? photoURL;
  final DateTime requestedAt;
  final String addedBy;
  final DateTime expiresAt;
  final List<String> parentIds;

  const PendingMember({
    required this.userId,
    required this.name,
    this.photoURL,
    required this.requestedAt,
    required this.addedBy,
    required this.expiresAt,
    required this.parentIds,
  });

  factory PendingMember.fromMap(String id, Map<String, dynamic> data) {
    return PendingMember(
      userId: id,
      name: data['name'] as String? ?? 'Usuario',
      photoURL: data['photoURL'] as String?,
      requestedAt: (data['requestedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      addedBy: data['addedBy'] as String? ?? '',
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ?? DateTime.now().add(const Duration(days: 7)),
      parentIds: List<String>.from(data['parentIds'] ?? []),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'photoURL': photoURL,
      'role': 'child',
      'requestedAt': Timestamp.fromDate(requestedAt),
      'addedBy': addedBy,
      'expiresAt': Timestamp.fromDate(expiresAt),
      'parentIds': parentIds,
    };
  }

  /// Check if the request has expired
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Days remaining until expiration
  int get daysRemaining {
    final diff = expiresAt.difference(DateTime.now());
    return diff.inDays;
  }

  PendingMember copyWith({
    String? userId,
    String? name,
    String? photoURL,
    DateTime? requestedAt,
    String? addedBy,
    DateTime? expiresAt,
    List<String>? parentIds,
  }) {
    return PendingMember(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      photoURL: photoURL ?? this.photoURL,
      requestedAt: requestedAt ?? this.requestedAt,
      addedBy: addedBy ?? this.addedBy,
      expiresAt: expiresAt ?? this.expiresAt,
      parentIds: parentIds ?? this.parentIds,
    );
  }

  @override
  String toString() =>
      'PendingMember(userId: $userId, name: $name, expiresAt: $expiresAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingMember &&
          runtimeType == other.runtimeType &&
          userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}
