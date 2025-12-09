import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/mood_poll.dart';

/// Repositorio para operaciones CRUD de mood polls
///
/// Maneja las colecciones:
/// - mood_poll_questions: Preguntas disponibles (predefinidas + generadas por IA)
/// - mood_poll_responses: Respuestas de los usuarios
/// - mood_poll_schedules: Control de cuándo mostrar encuestas a cada usuario
class MoodPollRepository {
  final FirebaseFirestore _firestore;

  MoodPollRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  // Referencias a colecciones
  CollectionReference<Map<String, dynamic>> get _questionsCollection =>
      _firestore.collection('mood_poll_questions');

  CollectionReference<Map<String, dynamic>> get _responsesCollection =>
      _firestore.collection('mood_poll_responses');

  CollectionReference<Map<String, dynamic>> get _schedulesCollection =>
      _firestore.collection('mood_poll_schedules');

  // ============ QUESTIONS ============

  /// Obtener todas las preguntas activas
  Future<List<MoodPollQuestion>> getActiveQuestions() async {
    final snapshot = await _questionsCollection
        .where('enabled', isEqualTo: true)
        .get();

    return snapshot.docs
        .map((doc) => MoodPollQuestion.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Obtener una pregunta por ID
  Future<MoodPollQuestion?> getQuestionById(String questionId) async {
    final doc = await _questionsCollection.doc(questionId).get();
    if (!doc.exists) return null;
    return MoodPollQuestion.fromFirestore(doc.id, doc.data()!);
  }

  /// Crear una nueva pregunta (para IA o admin)
  Future<String> createQuestion(MoodPollQuestion question) async {
    final docRef = await _questionsCollection.add(question.toFirestore());
    return docRef.id;
  }

  /// Actualizar una pregunta
  Future<void> updateQuestion(String questionId, Map<String, dynamic> data) async {
    await _questionsCollection.doc(questionId).update(data);
  }

  /// Desactivar una pregunta
  Future<void> deactivateQuestion(String questionId) async {
    await _questionsCollection.doc(questionId).update({'enabled': false});
  }

  // ============ RESPONSES ============

  /// Guardar respuesta de un usuario
  Future<String> saveResponse(MoodPollResponse response) async {
    final docRef = await _responsesCollection.add(response.toFirestore());
    return docRef.id;
  }

  /// Obtener respuestas de un usuario en un rango de fechas
  Future<List<MoodPollResponse>> getUserResponses({
    required String oderId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final snapshot = await _responsesCollection
        .where('userId', isEqualTo: oderId)
        .where('respondedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate))
        .where('respondedAt', isLessThanOrEqualTo: Timestamp.fromDate(endDate))
        .orderBy('respondedAt', descending: true)
        .get();

    return snapshot.docs
        .map((doc) => MoodPollResponse.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Obtener respuestas de la última semana
  Future<List<MoodPollResponse>> getWeeklyResponses(String oderId) async {
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    return getUserResponses(
      oderId: oderId,
      startDate: weekAgo,
      endDate: now,
    );
  }

  /// Actualizar respuesta (para marcar como compartida en story)
  Future<void> updateResponse(String responseId, Map<String, dynamic> data) async {
    await _responsesCollection.doc(responseId).update(data);
  }

  /// Marcar respuesta como compartida en story
  Future<void> markAsSharedInStory(String responseId, String storyId) async {
    await _responsesCollection.doc(responseId).update({
      'sharedAsStory': true,
      'storyId': storyId,
    });
  }

  // ============ SCHEDULES ============

  /// Obtener el schedule de encuestas para un usuario
  Future<MoodPollSchedule?> getUserSchedule(String oderId) async {
    final doc = await _schedulesCollection.doc(oderId).get();
    if (!doc.exists) return null;
    return MoodPollSchedule.fromFirestore(oderId, doc.data()!);
  }

  /// Crear o actualizar schedule de un usuario
  Future<void> saveUserSchedule(MoodPollSchedule schedule) async {
    await _schedulesCollection.doc(schedule.userId).set(
      schedule.toFirestore(),
      SetOptions(merge: true),
    );
  }

  /// Registrar que se mostró una encuesta al usuario
  Future<void> recordPollShown({
    required String oderId,
    required String questionId,
    required DateTime shownAt,
  }) async {
    await _schedulesCollection.doc(oderId).set({
      'lastPollShownAt': Timestamp.fromDate(shownAt),
      'pollsShownThisWeek': FieldValue.increment(1),
      'lastQuestionId': questionId,
      'shownQuestionIds': FieldValue.arrayUnion([questionId]),
    }, SetOptions(merge: true));
  }

  /// Resetear contador semanal (llamado por Cloud Function)
  Future<void> resetWeeklyCounter(String oderId) async {
    await _schedulesCollection.doc(oderId).update({
      'pollsShownThisWeek': 0,
      'shownQuestionIds': [],
      'weekStartDate': Timestamp.fromDate(DateTime.now()),
    });
  }

  // ============ STATS ============

  /// Calcular estadísticas de mood para un período
  Future<MoodPollStats> calculateStats({
    required String oderId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final responses = await getUserResponses(
      oderId: oderId,
      startDate: startDate,
      endDate: endDate,
    );

    // Contar por tipo
    final responsesByType = <MoodPollQuestionType, int>{};
    double totalSentiment = 0;

    for (final response in responses) {
      totalSentiment += response.sentimentScore;
      // Nota: necesitaríamos el tipo de la pregunta original para esto
      // Por ahora asumimos que está en el response o lo obtenemos de otra forma
    }

    final avgSentiment = responses.isNotEmpty
        ? totalSentiment / responses.length
        : 0.0;

    // Obtener total de preguntas mostradas
    final schedule = await getUserSchedule(oderId);
    final totalQuestions = schedule?.pollsShownThisWeek ?? 0;

    return MoodPollStats(
      userId: oderId,
      periodStart: startDate,
      periodEnd: endDate,
      totalQuestions: totalQuestions,
      totalResponses: responses.length,
      averageSentiment: avgSentiment,
      responsesByType: responsesByType,
      responses: responses,
    );
  }

  /// Inicializar preguntas predefinidas en Firestore (solo si están vacías)
  Future<void> initializePredefinedQuestions() async {
    final existing = await _questionsCollection.limit(1).get();
    if (existing.docs.isNotEmpty) return;

    final batch = _firestore.batch();
    for (final question in PredefinedMoodQuestions.questions) {
      final docRef = _questionsCollection.doc(question.id);
      batch.set(docRef, question.toFirestore());
    }
    await batch.commit();
  }
}

/// Modelo para el schedule de encuestas de un usuario
class MoodPollSchedule {
  final String oderId;
  final DateTime? lastPollShownAt;
  final int pollsShownThisWeek;
  final String? lastQuestionId;
  final List<String> shownQuestionIds;
  final DateTime? weekStartDate;

  MoodPollSchedule({
    required this.oderId,
    this.lastPollShownAt,
    this.pollsShownThisWeek = 0,
    this.lastQuestionId,
    this.shownQuestionIds = const [],
    this.weekStartDate,
  });

  // Alias for consistency
  String get userId => oderId;

  Map<String, dynamic> toFirestore() {
    return {
      'lastPollShownAt': lastPollShownAt != null
          ? Timestamp.fromDate(lastPollShownAt!)
          : null,
      'pollsShownThisWeek': pollsShownThisWeek,
      'lastQuestionId': lastQuestionId,
      'shownQuestionIds': shownQuestionIds,
      'weekStartDate': weekStartDate != null
          ? Timestamp.fromDate(weekStartDate!)
          : null,
    };
  }

  factory MoodPollSchedule.fromFirestore(String oderId, Map<String, dynamic> data) {
    return MoodPollSchedule(
      oderId: oderId,
      lastPollShownAt: (data['lastPollShownAt'] as Timestamp?)?.toDate(),
      pollsShownThisWeek: data['pollsShownThisWeek'] as int? ?? 0,
      lastQuestionId: data['lastQuestionId'] as String?,
      shownQuestionIds: List<String>.from(data['shownQuestionIds'] ?? []),
      weekStartDate: (data['weekStartDate'] as Timestamp?)?.toDate(),
    );
  }

  /// Verificar si se puede mostrar otra encuesta esta semana
  bool canShowPollThisWeek({int maxPollsPerWeek = 3}) {
    return pollsShownThisWeek < maxPollsPerWeek;
  }

  /// Verificar si pasó suficiente tiempo desde la última encuesta
  bool hasEnoughTimePassed({Duration minInterval = const Duration(hours: 24)}) {
    if (lastPollShownAt == null) return true;
    return DateTime.now().difference(lastPollShownAt!) >= minInterval;
  }

  /// Verificar si se puede mostrar una encuesta ahora
  bool canShowPollNow({
    int maxPollsPerWeek = 3,
    Duration minInterval = const Duration(hours: 24),
  }) {
    return canShowPollThisWeek(maxPollsPerWeek: maxPollsPerWeek) &&
        hasEnoughTimePassed(minInterval: minInterval);
  }
}
