import 'package:cloud_firestore/cloud_firestore.dart';

enum StoryStatus {
  pending,    // Esperando aprobación del padre
  approved,   // Aprobada y visible para contactos
  rejected,   // Rechazada por el padre
  expired,    // Expirada (24h)
}

class Story {
  final String id;
  final String userId;
  final String userName;
  final String? userPhotoURL;
  final String mediaUrl;
  final String mediaType; // 'image' or 'video'
  final String? caption;
  final DateTime createdAt;
  final DateTime expiresAt;
  final List<String> viewedBy;
  final Map<String, dynamic>? filter; // Información del filtro aplicado
  final StoryStatus status;
  final String? approvedBy; // ID del padre que aprobó
  final DateTime? approvedAt; // Cuándo fue aprobada
  final String? rejectionReason; // Razón del rechazo (opcional)

  Story({
    required this.id,
    required this.userId,
    required this.userName,
    this.userPhotoURL,
    required this.mediaUrl,
    required this.mediaType,
    this.caption,
    required this.createdAt,
    required this.expiresAt,
    required this.viewedBy,
    this.filter,
    this.status = StoryStatus.pending,
    this.approvedBy,
    this.approvedAt,
    this.rejectionReason,
  });

  // Factory constructor para crear desde Firestore
  factory Story.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return Story(
      id: doc.id,
      userId: data['userId'] ?? '',
      userName: data['userName'] ?? 'Usuario',
      userPhotoURL: data['userPhotoURL'],
      mediaUrl: data['mediaUrl'] ?? '',
      mediaType: data['mediaType'] ?? 'image',
      caption: data['caption'],
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      expiresAt: (data['expiresAt'] as Timestamp).toDate(),
      viewedBy: List<String>.from(data['viewedBy'] ?? []),
      filter: data['filter'],
      status: _parseStoryStatus(data['status']),
      approvedBy: data['approvedBy'],
      approvedAt: data['approvedAt'] != null ? (data['approvedAt'] as Timestamp).toDate() : null,
      rejectionReason: data['rejectionReason'],
    );
  }

  static StoryStatus _parseStoryStatus(dynamic status) {
    if (status == null) return StoryStatus.pending;

    switch (status.toString()) {
      case 'approved':
        return StoryStatus.approved;
      case 'rejected':
        return StoryStatus.rejected;
      case 'expired':
        return StoryStatus.expired;
      case 'pending':
      default:
        return StoryStatus.pending;
    }
  }

  // Convertir a Map para Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'userName': userName,
      'userPhotoURL': userPhotoURL,
      'mediaUrl': mediaUrl,
      'mediaType': mediaType,
      'caption': caption,
      'createdAt': Timestamp.fromDate(createdAt),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'viewedBy': viewedBy,
      'filter': filter,
      'status': status.toString().split('.').last,
      'approvedBy': approvedBy,
      'approvedAt': approvedAt != null ? Timestamp.fromDate(approvedAt!) : null,
      'rejectionReason': rejectionReason,
    };
  }

  // Verificar si la historia ha expirado
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  // Verificar si el usuario actual ya vio la historia
  bool isViewedBy(String userId) => viewedBy.contains(userId);

  // Verificar si la historia está visible para contactos
  bool get isVisibleToContacts => status == StoryStatus.approved && !isExpired;

  // Verificar si la historia está pendiente de aprobación
  bool get isPending => status == StoryStatus.pending && !isExpired;

  // Verificar si la historia fue rechazada
  bool get isRejected => status == StoryStatus.rejected;

  // Obtener texto descriptivo del estado
  String get statusText {
    switch (status) {
      case StoryStatus.pending:
        return 'Esperando aprobación';
      case StoryStatus.approved:
        return 'Aprobada';
      case StoryStatus.rejected:
        return 'Rechazada';
      case StoryStatus.expired:
        return 'Expirada';
    }
  }

  // Crear una copia con campos actualizados
  Story copyWith({
    String? id,
    String? userId,
    String? userName,
    String? userPhotoURL,
    String? mediaUrl,
    String? mediaType,
    String? caption,
    DateTime? createdAt,
    DateTime? expiresAt,
    List<String>? viewedBy,
    Map<String, dynamic>? filter,
    StoryStatus? status,
    String? approvedBy,
    DateTime? approvedAt,
    String? rejectionReason,
  }) {
    return Story(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userPhotoURL: userPhotoURL ?? this.userPhotoURL,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaType: mediaType ?? this.mediaType,
      caption: caption ?? this.caption,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      viewedBy: viewedBy ?? this.viewedBy,
      filter: filter ?? this.filter,
      status: status ?? this.status,
      approvedBy: approvedBy ?? this.approvedBy,
      approvedAt: approvedAt ?? this.approvedAt,
      rejectionReason: rejectionReason ?? this.rejectionReason,
    );
  }
}

// Clase para agrupar historias por usuario
class UserStories {
  final String userId;
  final String userName;
  final String? userPhotoURL;
  final List<Story> stories;
  final bool hasUnviewed;

  UserStories({
    required this.userId,
    required this.userName,
    this.userPhotoURL,
    required this.stories,
    required this.hasUnviewed,
  });

  // Obtener la historia más reciente para mostrar en el preview (solo aprobadas)
  Story? get latestStory {
    if (stories.isEmpty) return null;

    final visibleStories = stories.where((story) => story.isVisibleToContacts).toList();
    if (visibleStories.isEmpty) return null;

    visibleStories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return visibleStories.first;
  }

  // Obtener historias ordenadas por fecha de creación (solo aprobadas y no expiradas)
  List<Story> get sortedStories {
    final visibleStories = stories.where((story) => story.isVisibleToContacts).toList();
    visibleStories.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return visibleStories;
  }

  // Obtener todas las historias del usuario (incluyendo pendientes/rechazadas) - para el propio usuario
  List<Story> get allUserStories {
    final nonExpiredStories = stories.where((story) => !story.isExpired).toList();
    nonExpiredStories.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return nonExpiredStories;
  }

  // Obtener historias pendientes de aprobación
  List<Story> get pendingStories {
    return stories.where((story) => story.isPending).toList();
  }
}