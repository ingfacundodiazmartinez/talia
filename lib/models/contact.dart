import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo para contactos aprobados entre usuarios
///
/// Representa una relación de contacto bidireccional entre dos usuarios.
/// Un contacto puede estar en diferentes estados: pending, approved, rejected, revoked.
class Contact {
  final String id;
  final List<String> users; // [userId1, userId2] ordenados alfabéticamente
  final String user1Name;
  final String user2Name;
  final String user1Email;
  final String user2Email;
  final String status; // pending, approved, rejected, revoked
  final bool autoApproved;
  final DateTime addedAt;
  final String addedBy;
  final String addedVia; // user_code, group_approval, etc.
  final DateTime? approvedAt;
  final DateTime? revokedAt;
  final String? revokedBy;
  final bool? approvedForGroup;

  Contact({
    required this.id,
    required this.users,
    required this.user1Name,
    required this.user2Name,
    required this.user1Email,
    required this.user2Email,
    required this.status,
    required this.autoApproved,
    required this.addedAt,
    required this.addedBy,
    required this.addedVia,
    this.approvedAt,
    this.revokedAt,
    this.revokedBy,
    this.approvedForGroup,
  });

  // Factory constructors
  factory Contact.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Contact.fromMap(doc.id, data);
  }

  factory Contact.fromMap(String id, Map<String, dynamic> data) {
    return Contact(
      id: id,
      users: List<String>.from(data['users'] ?? []),
      user1Name: data['user1Name'] ?? '',
      user2Name: data['user2Name'] ?? '',
      user1Email: data['user1Email'] ?? '',
      user2Email: data['user2Email'] ?? '',
      status: data['status'] ?? 'pending',
      autoApproved: data['autoApproved'] ?? false,
      addedAt: (data['addedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      addedBy: data['addedBy'] ?? '',
      addedVia: data['addedVia'] ?? 'unknown',
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      revokedAt: (data['revokedAt'] as Timestamp?)?.toDate(),
      revokedBy: data['revokedBy'],
      approvedForGroup: data['approvedForGroup'],
    );
  }

  // Conversión a Map
  Map<String, dynamic> toMap() {
    return {
      'users': users,
      'user1Name': user1Name,
      'user2Name': user2Name,
      'user1Email': user1Email,
      'user2Email': user2Email,
      'status': status,
      'autoApproved': autoApproved,
      'addedAt': Timestamp.fromDate(addedAt),
      'addedBy': addedBy,
      'addedVia': addedVia,
      if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
      if (revokedAt != null) 'revokedAt': Timestamp.fromDate(revokedAt!),
      if (revokedBy != null) 'revokedBy': revokedBy,
      if (approvedForGroup != null) 'approvedForGroup': approvedForGroup,
    };
  }

  // Getters computados
  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
  bool get isRevoked => status == 'revoked';

  /// Obtener el ID del otro usuario en el contacto
  String getOtherUserId(String currentUserId) {
    return users.firstWhere(
      (id) => id != currentUserId,
      orElse: () => '',
    );
  }

  // Static methods para consultas

  /// Verificar si ya existe un contacto entre dos usuarios
  static Future<Contact?> findBetween(String userId1, String userId2) async {
    final participants = [userId1, userId2]..sort();

    final query = await FirebaseFirestore.instance
        .collection('contacts')
        .where('users', isEqualTo: participants)
        .limit(1)
        .get();

    if (query.docs.isEmpty) return null;

    return Contact.fromFirestore(query.docs.first);
  }

  /// Verificar si existe un contacto aprobado entre dos usuarios
  static Future<bool> existsApprovedBetween(String userId1, String userId2) async {
    final contact = await findBetween(userId1, userId2);
    return contact?.isApproved ?? false;
  }

  /// Obtener todos los contactos aprobados de un usuario
  static Stream<List<Contact>> getApprovedByUser(String userId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: userId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Contact.fromFirestore(doc))
            .toList());
  }

  /// Obtener todos los contactos pendientes de un usuario
  static Stream<List<Contact>> getPendingByUser(String userId) {
    return FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: userId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Contact.fromFirestore(doc))
            .toList());
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

  /// Crear un nuevo contacto
  static Future<String> create(Map<String, dynamic> data) async {
    final docRef = await FirebaseFirestore.instance
        .collection('contacts')
        .add(data);

    return docRef.id;
  }

  /// Actualizar el estado del contacto
  Future<void> updateStatus(String newStatus, {String? updatedBy}) async {
    final updateData = <String, dynamic>{
      'status': newStatus,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (newStatus == 'approved') {
      updateData['approvedAt'] = FieldValue.serverTimestamp();
    } else if (newStatus == 'revoked') {
      updateData['revokedAt'] = FieldValue.serverTimestamp();
      if (updatedBy != null) updateData['revokedBy'] = updatedBy;
    }

    await FirebaseFirestore.instance
        .collection('contacts')
        .doc(id)
        .update(updateData);
  }

  /// Revocar el contacto
  Future<void> revoke(String revokedBy) async {
    await updateStatus('revoked', updatedBy: revokedBy);
  }

  /// Eliminar el contacto
  Future<void> delete() async {
    await FirebaseFirestore.instance
        .collection('contacts')
        .doc(id)
        .delete();
  }

  // Métodos de comparación
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Contact && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'Contact(id: $id, users: $users, status: $status)';
  }
}
