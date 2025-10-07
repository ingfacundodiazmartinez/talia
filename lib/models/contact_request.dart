import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo para solicitudes de contacto que requieren aprobación parental
///
/// Representa una solicitud individual de un padre para aprobar un contacto
/// de su hijo. En contactos bidireccionales (niño-niño), habrá una solicitud
/// para cada padre involucrado.
class ContactRequest {
  final String id;
  final String childId;
  final String? parentId;
  final String? contactId;
  final String contactName;
  final String? contactPhone;
  final String? contactEmail;
  final String? childName;
  final String? childEmail;
  final String status; // pending, approved, rejected
  final DateTime requestedAt;
  final DateTime? approvedAt;
  final DateTime? rejectedAt;
  final String? approvedBy;
  final String? rejectedBy;
  final String? contactDocId;

  ContactRequest({
    required this.id,
    required this.childId,
    this.parentId,
    this.contactId,
    required this.contactName,
    this.contactPhone,
    this.contactEmail,
    this.childName,
    this.childEmail,
    required this.status,
    required this.requestedAt,
    this.approvedAt,
    this.rejectedAt,
    this.approvedBy,
    this.rejectedBy,
    this.contactDocId,
  });

  // Factory constructors
  factory ContactRequest.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ContactRequest.fromMap(doc.id, data);
  }

  factory ContactRequest.fromMap(String id, Map<String, dynamic> data) {
    return ContactRequest(
      id: id,
      childId: data['childId'] ?? '',
      parentId: data['parentId'],
      contactId: data['contactId'],
      contactName: data['contactName'] ?? '',
      contactPhone: data['contactPhone'],
      contactEmail: data['contactEmail'],
      childName: data['childName'],
      childEmail: data['childEmail'],
      status: data['status'] ?? 'pending',
      requestedAt: (data['requestedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      rejectedAt: (data['rejectedAt'] as Timestamp?)?.toDate(),
      approvedBy: data['approvedBy'],
      rejectedBy: data['rejectedBy'],
      contactDocId: data['contactDocId'],
    );
  }

  // Conversión a Map
  Map<String, dynamic> toMap() {
    return {
      'childId': childId,
      if (parentId != null) 'parentId': parentId,
      if (contactId != null) 'contactId': contactId,
      'contactName': contactName,
      if (contactPhone != null) 'contactPhone': contactPhone,
      if (contactEmail != null) 'contactEmail': contactEmail,
      if (childName != null) 'childName': childName,
      if (childEmail != null) 'childEmail': childEmail,
      'status': status,
      'requestedAt': Timestamp.fromDate(requestedAt),
      if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
      if (rejectedAt != null) 'rejectedAt': Timestamp.fromDate(rejectedAt!),
      if (approvedBy != null) 'approvedBy': approvedBy,
      if (rejectedBy != null) 'rejectedBy': rejectedBy,
      if (contactDocId != null) 'contactDocId': contactDocId,
    };
  }

  // Getters computados
  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  // Static methods para consultas

  /// Obtener solicitudes pendientes para un padre específico
  static Stream<List<ContactRequest>> getPendingByParent(String parentId) {
    return FirebaseFirestore.instance
        .collection('contact_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ContactRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener solicitudes aprobadas para un padre específico
  static Stream<List<ContactRequest>> getApprovedByParent(String parentId) {
    return FirebaseFirestore.instance
        .collection('contact_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ContactRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener solicitudes rechazadas para un padre específico
  static Stream<List<ContactRequest>> getRejectedByParent(String parentId) {
    return FirebaseFirestore.instance
        .collection('contact_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'rejected')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ContactRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener solicitudes pendientes para hijos específicos
  static Stream<List<ContactRequest>> getPendingByChildren(List<String> childrenIds) {
    if (childrenIds.isEmpty) {
      return Stream.value([]);
    }

    return FirebaseFirestore.instance
        .collection('contact_requests')
        .where('childId', whereIn: childrenIds)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ContactRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener solicitudes rechazadas para hijos específicos
  static Stream<List<ContactRequest>> getRejectedByChildren(List<String> childrenIds) {
    if (childrenIds.isEmpty) {
      return Stream.value([]);
    }

    return FirebaseFirestore.instance
        .collection('contact_requests')
        .where('childId', whereIn: childrenIds)
        .where('status', isEqualTo: 'rejected')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ContactRequest.fromFirestore(doc))
            .toList());
  }

  /// Obtener una solicitud por ID
  static Future<ContactRequest?> getById(String requestId) async {
    final doc = await FirebaseFirestore.instance
        .collection('contact_requests')
        .doc(requestId)
        .get();

    if (!doc.exists) return null;

    return ContactRequest.fromFirestore(doc);
  }

  /// Verificar si ya existe una solicitud pendiente entre dos usuarios
  static Future<bool> existsPendingBetween({
    required String childId,
    required String contactPhone,
  }) async {
    final query = await FirebaseFirestore.instance
        .collection('contact_requests')
        .where('childId', isEqualTo: childId)
        .where('contactPhone', isEqualTo: contactPhone)
        .where('status', isEqualTo: 'pending')
        .get();

    return query.docs.isNotEmpty;
  }

  /// Crear una nueva solicitud
  static Future<String> create(Map<String, dynamic> data) async {
    final docRef = await FirebaseFirestore.instance
        .collection('contact_requests')
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
        .collection('contact_requests')
        .doc(id)
        .update(updateData);
  }

  // Métodos de comparación
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactRequest &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'ContactRequest(id: $id, childId: $childId, contactName: $contactName, status: $status)';
  }
}
