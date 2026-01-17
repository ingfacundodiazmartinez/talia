import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo para solicitudes de permisos de grupo
///
/// Representa una solicitud de un padre para aprobar que su hijo
/// participe en un grupo con un contacto específico.
class PermissionRequest {
  final String id;
  final String childId;
  final String parentId;
  final String type; // Siempre 'group' para estas solicitudes
  final Map<String, dynamic> groupInfo;
  final Map<String, dynamic> contactToApprove;
  final String status; // pending, approved, rejected
  final DateTime createdAt;
  final DateTime? approvedAt;
  final DateTime? rejectedAt;
  final String? approvedBy;
  final String? rejectedBy;
  final DateTime? updatedAt;
  final String? updatedBy;

  PermissionRequest({
    required this.id,
    required this.childId,
    required this.parentId,
    required this.type,
    required this.groupInfo,
    required this.contactToApprove,
    required this.status,
    required this.createdAt,
    this.approvedAt,
    this.rejectedAt,
    this.approvedBy,
    this.rejectedBy,
    this.updatedAt,
    this.updatedBy,
  });

  // Factory constructors
  factory PermissionRequest.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return PermissionRequest.fromMap(doc.id, data);
  }

  factory PermissionRequest.fromMap(String id, Map<String, dynamic> data) {
    return PermissionRequest(
      id: id,
      childId: data['childId'] ?? '',
      parentId: data['parentId'] ?? '',
      type: data['type'] ?? 'group',
      groupInfo: Map<String, dynamic>.from(data['groupInfo'] ?? {}),
      contactToApprove: Map<String, dynamic>.from(data['contactToApprove'] ?? {}),
      status: data['status'] ?? 'pending',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      rejectedAt: (data['rejectedAt'] as Timestamp?)?.toDate(),
      approvedBy: data['approvedBy'],
      rejectedBy: data['rejectedBy'],
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: data['updatedBy'],
    );
  }

  // Conversión a Map
  Map<String, dynamic> toMap() {
    return {
      'childId': childId,
      'parentId': parentId,
      'type': type,
      'groupInfo': groupInfo,
      'contactToApprove': contactToApprove,
      'status': status,
      'createdAt': Timestamp.fromDate(createdAt),
      if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
      if (rejectedAt != null) 'rejectedAt': Timestamp.fromDate(rejectedAt!),
      if (approvedBy != null) 'approvedBy': approvedBy,
      if (rejectedBy != null) 'rejectedBy': rejectedBy,
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      if (updatedBy != null) 'updatedBy': updatedBy,
    };
  }

  // Getters computados
  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  String get groupName => groupInfo['groupName'] ?? '';
  String get contactName => contactToApprove['name'] ?? '';
  String? get contactUserId => contactToApprove['userId'];

  // Static methods para consultas

  /// Obtener solicitudes pendientes para un padre específico
  static Stream<List<PermissionRequest>> getPendingByParent(String parentId) {
    return FirebaseFirestore.instance
        .collection('permission_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => PermissionRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener solicitudes aprobadas para un padre específico
  static Stream<List<PermissionRequest>> getApprovedByParent(String parentId) {
    return FirebaseFirestore.instance
        .collection('permission_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => PermissionRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener solicitudes rechazadas para un padre específico
  static Stream<List<PermissionRequest>> getRejectedByParent(String parentId) {
    return FirebaseFirestore.instance
        .collection('permission_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'rejected')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => PermissionRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener una solicitud por ID
  static Future<PermissionRequest?> getById(String requestId) async {
    final doc = await FirebaseFirestore.instance
        .collection('permission_requests')
        .doc(requestId)
        .get();

    if (!doc.exists) return null;

    return PermissionRequest.fromFirestore(doc);
  }

  /// Crear una nueva solicitud
  static Future<String> create(Map<String, dynamic> data) async {
    final docRef = await FirebaseFirestore.instance
        .collection('permission_requests')
        .add(data);

    return docRef.id;
  }

  /// Actualizar el estado de una solicitud
  Future<void> updateStatus({
    required String newStatus,
    String? updatedBy,
  }) async {
    final updateData = <String, dynamic>{
      'status': newStatus,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (updatedBy != null) {
      updateData['updatedBy'] = updatedBy;
    }

    if (newStatus == 'approved') {
      updateData['approvedAt'] = FieldValue.serverTimestamp();
      if (updatedBy != null) updateData['approvedBy'] = updatedBy;
      // Limpiar campos de rechazo
      updateData['rejectedAt'] = null;
      updateData['rejectedBy'] = null;
    } else if (newStatus == 'rejected') {
      updateData['rejectedAt'] = FieldValue.serverTimestamp();
      if (updatedBy != null) updateData['rejectedBy'] = updatedBy;
    }

    await FirebaseFirestore.instance
        .collection('permission_requests')
        .doc(id)
        .update(updateData);
  }

  // Métodos de comparación
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PermissionRequest &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'PermissionRequest(id: $id, childId: $childId, groupName: $groupName, status: $status)';
  }
}
