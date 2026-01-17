/// Modelo para agrupar contactos por persona en la Lista Blanca
///
/// Permite mostrar un contacto una sola vez aunque tenga
/// relaciones con múltiples hijos del padre.
class GroupedContact {
  final String contactId;
  final String contactName;
  final String? contactPhone;
  final String? contactPhotoURL;
  final List<ChildRelation> childRelations;

  GroupedContact({
    required this.contactId,
    required this.contactName,
    this.contactPhone,
    this.contactPhotoURL,
    required this.childRelations,
  });

  /// Tiene al menos una relación pendiente
  bool get hasPending => childRelations.any((r) => r.status == 'pending');

  /// Tiene al menos una relación aprobada
  bool get hasApproved => childRelations.any((r) => r.status == 'approved');

  /// Tiene al menos una relación rechazada
  bool get hasRejected => childRelations.any((r) => r.status == 'rejected');

  /// Tiene al menos una relación revocada
  bool get hasRevoked => childRelations.any((r) => r.status == 'revoked');

  /// Cantidad de relaciones pendientes
  int get pendingCount =>
      childRelations.where((r) => r.status == 'pending').length;

  /// Cantidad de relaciones aprobadas
  int get approvedCount =>
      childRelations.where((r) => r.status == 'approved').length;

  /// Cantidad de relaciones rechazadas
  int get rejectedCount =>
      childRelations.where((r) => r.status == 'rejected').length;

  /// Cantidad de relaciones revocadas
  int get revokedCount =>
      childRelations.where((r) => r.status == 'revoked').length;

  /// Estado principal para ordenamiento (pending > approved > rejected > revoked)
  String get primaryStatus {
    if (hasPending) return 'pending';
    if (hasApproved) return 'approved';
    if (hasRejected) return 'rejected';
    return 'revoked';
  }

  /// Prioridad para ordenamiento (menor = más prioritario)
  int get sortPriority {
    if (hasPending) return 0;
    if (hasApproved) return 1;
    if (hasRejected) return 2;
    return 3; // revoked
  }

  /// Copia con nuevas relaciones
  GroupedContact copyWith({
    String? contactId,
    String? contactName,
    String? contactPhone,
    String? contactPhotoURL,
    List<ChildRelation>? childRelations,
  }) {
    return GroupedContact(
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      contactPhone: contactPhone ?? this.contactPhone,
      contactPhotoURL: contactPhotoURL ?? this.contactPhotoURL,
      childRelations: childRelations ?? this.childRelations,
    );
  }
}

/// Relación de un contacto con un hijo específico
///
/// Representa la aprobación de un padre para que su hijo
/// pueda comunicarse con este contacto.
class ChildRelation {
  final String childId;
  final String childName;
  final String? childPhotoURL;
  final String status; // pending | approved | rejected
  final String contactDocId; // ID del documento en /contacts
  final String type; // contact | group | group_v2
  final Map<String, dynamic> data;

  ChildRelation({
    required this.childId,
    required this.childName,
    this.childPhotoURL,
    required this.status,
    required this.contactDocId,
    required this.type,
    required this.data,
  });

  /// Es una solicitud pendiente
  bool get isPending => status == 'pending';

  /// Es una relación aprobada
  bool get isApproved => status == 'approved';

  /// Es una relación rechazada
  bool get isRejected => status == 'rejected';

  /// Es una relación revocada
  bool get isRevoked => status == 'revoked';

  /// Es un grupo (no un contacto individual)
  bool get isGroup => type == 'group' || type == 'group_v2';
}
