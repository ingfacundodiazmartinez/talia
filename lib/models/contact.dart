import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado de aprobación por lado (hijo)
class ApprovalStatus {
  final String status; // pending | approved | rejected
  final String? parentId; // Padre asignado para aprobar
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? rejectedBy;
  final DateTime? rejectedAt;

  ApprovalStatus({
    required this.status,
    this.parentId,
    this.approvedBy,
    this.approvedAt,
    this.rejectedBy,
    this.rejectedAt,
  });

  factory ApprovalStatus.fromMap(Map<String, dynamic> data) {
    return ApprovalStatus(
      status: data['status'] ?? 'pending',
      parentId: data['parentId'],
      approvedBy: data['approvedBy'],
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      rejectedBy: data['rejectedBy'],
      rejectedAt: (data['rejectedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'status': status,
      if (parentId != null) 'parentId': parentId,
      if (approvedBy != null) 'approvedBy': approvedBy,
      if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
      if (rejectedBy != null) 'rejectedBy': rejectedBy,
      if (rejectedAt != null) 'rejectedAt': Timestamp.fromDate(rejectedAt!),
    };
  }

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
}

/// Modelo unificado para contactos entre usuarios
///
/// Schema simplificado:
/// - Una sola colección `contacts`
/// - ID predecible: `{userId1}_{userId2}` (ordenados alfabéticamente)
/// - Sin duplicación de datos (nombres/fotos se obtienen fresh de /users)
/// - `approvals` map para estado por lado (hijo)
class Contact {
  final String id; // {userId1}_{userId2}
  final List<String> users; // [userId1, userId2] ordenados alfabéticamente
  final String status; // pending | approved | rejected | revoked
  final DateTime createdAt;
  final String createdBy;
  final String? createdVia; // user_code | group_approval | etc.
  final bool autoApproved;

  /// Estado de aprobación por lado
  /// Key: childId que necesita aprobación
  /// Value: ApprovalStatus con estado, parentId asignado, etc.
  final Map<String, ApprovalStatus> approvals;

  /// IDs de padres que pueden ver este contacto y los datos de los usuarios
  /// Se calcula al crear el contacto basado en los hijos involucrados
  final List<String> parentViewers;

  /// Metadatos de revocación
  final DateTime? revokedAt;
  final String? revokedBy;
  final String? revokedReason;

  /// Mapa de phones para contactos potential
  /// Key: userId, Value: phone number
  /// Solo presente en contactos con status='potential'
  final Map<String, String> phones;

  /// Tipo de contacto (null para contactos normales)
  /// Valores especiales: 'parent_child_link' (no mostrar en whitelist)
  final String? type;

  Contact({
    required this.id,
    required this.users,
    required this.status,
    required this.createdAt,
    required this.createdBy,
    this.createdVia,
    required this.autoApproved,
    required this.approvals,
    this.parentViewers = const [],
    this.revokedAt,
    this.revokedBy,
    this.revokedReason,
    this.phones = const {},
    this.type,
  });

  // ═══════════════════════════════════════════════════════════════
  // FACTORY CONSTRUCTORS
  // ═══════════════════════════════════════════════════════════════

  factory Contact.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Contact.fromMap(doc.id, data);
  }

  factory Contact.fromMap(String id, Map<String, dynamic> data) {
    // Parsear approvals map
    final approvalsRaw = data['approvals'] as Map<String, dynamic>? ?? {};
    final approvals = <String, ApprovalStatus>{};
    for (final entry in approvalsRaw.entries) {
      approvals[entry.key] = ApprovalStatus.fromMap(
        entry.value as Map<String, dynamic>,
      );
    }

    // Parsear phones map
    final phonesRaw = data['phones'] as Map<String, dynamic>? ?? {};
    final phones = phonesRaw.map((k, v) => MapEntry(k, v.toString()));

    return Contact(
      id: id,
      users: List<String>.from(data['users'] ?? []),
      status: data['status'] ?? 'pending',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
      createdVia: data['createdVia'],
      autoApproved: data['autoApproved'] ?? false,
      approvals: approvals,
      parentViewers: List<String>.from(data['parentViewers'] ?? []),
      revokedAt: (data['revokedAt'] as Timestamp?)?.toDate(),
      revokedBy: data['revokedBy'],
      revokedReason: data['revokedReason'],
      phones: phones,
      type: data['type'],
    );
  }

  /// Verificar si es un contacto real (no un link interno)
  bool get isRealContact => type == null || type != 'parent_child_link';

  // ═══════════════════════════════════════════════════════════════
  // SERIALIZATION
  // ═══════════════════════════════════════════════════════════════

  Map<String, dynamic> toMap() {
    final approvalsMap = <String, dynamic>{};
    for (final entry in approvals.entries) {
      approvalsMap[entry.key] = entry.value.toMap();
    }

    return {
      'users': users,
      'status': status,
      'createdAt': Timestamp.fromDate(createdAt),
      'createdBy': createdBy,
      if (createdVia != null) 'createdVia': createdVia,
      'autoApproved': autoApproved,
      'approvals': approvalsMap,
      'parentViewers': parentViewers,
      if (revokedAt != null) 'revokedAt': Timestamp.fromDate(revokedAt!),
      if (revokedBy != null) 'revokedBy': revokedBy,
      if (revokedReason != null) 'revokedReason': revokedReason,
      if (phones.isNotEmpty) 'phones': phones,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // COMPUTED PROPERTIES
  // ═══════════════════════════════════════════════════════════════

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
  bool get isRevoked => status == 'revoked';
  bool get isPotential => status == 'potential';

  /// Obtener el ID del otro usuario en el contacto
  String getOtherUserId(String currentUserId) {
    return users.firstWhere(
      (id) => id != currentUserId,
      orElse: () => '',
    );
  }

  /// Verificar si un padre específico necesita aprobar
  bool needsApprovalFrom(String parentId) {
    return approvals.values.any(
      (a) => a.isPending && a.parentId == parentId,
    );
  }

  /// Obtener los childIds que necesitan aprobación de un padre
  List<String> getChildIdsNeedingApprovalFrom(String parentId) {
    return approvals.entries
        .where((e) => e.value.isPending && e.value.parentId == parentId)
        .map((e) => e.key)
        .toList();
  }

  /// Obtener la aprobación para un hijo específico
  ApprovalStatus? getApprovalForChild(String childId) {
    return approvals[childId];
  }

  /// Verificar si todas las aprobaciones están completas
  bool get allApprovalsComplete {
    if (approvals.isEmpty) return true;
    return approvals.values.every((a) => a.isApproved);
  }

  /// Obtener número de aprobaciones pendientes
  int get pendingApprovalsCount {
    return approvals.values.where((a) => a.isPending).length;
  }

  // ═══════════════════════════════════════════════════════════════
  // STATIC HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Generar ID de contacto a partir de dos userIds
  static String generateId(String userId1, String userId2) {
    final sorted = [userId1, userId2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  /// Extraer userIds de un contactId
  static List<String> extractUserIds(String contactId) {
    return contactId.split('_');
  }

  // ═══════════════════════════════════════════════════════════════
  // STATIC QUERIES (para uso directo desde UI cuando sea simple)
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si ya existe un contacto entre dos usuarios
  static Future<Contact?> findBetween(String userId1, String userId2) async {
    final contactId = generateId(userId1, userId2);

    final doc = await FirebaseFirestore.instance
        .collection('contacts')
        .doc(contactId)
        .get();

    if (!doc.exists) return null;
    return Contact.fromFirestore(doc);
  }

  /// Verificar si existe un contacto aprobado entre dos usuarios
  static Future<bool> existsApprovedBetween(
      String userId1, String userId2) async {
    final contact = await findBetween(userId1, userId2);
    return contact?.isApproved ?? false;
  }

  /// Obtener un contacto por ID
  static Future<Contact?> getById(String contactId) async {
    final doc = await FirebaseFirestore.instance
        .collection('contacts')
        .doc(contactId)
        .get();

    if (!doc.exists) return null;
    return Contact.fromFirestore(doc);
  }

  /// Stream de contactos de un usuario (todos los estados)
  static Stream<List<Contact>> watchByUser(String userId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: userId)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Contact.fromFirestore(doc)).toList());
  }

  /// Stream de contactos aprobados de un usuario
  static Stream<List<Contact>> watchApprovedByUser(String userId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: userId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Contact.fromFirestore(doc)).toList());
  }

