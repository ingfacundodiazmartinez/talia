import 'package:cloud_firestore/cloud_firestore.dart';

enum StoryStatus {
  pending,    // Esperando aprobación del padre
  approved,   // Aprobada y visible para contactos
  rejected,   // Rechazada por el padre
  expired,    // Expirada (24h)
}

enum StoryVisibility {
  temporary,  // Historia temporal (24h en feed)
  permanent,  // Historia permanente (visible en perfil)
  archived,   // Historia archivada (no visible pero no eliminada)
}

class StoryReply {
  final String userId;
  final String userName;
  final String? userPhotoURL;
  final String text;
  final DateTime timestamp;

  StoryReply({
    required this.userId,
    required this.userName,
    this.userPhotoURL,
    required this.text,
    required this.timestamp,
  });

  factory StoryReply.fromMap(Map<String, dynamic> data) {
    return StoryReply(
      userId: data['userId'] ?? '',
      userName: data['userName'] ?? 'Usuario',
      userPhotoURL: data['userPhotoURL'],
      text: data['text'] ?? '',
      timestamp: (data['timestamp'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userName': userName,
      'userPhotoURL': userPhotoURL,
      'text': text,
      'timestamp': Timestamp.fromDate(timestamp),
    };
  }
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
  final List<StoryReply> replies; // Respuestas a la historia
  final Map<String, dynamic>? filter; // Información del filtro aplicado
  final StoryStatus status;
  final String? approvedBy; // ID del padre que aprobó
  final DateTime? approvedAt; // Cuándo fue aprobada
  final String? rejectionReason; // Razón del rechazo (opcional)
  final StoryVisibility visibility; // Visibilidad de la historia (temporal/permanent/archived)
  final DateTime? savedToPermanentAt; // Cuándo se guardó como permanente

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
    this.replies = const [],
    this.filter,
    this.status = StoryStatus.pending,
    this.approvedBy,
    this.approvedAt,
    this.rejectionReason,
    this.visibility = StoryVisibility.temporary,
    this.savedToPermanentAt,
  });

  // Factory constructor para crear desde Firestore
  factory Story.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    // Parse replies
    final repliesList = data['replies'] as List<dynamic>? ?? [];
    final replies = repliesList
        .map((reply) => StoryReply.fromMap(reply as Map<String, dynamic>))
        .toList();

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
      replies: replies,
      filter: data['filter'],
      status: _parseStoryStatus(data['status']),
      approvedBy: data['approvedBy'],
      approvedAt: data['approvedAt'] != null ? (data['approvedAt'] as Timestamp).toDate() : null,
      rejectionReason: data['rejectionReason'],
      visibility: _parseStoryVisibility(data['visibility']),
      savedToPermanentAt: data['savedToPermanentAt'] != null ? (data['savedToPermanentAt'] as Timestamp).toDate() : null,
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

  static StoryVisibility _parseStoryVisibility(dynamic visibility) {
    if (visibility == null) return StoryVisibility.temporary;

    switch (visibility.toString()) {
      case 'permanent':
        return StoryVisibility.permanent;
      case 'archived':
        return StoryVisibility.archived;
      case 'temporary':
      default:
        return StoryVisibility.temporary;
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
      'replies': replies.map((reply) => reply.toMap()).toList(),
      'filter': filter,
      'status': status.toString().split('.').last,
      'approvedBy': approvedBy,
      'approvedAt': approvedAt != null ? Timestamp.fromDate(approvedAt!) : null,
      'rejectionReason': rejectionReason,
      'visibility': visibility.toString().split('.').last,
      'savedToPermanentAt': savedToPermanentAt != null ? Timestamp.fromDate(savedToPermanentAt!) : null,
    };
  }

  // Verificar si la historia ha expirado
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  // Verificar si el usuario actual ya vio la historia
  bool isViewedBy(String userId) => viewedBy.contains(userId);

  // Verificar si la historia está visible para contactos (temporales en feed)
  bool get isVisibleToContacts => status == StoryStatus.approved && !isExpired && visibility == StoryVisibility.temporary;

  // Verificar si la historia está visible en perfil (permanentes)
  bool get isVisibleInProfile => status == StoryStatus.approved && visibility == StoryVisibility.permanent;

  // Verificar si la historia está archivada
  bool get isArchived => visibility == StoryVisibility.archived;

  // Verificar si la historia está pendiente de aprobación
  bool get isPending => status == StoryStatus.pending && !isExpired;

  // Verificar si la historia fue rechazada
  bool get isRejected => status == StoryStatus.rejected;

  // Verificar si es permanente (guardada en perfil o archivada)
  bool get isPermanent => visibility == StoryVisibility.permanent || visibility == StoryVisibility.archived;

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

  // Obtener texto descriptivo de visibilidad
  String get visibilityText {
    switch (visibility) {
      case StoryVisibility.temporary:
        return 'Temporal (24h)';
      case StoryVisibility.permanent:
        return 'En perfil';
      case StoryVisibility.archived:
        return 'Archivada';
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
    List<StoryReply>? replies,
    Map<String, dynamic>? filter,
    StoryStatus? status,
    String? approvedBy,
    DateTime? approvedAt,
    String? rejectionReason,
    StoryVisibility? visibility,
    DateTime? savedToPermanentAt,
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
      replies: replies ?? this.replies,
      filter: filter ?? this.filter,
      status: status ?? this.status,
      approvedBy: approvedBy ?? this.approvedBy,
      approvedAt: approvedAt ?? this.approvedAt,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      visibility: visibility ?? this.visibility,
      savedToPermanentAt: savedToPermanentAt ?? this.savedToPermanentAt,
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