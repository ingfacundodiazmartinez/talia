import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado de una respuesta de trivia
enum ResponseStatus {
  inProgress, // Usuario respondiendo (puede interrumpirse)
  completed,  // Todas las preguntas respondidas
  partial,    // Interrumpido (app cerrada)
}

/// Respuesta individual a una pregunta
class QuestionAnswer {
  final String questionId;
  final String? selectedOptionId;
  final bool isCorrect;
  final int pointsEarned;
  final int responseTimeMs;
  final DateTime answeredAt;

  QuestionAnswer({
    required this.questionId,
    this.selectedOptionId,
    required this.isCorrect,
    required this.pointsEarned,
    required this.responseTimeMs,
    required this.answeredAt,
  });

  factory QuestionAnswer.fromMap(Map<String, dynamic> data) {
    return QuestionAnswer(
      questionId: data['questionId'] ?? '',
      selectedOptionId: data['selectedOptionId'],
      isCorrect: data['isCorrect'] ?? false,
      pointsEarned: data['pointsEarned'] ?? 0,
      responseTimeMs: data['responseTimeMs'] ?? 0,
      answeredAt:
          (data['answeredAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'questionId': questionId,
      'selectedOptionId': selectedOptionId,
      'isCorrect': isCorrect,
      'pointsEarned': pointsEarned,
      'responseTimeMs': responseTimeMs,
      'answeredAt': Timestamp.fromDate(answeredAt),
    };
  }

  /// Verifica si la pregunta fue respondida (no saltada/timeout)
  bool get wasAnswered => selectedOptionId != null;

  @override
  String toString() {
    return 'QuestionAnswer(questionId: $questionId, isCorrect: $isCorrect, points: $pointsEarned)';
  }
}

/// Modelo para la colección 'trivia_responses'
///
/// Representa la respuesta de un usuario a una trivia completa,
/// incluyendo todas las respuestas individuales y el puntaje total.
class TriviaResponse {
  final String id;
  final String oderId;
  final String oderName;
  final String? oderPhotoURL;
  final String triviaId;
  final ResponseStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final int totalScore;
  final int correctCount;
  final int totalQuestions;
  final List<QuestionAnswer> answers;
  final int timeSpentSeconds;

  TriviaResponse({
    required this.id,
    required this.oderId,
    required this.oderName,
    this.oderPhotoURL,
    required this.triviaId,
    this.status = ResponseStatus.inProgress,
    required this.startedAt,
    this.completedAt,
    this.totalScore = 0,
    this.correctCount = 0,
    required this.totalQuestions,
    this.answers = const [],
    this.timeSpentSeconds = 0,
  });

  // ==================== Factory Constructors ====================

  factory TriviaResponse.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TriviaResponse.fromMap(doc.id, data);
  }

  factory TriviaResponse.fromMap(String id, Map<String, dynamic> data) {
    return TriviaResponse(
      id: id,
      oderId: data['oderId'] ?? '',
      oderName: data['oderName'] ?? 'Usuario',
      oderPhotoURL: data['oderPhotoURL'],
      triviaId: data['triviaId'] ?? '',
      status: _parseStatus(data['status']),
      startedAt:
          (data['startedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      totalScore: data['totalScore'] ?? 0,
      correctCount: data['correctCount'] ?? 0,
      totalQuestions: data['totalQuestions'] ?? 0,
      answers: (data['answers'] as List<dynamic>?)
              ?.map((e) => QuestionAnswer.fromMap(e as Map<String, dynamic>))
              .toList() ??
          [],
      timeSpentSeconds: data['timeSpentSeconds'] ?? 0,
    );
  }

  static ResponseStatus _parseStatus(String? status) {
    switch (status) {
      case 'inProgress':
        return ResponseStatus.inProgress;
      case 'completed':
        return ResponseStatus.completed;
      case 'partial':
        return ResponseStatus.partial;
      default:
        return ResponseStatus.inProgress;
    }
  }

  // ==================== Serialization ====================

  Map<String, dynamic> toFirestore() {
    return {
      'oderId': oderId,
      'oderName': oderName,
      'oderPhotoURL': oderPhotoURL,
      'triviaId': triviaId,
      'status': status.name,
      'startedAt': Timestamp.fromDate(startedAt),
      'completedAt':
          completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'totalScore': totalScore,
      'correctCount': correctCount,
      'totalQuestions': totalQuestions,
      'answers': answers.map((a) => a.toMap()).toList(),
      'timeSpentSeconds': timeSpentSeconds,
    };
  }

  // ==================== Computed Getters ====================

  /// Verifica si la respuesta está completa
  bool get isComplete => status == ResponseStatus.completed;

  /// Verifica si la respuesta fue interrumpida
  bool get isPartial => status == ResponseStatus.partial;

  /// Verifica si está en progreso
  bool get isInProgress => status == ResponseStatus.inProgress;

  /// Porcentaje de respuestas correctas (0.0 - 1.0)
  double get accuracy =>
      totalQuestions > 0 ? correctCount / totalQuestions : 0.0;

  /// Porcentaje de respuestas correctas como entero (0 - 100)
  int get accuracyPercent => (accuracy * 100).round();

  /// Cantidad de preguntas respondidas
  int get answeredCount => answers.length;

  /// Porcentaje de progreso (0.0 - 1.0)
  double get progress =>
      totalQuestions > 0 ? answeredCount / totalQuestions : 0.0;

  /// Tiempo promedio de respuesta en milisegundos
  int get averageResponseTimeMs {
    if (answers.isEmpty) return 0;
    final totalTime =
        answers.fold<int>(0, (total, a) => total + a.responseTimeMs);
    return totalTime ~/ answers.length;
  }

  /// Verifica si el usuario ya respondió una pregunta específica
  bool hasAnsweredQuestion(String questionId) {
    return answers.any((a) => a.questionId == questionId);
  }

  /// Obtiene la respuesta a una pregunta específica
  QuestionAnswer? getAnswerForQuestion(String questionId) {
    try {
      return answers.firstWhere((a) => a.questionId == questionId);
    } catch (_) {
      return null;
    }
  }

  // ==================== Static Methods ====================

  /// Genera el ID del documento (oderId_triviaId)
  static String generateId(String oderId, String triviaId) {
    return '${oderId}_$triviaId';
  }

  static final _collection =
      FirebaseFirestore.instance.collection('trivia_responses');

  /// Obtener una respuesta por usuario y trivia
  static Future<TriviaResponse?> getByUserAndTrivia(
      String oderId, String triviaId) async {
    final id = generateId(oderId, triviaId);
    final doc = await _collection.doc(id).get();
    if (!doc.exists) return null;
    return TriviaResponse.fromFirestore(doc);
  }

  /// Verificar si un usuario ya respondió una trivia
  static Future<bool> hasUserResponded(String oderId, String triviaId) async {
    final id = generateId(oderId, triviaId);
    final doc = await _collection.doc(id).get();
    return doc.exists;
  }

  /// Stream de respuestas de una trivia (para leaderboard)
  static Stream<List<TriviaResponse>> watchByTrivia(String triviaId) {
    return _collection
        .where('triviaId', isEqualTo: triviaId)
        .where('status', whereIn: ['completed', 'partial'])
        .orderBy('totalScore', descending: true)
        .orderBy('completedAt', descending: false)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map(TriviaResponse.fromFirestore).toList());
  }

  /// Obtener el leaderboard de una trivia
  static Future<List<TriviaResponse>> getLeaderboard(String triviaId,
      {int limit = 10}) async {
    final snapshot = await _collection
        .where('triviaId', isEqualTo: triviaId)
        .where('status', whereIn: ['completed', 'partial'])
        .orderBy('totalScore', descending: true)
        .orderBy('completedAt', descending: false)
        .limit(limit)
        .get();
    return snapshot.docs.map(TriviaResponse.fromFirestore).toList();
  }

  /// Contar participantes de una trivia
  static Future<int> countParticipants(String triviaId) async {
    final snapshot = await _collection
        .where('triviaId', isEqualTo: triviaId)
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  /// Stream de la respuesta de un usuario específico
  static Stream<TriviaResponse?> watchUserResponse(
      String oderId, String triviaId) {
    final id = generateId(oderId, triviaId);
    return _collection.doc(id).snapshots().map((doc) {
      if (!doc.exists) return null;
      return TriviaResponse.fromFirestore(doc);
    });
  }

  /// Stream de IDs de trivias que el usuario ha respondido (completadas o parciales)
  /// Usado para determinar si mostrar el gradiente "no visto" en stories_section
  static Stream<Set<String>> watchRespondedTriviaIds(String oderId) {
    return _collection
        .where('oderId', isEqualTo: oderId)
        .where('status', whereIn: ['completed', 'partial'])
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) {
              final data = doc.data();
              return data['triviaId'] as String? ?? '';
            }).where((id) => id.isNotEmpty).toSet());
  }

