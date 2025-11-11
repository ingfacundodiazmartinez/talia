import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo para representar un miembro de grupo con su estado de aprobación
///
/// Estados posibles:
/// - 'approved': Miembro completamente aprobado, puede ver y enviar mensajes
/// - 'pending': Pendiente de aprobación parental, puede ver pero no puede enviar mensajes
/// - 'blocked': Bloqueado, no puede ver ni enviar mensajes
/// - 'admin': Administrador del grupo (creator + permisos especiales)
class GroupMember {
  final String userId;
  final String displayName;
  final String? photoUrl;
  final GroupMemberStatus status;
  final DateTime joinedAt;
  final DateTime? approvedAt;
  final String? approvedBy; // Parent ID que aprobó (si aplica)
  final String? blockedBy;   // Parent ID que bloqueó (si aplica)
  final DateTime? blockedAt;
  final String? blockReason;
  final Map<String, dynamic>? metadata;

  const GroupMember({
    required this.userId,
    required this.displayName,
    this.photoUrl,
    required this.status,
    required this.joinedAt,
    this.approvedAt,
    this.approvedBy,
    this.blockedBy,
    this.blockedAt,
    this.blockReason,
    this.metadata,
  });

  /// Constructor desde Firestore data
  factory GroupMember.fromFirestore(Map<String, dynamic> data) {
    return GroupMember(
      userId: data['userId'] as String,
      displayName: data['displayName'] as String? ?? 'Usuario',
      photoUrl: data['photoUrl'] as String?,
      status: GroupMemberStatus.fromString(data['status'] as String? ?? 'pending'),
      joinedAt: (data['joinedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      approvedBy: data['approvedBy'] as String?,
      blockedBy: data['blockedBy'] as String?,
      blockedAt: (data['blockedAt'] as Timestamp?)?.toDate(),
      blockReason: data['blockReason'] as String?,
      metadata: data['metadata'] as Map<String, dynamic>?,
    );
  }

  /// Convertir a Map para Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'displayName': displayName,
      if (photoUrl != null) 'photoUrl': photoUrl,
      'status': status.value,
      'joinedAt': Timestamp.fromDate(joinedAt),
      if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
      if (approvedBy != null) 'approvedBy': approvedBy,
      if (blockedBy != null) 'blockedBy': blockedBy,
      if (blockedAt != null) 'blockedAt': Timestamp.fromDate(blockedAt!),
      if (blockReason != null) 'blockReason': blockReason,
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// Crear copia con cambios
  GroupMember copyWith({
    String? userId,
    String? displayName,
    String? photoUrl,
    GroupMemberStatus? status,
    DateTime? joinedAt,
    DateTime? approvedAt,
    String? approvedBy,
    String? blockedBy,
    DateTime? blockedAt,
    String? blockReason,
    Map<String, dynamic>? metadata,
  }) {
    return GroupMember(
      userId: userId ?? this.userId,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      status: status ?? this.status,
      joinedAt: joinedAt ?? this.joinedAt,
      approvedAt: approvedAt ?? this.approvedAt,
      approvedBy: approvedBy ?? this.approvedBy,
      blockedBy: blockedBy ?? this.blockedBy,
      blockedAt: blockedAt ?? this.blockedAt,
      blockReason: blockReason ?? this.blockReason,
      metadata: metadata ?? this.metadata,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // BUSINESS LOGIC HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Puede ver mensajes del grupo
  bool get canViewMessages => status != GroupMemberStatus.blocked;

  /// Puede enviar mensajes al grupo
  bool get canSendMessages => status == GroupMemberStatus.approved || status == GroupMemberStatus.admin;

  /// Es administrador del grupo
  bool get isAdmin => status == GroupMemberStatus.admin;

  /// Está pendiente de aprobación
  bool get isPending => status == GroupMemberStatus.pending;

  /// Está bloqueado
  bool get isBlocked => status == GroupMemberStatus.blocked;

  /// Puede ser promovido a admin
  bool get canBePromoted => status == GroupMemberStatus.approved;

  /// Requiere aprobación parental
  bool get requiresParentalApproval => isPending;

  @override
  String toString() {
    return 'GroupMember(userId: $userId, displayName: $displayName, status: ${status.value})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GroupMember && other.userId == userId;
  }

  @override
  int get hashCode => userId.hashCode;
}

/// Enum para estados de miembros de grupo
enum GroupMemberStatus {
  approved('approved'),
  pending('pending'),
  blocked('blocked'),
  admin('admin');

  const GroupMemberStatus(this.value);
  final String value;

  static GroupMemberStatus fromString(String value) {
    switch (value.toLowerCase()) {
      case 'approved':
        return GroupMemberStatus.approved;
      case 'pending':
        return GroupMemberStatus.pending;
      case 'blocked':
        return GroupMemberStatus.blocked;
      case 'admin':
        return GroupMemberStatus.admin;
      default:
        return GroupMemberStatus.pending; // Default safe
    }
  }

  /// Texto display para UI
  String get displayName {
    switch (this) {
      case GroupMemberStatus.approved:
        return 'Aprobado';
      case GroupMemberStatus.pending:
        return 'Pendiente';
      case GroupMemberStatus.blocked:
        return 'Bloqueado';
      case GroupMemberStatus.admin:
        return 'Administrador';
    }
  }

  /// Color sugerido para UI
  String get colorHex {
    switch (this) {
      case GroupMemberStatus.approved:
        return '#4CAF50'; // Verde
      case GroupMemberStatus.pending:
        return '#FF9800'; // Naranja
      case GroupMemberStatus.blocked:
        return '#F44336'; // Rojo
      case GroupMemberStatus.admin:
        return '#2196F3'; // Azul
    }
  }
}

/// Lista de miembros con helpers de business logic
class GroupMemberList {
  final List<GroupMember> members;

  const GroupMemberList(this.members);

  /// Obtener solo miembros aprobados
  List<GroupMember> get approvedMembers =>
      members.where((m) => m.status == GroupMemberStatus.approved).toList();

  /// Obtener solo miembros pendientes
  List<GroupMember> get pendingMembers =>
      members.where((m) => m.status == GroupMemberStatus.pending).toList();

  /// Obtener solo miembros bloqueados
  List<GroupMember> get blockedMembers =>
      members.where((m) => m.status == GroupMemberStatus.blocked).toList();

  /// Obtener solo administradores
  List<GroupMember> get admins =>
      members.where((m) => m.status == GroupMemberStatus.admin).toList();

  /// Obtener miembros activos (no bloqueados)
  List<GroupMember> get activeMembers =>
      members.where((m) => m.status != GroupMemberStatus.blocked).toList();

  /// Buscar miembro por ID
  GroupMember? findMember(String userId) {
    try {
      return members.firstWhere((m) => m.userId == userId);
    } catch (_) {
      return null;
    }
  }

  /// Verificar si usuario es miembro (cualquier estado)
  bool containsUser(String userId) => findMember(userId) != null;

  /// Verificar si usuario puede enviar mensajes
  bool canUserSendMessages(String userId) {
    final member = findMember(userId);
    return member?.canSendMessages == true;
  }

  /// Verificar si usuario puede ver mensajes
  bool canUserViewMessages(String userId) {
    final member = findMember(userId);
    return member?.canViewMessages == true;
  }

  /// Verificar si usuario es admin
  bool isUserAdmin(String userId) {
    final member = findMember(userId);
    return member?.isAdmin == true;
  }

  /// Contar miembros por estado
  Map<String, int> get memberCountsByStatus {
    final counts = <String, int>{
      'approved': 0,
      'pending': 0,
      'blocked': 0,
      'admin': 0,
    };

    for (final member in members) {
      counts[member.status.value] = (counts[member.status.value] ?? 0) + 1;
    }

    return counts;
  }

  /// Total de miembros activos (no bloqueados)
  int get activeMemberCount => activeMembers.length;

  /// Total de miembros
  int get totalMemberCount => members.length;

  @override
  String toString() {
    return 'GroupMemberList(${members.length} members: $memberCountsByStatus)';
  }
}