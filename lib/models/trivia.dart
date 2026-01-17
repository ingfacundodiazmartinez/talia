import 'package:cloud_firestore/cloud_firestore.dart';

/// Status de una trivia
enum TriviaStatus {
  active,   // Trivia abierta, aceptando respuestas
  closed,   // Cerrada manualmente por el creador
  expired,  // Expirada automáticamente (24h)
}

/// Modelo para la colección 'trivias'
///
/// Representa una trivia personal que los usuarios pueden crear
/// para que sus contactos respondan preguntas sobre ellos.
class Trivia {
  final String id;
  final String creatorId;
  final String creatorName;
  final String? creatorPhotoURL;
  final String title;
  final String? backgroundImageUrl;
  final List<String> questionIds;
  final DateTime createdAt;
  final DateTime expiresAt;
  final TriviaStatus status;
  final int participantCount;
  final bool hasResponses;
  final List<String> availableFor;
  final List<String> blockedUsers;
  final String? resultsStoryId;
  final bool reminderSent;

  Trivia({
    required this.id,
    required this.creatorId,
    required this.creatorName,
    this.creatorPhotoURL,
    required this.title,
    this.backgroundImageUrl,
    required this.questionIds,
    required this.createdAt,
    required this.expiresAt,
    this.status = TriviaStatus.active,
    this.participantCount = 0,
    this.hasResponses = false,
    required this.availableFor,
    this.blockedUsers = const [],
    this.resultsStoryId,
    this.reminderSent = false,
  });

  // ==================== Factory Constructors ====================

  factory Trivia.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Trivia.fromMap(doc.id, data);
  }

  factory Trivia.fromMap(String id, Map<String, dynamic> data) {
    return Trivia(
      id: id,
      creatorId: data['creatorId'] ?? '',
      creatorName: data['creatorName'] ?? 'Usuario',
      creatorPhotoURL: data['creatorPhotoURL'],
      title: data['title'] ?? '',
      backgroundImageUrl: data['backgroundImageUrl'],
      questionIds: List<String>.from(data['questionIds'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ??
          DateTime.now().add(const Duration(hours: 24)),
      status: _parseStatus(data['status']),
      participantCount: data['participantCount'] ?? 0,
      hasResponses: data['hasResponses'] ?? false,
      availableFor: List<String>.from(data['availableFor'] ?? []),
      blockedUsers: List<String>.from(data['blockedUsers'] ?? []),
      resultsStoryId: data['resultsStoryId'],
      reminderSent: data['reminderSent'] ?? false,
    );
  }

  static TriviaStatus _parseStatus(String? status) {
    switch (status) {
      case 'active':
        return TriviaStatus.active;
      case 'closed':
        return TriviaStatus.closed;
      case 'expired':
        return TriviaStatus.expired;
      default:
        return TriviaStatus.active;
    }
  }

  // ==================== Serialization ====================

  Map<String, dynamic> toFirestore() {
    return {
      'creatorId': creatorId,
      'creatorName': creatorName,
      'creatorPhotoURL': creatorPhotoURL,
      'title': title,
      'backgroundImageUrl': backgroundImageUrl,
      'questionIds': questionIds,
      'createdAt': Timestamp.fromDate(createdAt),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'status': status.name,
      'participantCount': participantCount,
      'hasResponses': hasResponses,
      'availableFor': availableFor,
      'blockedUsers': blockedUsers,
      'resultsStoryId': resultsStoryId,
      'reminderSent': reminderSent,
    };
  }

  // ==================== Computed Getters ====================

  /// Verifica si la trivia puede ser editada (solo si no hay respuestas)
  bool get isEditable => !hasResponses && status == TriviaStatus.active;

  /// Verifica si la trivia está activa y no expirada
  bool get isActive => status == TriviaStatus.active && !isExpired;

  /// Verifica si la trivia ha expirado
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Verifica si la trivia puede ser cerrada
  bool get canClose => status == TriviaStatus.active;

  /// Verifica si los resultados ya fueron compartidos
  bool get hasSharedResults => resultsStoryId != null;

  /// Cantidad de preguntas en la trivia
  int get questionCount => questionIds.length;

  /// Tiempo restante antes de expirar
  Duration get timeRemaining {
    final now = DateTime.now();
    if (now.isAfter(expiresAt)) return Duration.zero;
    return expiresAt.difference(now);
  }

  /// Porcentaje de tiempo transcurrido (0.0 - 1.0)
  double get timeElapsedPercent {
    final totalDuration = expiresAt.difference(createdAt);
    final elapsed = DateTime.now().difference(createdAt);
    return (elapsed.inSeconds / totalDuration.inSeconds).clamp(0.0, 1.0);
  }

  // ==================== Static Query Methods ====================

  static final _collection = FirebaseFirestore.instance.collection('trivias');

  /// Obtener una trivia por ID
  static Future<Trivia?> getById(String triviaId) async {
    final doc = await _collection.doc(triviaId).get();
    if (!doc.exists) return null;
    return Trivia.fromFirestore(doc);
  }

  /// Stream de una trivia específica
  static Stream<Trivia?> watchById(String triviaId) {
    return _collection.doc(triviaId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return Trivia.fromFirestore(doc);
    });
  }

  /// Stream de trivias activas disponibles para un usuario
  static Stream<List<Trivia>> watchActiveForUser(String userId) {
    return _collection
        .where('availableFor', arrayContains: userId)
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map(Trivia.fromFirestore)
            .where((t) => !t.isExpired && !t.blockedUsers.contains(userId))
            .toList());
  }

  /// Stream de trivias creadas por un usuario
  static Stream<List<Trivia>> watchCreatedByUser(String creatorId) {
    return _collection
        .where('creatorId', isEqualTo: creatorId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(Trivia.fromFirestore).toList());
  }

  /// Obtener trivias activas creadas por un usuario
  static Future<List<Trivia>> getActiveByCreator(String creatorId) async {
    final snapshot = await _collection
        .where('creatorId', isEqualTo: creatorId)
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt', descending: true)
        .get();
    return snapshot.docs
        .map(Trivia.fromFirestore)
        .where((t) => !t.isExpired)
        .toList();
  }

  // ==================== Copy With ====================

  Trivia copyWith({
    String? id,
    String? creatorId,
    String? creatorName,
    String? creatorPhotoURL,
    String? title,
    String? backgroundImageUrl,
    List<String>? questionIds,
    DateTime? createdAt,
    DateTime? expiresAt,
    TriviaStatus? status,
    int? participantCount,
    bool? hasResponses,
    List<String>? availableFor,
    List<String>? blockedUsers,
    String? resultsStoryId,
    bool? reminderSent,
  }) {
    return Trivia(
      id: id ?? this.id,
      creatorId: creatorId ?? this.creatorId,
      creatorName: creatorName ?? this.creatorName,
      creatorPhotoURL: creatorPhotoURL ?? this.creatorPhotoURL,
      title: title ?? this.title,
      backgroundImageUrl: backgroundImageUrl ?? this.backgroundImageUrl,
      questionIds: questionIds ?? this.questionIds,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      status: status ?? this.status,
      participantCount: participantCount ?? this.participantCount,
      hasResponses: hasResponses ?? this.hasResponses,
      availableFor: availableFor ?? this.availableFor,
      blockedUsers: blockedUsers ?? this.blockedUsers,
      resultsStoryId: resultsStoryId ?? this.resultsStoryId,
      reminderSent: reminderSent ?? this.reminderSent,
    );
  }

  @override
  String toString() {
    return 'Trivia(id: $id, title: $title, status: $status, questions: $questionCount, participants: $participantCount)';
  }
}