  // ==================== Copy With ====================

  TriviaResponse copyWith({
    String? id,
    String? oderId,
    String? oderName,
    String? oderPhotoURL,
    String? triviaId,
    ResponseStatus? status,
    DateTime? startedAt,
    DateTime? completedAt,
    int? totalScore,
    int? correctCount,
    int? totalQuestions,
    List<QuestionAnswer>? answers,
    int? timeSpentSeconds,
  }) {
    return TriviaResponse(
      id: id ?? this.id,
      oderId: oderId ?? this.oderId,
      oderName: oderName ?? this.oderName,
      oderPhotoURL: oderPhotoURL ?? this.oderPhotoURL,
      triviaId: triviaId ?? this.triviaId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      totalScore: totalScore ?? this.totalScore,
      correctCount: correctCount ?? this.correctCount,
      totalQuestions: totalQuestions ?? this.totalQuestions,
      answers: answers ?? this.answers,
      timeSpentSeconds: timeSpentSeconds ?? this.timeSpentSeconds,
    );
  }

  @override
  String toString() {
    return 'TriviaResponse(id: $id, oderId: $oderId, score: $totalScore, status: $status)';
  }
}

/// Entrada del leaderboard con ranking
class TriviaLeaderboardEntry {
  final TriviaResponse response;
  final int rank;

  TriviaLeaderboardEntry({
    required this.response,
    required this.rank,
  });

  String get oderId => response.oderId;
  String get oderName => response.oderName;
  String? get oderPhotoURL => response.oderPhotoURL;
  int get score => response.totalScore;
  int get correctCount => response.correctCount;
  int get totalQuestions => response.totalQuestions;
  DateTime? get completedAt => response.completedAt;
  double get accuracy => response.accuracy;

  /// Verifica si está en el podio (top 3)
  bool get isOnPodium => rank <= 3;

  /// Obtiene el emoji de medalla según el ranking
  String get medalEmoji {
    switch (rank) {
      case 1:
        return '🥇';
      case 2:
        return '🥈';
      case 3:
        return '🥉';
      default:
        return '';
    }
  }

  @override
  String toString() {
    return 'TriviaLeaderboardEntry(rank: $rank, oderId: $oderId, score: $score)';
  }
}