  /// Stream de contactos sugeridos (potential) de un usuario
  /// Estos son contactos descubiertos durante sync que aún no han sido solicitados
  static Stream<List<Contact>> watchPotentialForUser(String userId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: userId)
        .where('status', isEqualTo: 'potential')
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Contact.fromFirestore(doc)).toList());
  }

  // ═══════════════════════════════════════════════════════════════
  // CHILD QUERIES (para pantalla de contactos del niño)
  // ═══════════════════════════════════════════════════════════════

  /// Stream de contactos donde MI aprobación está pendiente (mis padres deben aprobar)
  /// Filtra contactos donde approvals[childId].status == 'pending'
  static Stream<List<Contact>> watchPendingForChild(String childId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: childId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Contact.fromFirestore(doc))
            .where((contact) {
              final approval = contact.approvals[childId];
              return approval != null && approval.isPending;
            })
            .toList());
  }

  /// Stream de contactos donde MI aprobación fue rechazada
  static Stream<List<Contact>> watchRejectedForChild(String childId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: childId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Contact.fromFirestore(doc))
            .where((contact) {
              final approval = contact.approvals[childId];
              return approval != null && approval.isRejected;
            })
            .toList());
  }

  /// Stream de contactos donde el OTRO usuario tiene aprobación pendiente
  /// (sus padres deben aprobar)
  static Stream<List<Contact>> watchOtherPendingForChild(String childId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: childId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Contact.fromFirestore(doc))
            .where((contact) {
              final otherUserId = contact.getOtherUserId(childId);
              final otherApproval = contact.approvals[otherUserId];
              // Mi lado está ok pero el otro está pendiente
              final myApproval = contact.approvals[childId];
              final myStatusOk = myApproval == null || myApproval.isApproved;
              return myStatusOk && otherApproval != null && otherApproval.isPending;
            })
            .toList());
  }

  /// Obtener el nombre del contacto (otro usuario) desde datos de usuario
  /// Helper para UI - debe llamarse con datos de /users
  String getContactName(String currentUserId, Map<String, dynamic>? otherUserData) {
    if (otherUserData == null) return 'Usuario';
    return otherUserData['name'] as String? ?? 'Usuario';
  }

  // ═══════════════════════════════════════════════════════════════
  // EQUALITY
  // ═══════════════════════════════════════════════════════════════

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Contact && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'Contact(id: $id, users: $users, status: $status, approvals: ${approvals.length})';
  }
}
