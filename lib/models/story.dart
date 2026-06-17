import 'package:cloud_firestore/cloud_firestore.dart';

enum StoryStatus {
  uploading,  // Subiendo media a Firebase Storage
  pending,    // Esperando aprobación del padre
  approved,   // Aprobada y visible para contactos
  rejected,   // Rechazada por el padre
  expired,    // Expirada (24h)
  failed,     // Falló la subida; se guarda localmente para reintentar
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

/// Una línea de la letra con su ventana de tiempo (ms absolutos de la canción),
/// usada para resaltar la línea actual mientras suena (karaoke línea por línea).
class LyricLine {
  final String text;
  final int startMs;
  final int endMs;

  const LyricLine({required this.text, required this.startMs, required this.endMs});

  factory LyricLine.fromMap(Map<String, dynamic> data) {
    return LyricLine(
      text: (data['text'] ?? '').toString(),
      startMs: (data['startMs'] as num?)?.toInt() ?? 0,
      endMs: (data['endMs'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {'text': text, 'startMs': startMs, 'endMs': endMs};
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
  final String? localMediaPath; // Path local del media (para subida optimista)
  final double uploadProgress; // Progreso de subida (0.0 - 1.0)
  final String? uploadError; // Error durante la subida (si lo hay)
  final List<String> availableFor; // IDs de usuarios que pueden ver esta historia (contactos al momento de crear)
  final List<String> parentViewers; // IDs de padres que pueden ver/aprobar esta historia (para queries optimizadas)
  final List<String> likedBy; // IDs de usuarios que dieron like a esta historia
  final bool aiGenerated; // true si la historia se creó con face-swap / IA
  final bool isOfficial; // true si fue autorada por Talia (sistema)
  final bool isBroadcast; // true si es un comunicado para todos los usuarios
  final String? musicUrl; // URL de la canción generada con IA (opcional)
  final String? musicPrompt; // Descripción usada para generar la canción
  final String? musicLyrics; // Letra de la canción (para mostrar en la historia)
  final int? musicStartMs; // Inicio del recorte de la canción (ms)
  final int? musicClipMs; // Duración del clip de la canción (ms)
  final String? musicTitle; // Título de la canción (para el modo 'title')
  final String? musicDisplayMode; // 'title' | 'lyrics' — qué mostrar en la historia
  final List<LyricLine> musicLyricsTimings; // líneas con timing (ms abs) para karaoke

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
    this.localMediaPath,
    this.uploadProgress = 0.0,
    this.uploadError,
    this.availableFor = const [],
    this.parentViewers = const [],
    this.likedBy = const [],
    this.aiGenerated = false,
    this.isOfficial = false,
    this.isBroadcast = false,
    this.musicUrl,
    this.musicPrompt,
    this.musicLyrics,
    this.musicStartMs,
    this.musicClipMs,
    this.musicTitle,
    this.musicDisplayMode,
    this.musicLyricsTimings = const [],
  });

  // Factory constructor para crear desde Firestore
  factory Story.fromFirestore(DocumentSnapshot doc) {
    try {
      final data = doc.data() as Map<String, dynamic>;

      // Parse replies with robust error handling
      List<StoryReply> replies = [];
      try {
        final repliesData = data['replies'];
        if (repliesData != null && repliesData is List<dynamic>) {
          replies = repliesData
              .whereType<Map<String, dynamic>>()
              .map((reply) => StoryReply.fromMap(reply))
              .toList();
        }
      } catch (e) {
        // Silently handle malformed replies data
        replies = [];
      }

      // Parse viewedBy with robust error handling
      List<String> viewedBy = [];
      try {
        final viewedByData = data['viewedBy'];
        if (viewedByData != null) {
          if (viewedByData is List<dynamic>) {
            viewedBy = viewedByData.whereType<String>().toList();
          }
        }
      } catch (e) {
        viewedBy = [];
      }

      // Parse availableFor with robust error handling
      List<String> availableFor = [];
      try {
        final availableForData = data['availableFor'];
        if (availableForData != null) {
          if (availableForData is List<dynamic>) {
            availableFor = availableForData.whereType<String>().toList();
          }
        }
      } catch (e) {
        availableFor = [];
      }

      // Parse parentViewers with robust error handling
      List<String> parentViewers = [];
      try {
        final parentViewersData = data['parentViewers'];
        if (parentViewersData != null) {
          if (parentViewersData is List<dynamic>) {
            parentViewers = parentViewersData.whereType<String>().toList();
          }
        }
      } catch (e) {
        parentViewers = [];
      }

      // Parse likedBy with robust error handling
      List<String> likedBy = [];
      try {
        final likedByData = data['likedBy'];
        if (likedByData != null) {
          if (likedByData is List<dynamic>) {
            likedBy = likedByData.whereType<String>().toList();
          }
        }
      } catch (e) {
        likedBy = [];
      }

    return Story(
      id: doc.id,
      userId: data['userId'] ?? '',
      userName: data['userName'] ?? 'Usuario',
      userPhotoURL: data['userPhotoURL'],
      mediaUrl: data['mediaUrl'] ?? '',
      mediaType: data['mediaType'] ?? 'image',
      caption: data['caption'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ?? DateTime.now().add(Duration(hours: 24)),
      viewedBy: viewedBy,
      replies: replies,
      filter: data['filter'],
      status: _parseStoryStatus(data['status']),
      approvedBy: data['approvedBy'],
      approvedAt: data['approvedAt'] != null ? (data['approvedAt'] as Timestamp).toDate() : null,
      rejectionReason: data['rejectionReason'],
      visibility: _parseStoryVisibility(data['visibility']),
      savedToPermanentAt: data['savedToPermanentAt'] != null ? (data['savedToPermanentAt'] as Timestamp).toDate() : null,
      availableFor: availableFor,
      parentViewers: parentViewers,
      likedBy: likedBy,
      aiGenerated: data['aiGenerated'] == true,
      isOfficial: data['isOfficial'] == true,
      isBroadcast: data['isBroadcast'] == true,
      musicUrl: data['musicUrl'],
      musicPrompt: data['musicPrompt'],
      musicLyrics: data['musicLyrics'],
      musicStartMs: (data['musicStartMs'] as num?)?.toInt(),
      musicClipMs: (data['musicClipMs'] as num?)?.toInt(),
      musicTitle: data['musicTitle'],
      musicDisplayMode: data['musicDisplayMode'],
      musicLyricsTimings: _parseLyricTimings(data['musicLyricsTimings']),
    );
    } catch (e) {
      throw Exception('Error parsing story ${doc.id}: $e. Data keys: ${(doc.data() as Map<String, dynamic>?)?.keys.toList()}');
    }
  }

  static List<LyricLine> _parseLyricTimings(dynamic raw) {
    if (raw is! List) return const [];
    try {
      return raw
          .whereType<Map>()
          .map((m) => LyricLine.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static StoryStatus _parseStoryStatus(dynamic status) {
    if (status == null) return StoryStatus.pending;

    switch (status.toString()) {
      case 'uploading':
        return StoryStatus.uploading;
      case 'approved':
        return StoryStatus.approved;
      case 'rejected':
        return StoryStatus.rejected;
      case 'expired':
        return StoryStatus.expired;
      case 'failed':
        return StoryStatus.failed;
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
      'availableFor': availableFor,
      'parentViewers': parentViewers,
      'likedBy': likedBy,
      'aiGenerated': aiGenerated,
      'isOfficial': isOfficial,
      'isBroadcast': isBroadcast,
      'musicUrl': musicUrl,
      'musicPrompt': musicPrompt,
      'musicLyrics': musicLyrics,
      'musicStartMs': musicStartMs,
      'musicClipMs': musicClipMs,
      'musicTitle': musicTitle,
      'musicDisplayMode': musicDisplayMode,
      'musicLyricsTimings': musicLyricsTimings.map((l) => l.toMap()).toList(),
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

  // Verificar si la historia está subiendo
  bool get isUploading => status == StoryStatus.uploading;

  // Verificar si la subida falló (se guarda localmente para reintentar)
  bool get isFailed => status == StoryStatus.failed;

  // Obtener texto descriptivo del estado
  String get statusText {
    switch (status) {
      case StoryStatus.uploading:
        return 'Subiendo...';
      case StoryStatus.pending:
        return 'Esperando aprobación';
      case StoryStatus.approved:
        return 'Aprobada';
      case StoryStatus.rejected:
        return 'Rechazada';
      case StoryStatus.expired:
        return 'Expirada';
      case StoryStatus.failed:
        return 'No se pudo subir';
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
    String? localMediaPath,
    double? uploadProgress,
    String? uploadError,
    List<String>? availableFor,
    List<String>? parentViewers,
    List<String>? likedBy,
    bool? aiGenerated,
    bool? isOfficial,
    bool? isBroadcast,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<LyricLine>? musicLyricsTimings,
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
      localMediaPath: localMediaPath ?? this.localMediaPath,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      uploadError: uploadError ?? this.uploadError,
      availableFor: availableFor ?? this.availableFor,
      parentViewers: parentViewers ?? this.parentViewers,
      likedBy: likedBy ?? this.likedBy,
      aiGenerated: aiGenerated ?? this.aiGenerated,
      isOfficial: isOfficial ?? this.isOfficial,
      isBroadcast: isBroadcast ?? this.isBroadcast,
      musicUrl: musicUrl ?? this.musicUrl,
      musicPrompt: musicPrompt ?? this.musicPrompt,
      musicLyrics: musicLyrics ?? this.musicLyrics,
      musicStartMs: musicStartMs ?? this.musicStartMs,
      musicClipMs: musicClipMs ?? this.musicClipMs,
      musicTitle: musicTitle ?? this.musicTitle,
      musicDisplayMode: musicDisplayMode ?? this.musicDisplayMode,
      musicLyricsTimings: musicLyricsTimings ?? this.musicLyricsTimings,
    );
  }

  // Verificar si un usuario dio like a esta historia
  bool isLikedBy(String userId) => likedBy.contains(userId);

  // Obtener cantidad de likes
  int get likesCount => likedBy.length;

  // true si la historia tiene una canción asociada
  bool get hasMusic => musicUrl != null && musicUrl!.isNotEmpty;

  // true si es una historia de solo música (sin foto/video)
  bool get isMusicOnly => mediaType == 'music';

  // true si la historia de música debe mostrar la letra sincronizada (karaoke).
  bool get showsKaraokeLyrics =>
      musicDisplayMode == 'lyrics' && musicLyricsTimings.isNotEmpty;

  // true si es una música legacy (sin displayMode) que solo tiene letra estática.
  bool get hasLegacyStaticLyrics =>
      musicDisplayMode == null &&
      musicLyrics != null &&
      musicLyrics!.trim().isNotEmpty;
}

// Clase para agrupar historias por usuario
class UserStories {
  final String userId;
  final String userName;
  final String? userPhotoURL;
  final List<Story> stories;
  final bool hasUnviewed;
  final bool isOfficial; // true si es la cuenta oficial de Talia

  UserStories({
    required this.userId,
    required this.userName,
    this.userPhotoURL,
    required this.stories,
    required this.hasUnviewed,
    this.isOfficial = false,
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

  // Como allUserStories pero SIN filtrar expiradas. Usado en "Mis historias"
  // del perfil donde el user quiere ver su histórico completo, incluso
  // historias fuera de 24h.
  List<Story> get allUserStoriesIncludingExpired {
    final all = List<Story>.from(stories);
    all.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all;
  }

  // Obtener historias pendientes de aprobación
  List<Story> get pendingStories {
    return stories.where((story) => story.isPending).toList();
  }
}