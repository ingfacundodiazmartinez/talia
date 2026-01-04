import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/trivia.dart';
import '../../models/trivia_question.dart';
import '../../models/trivia_response.dart';
import '../../utils/release_logger.dart';

/// Repositorio para operaciones CRUD de trivias
///
/// Maneja todas las operaciones de lectura y escritura
/// con Firestore para trivias, preguntas y respuestas.
class TriviaRepository {
  static TriviaRepository? _instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  TriviaRepository._internal({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  factory TriviaRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) {
    _instance ??= TriviaRepository._internal(
      firestore: firestore,
      auth: auth,
    );
    return _instance!;
  }

  /// Resetear instancia (para testing)
  static void resetInstance() {
    _instance = null;
  }

  // ==================== Collections ====================

  CollectionReference<Map<String, dynamic>> get _triviasCollection =>
      _firestore.collection('trivias');

  CollectionReference<Map<String, dynamic>> _questionsCollection(
          String triviaId) =>
      _triviasCollection.doc(triviaId).collection('questions');

  CollectionReference<Map<String, dynamic>> get _responsesCollection =>
      _firestore.collection('trivia_responses');

  // ==================== Current User ====================

  String get currentUserId => _auth.currentUser?.uid ?? '';

  // ==================== Trivia CRUD ====================

  /// Crear una nueva trivia con sus preguntas
  ///
  /// Nota: Se crean en dos pasos porque las reglas de Firestore
  /// para questions necesitan leer el documento trivia padre,
  /// que no existe si todo va en el mismo batch.
  Future<String> createTrivia({
    required Trivia trivia,
    required List<TriviaQuestion> questions,
  }) async {
    // Crear documento de trivia
    final triviaRef = _triviasCollection.doc();

    // Primero generar los IDs de las preguntas
    final questionRefs = <DocumentReference<Map<String, dynamic>>>[];
    final questionIds = <String>[];
    for (int i = 0; i < questions.length; i++) {
      final questionRef = _questionsCollection(triviaRef.id).doc();
      questionRefs.add(questionRef);
      questionIds.add(questionRef.id);
    }

    // PASO 1: Crear la trivia primero (para que exista cuando se validen las preguntas)
    final triviaWithId = trivia.copyWith(
      id: triviaRef.id,
      questionIds: questionIds,
    );
    await triviaRef.set(triviaWithId.toFirestore());

    // PASO 2: Crear preguntas en batch (ahora la trivia ya existe)
    final batch = _firestore.batch();
    for (int i = 0; i < questions.length; i++) {
      final questionWithId = questions[i].copyWith(
        id: questionRefs[i].id,
        triviaId: triviaRef.id,
        order: i + 1,
      );
      batch.set(questionRefs[i], questionWithId.toFirestore());
    }
    await batch.commit();

    ReleaseLogger.log(
        '📝 [TriviaRepo] Trivia creada: ${triviaRef.id} con ${questions.length} preguntas');

    return triviaRef.id;
  }

  /// Obtener una trivia por ID
  Future<Trivia?> getTrivia(String triviaId) async {
    final doc = await _triviasCollection.doc(triviaId).get();
    if (!doc.exists) return null;
    return Trivia.fromFirestore(doc);
  }

  /// Stream de una trivia
  Stream<Trivia?> watchTrivia(String triviaId) {
    return _triviasCollection.doc(triviaId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return Trivia.fromFirestore(doc);
    });
  }

  /// Actualizar trivia
  Future<void> updateTrivia(
      String triviaId, Map<String, dynamic> updates) async {
    await _triviasCollection.doc(triviaId).update(updates);
    ReleaseLogger.log('📝 [TriviaRepo] Trivia actualizada: $triviaId');
  }

  /// Eliminar trivia y todas sus dependencias
  Future<void> deleteTrivia(String triviaId) async {
    final batch = _firestore.batch();

    // Eliminar preguntas
    final questions = await _questionsCollection(triviaId).get();
    for (final doc in questions.docs) {
      batch.delete(doc.reference);
    }

    // Eliminar respuestas
    final responses = await _responsesCollection
        .where('triviaId', isEqualTo: triviaId)
        .get();
    for (final doc in responses.docs) {
      batch.delete(doc.reference);
    }

    // Eliminar trivia
    batch.delete(_triviasCollection.doc(triviaId));

    await batch.commit();
    ReleaseLogger.log('🗑️ [TriviaRepo] Trivia eliminada: $triviaId');
  }

  /// Cerrar trivia (cambiar status)
  Future<void> closeTrivia(String triviaId) async {
    await _triviasCollection.doc(triviaId).update({
      'status': TriviaStatus.closed.name,
      'closedAt': FieldValue.serverTimestamp(),
    });
    ReleaseLogger.log('🔒 [TriviaRepo] Trivia cerrada: $triviaId');
  }

  /// Marcar trivia como con respuestas (inmutable)
  Future<void> markTriviaAsHasResponses(String triviaId) async {
    await _triviasCollection.doc(triviaId).update({
      'hasResponses': true,
    });
  }

  /// Incrementar contador de participantes
  Future<void> incrementParticipantCount(String triviaId) async {
    await _triviasCollection.doc(triviaId).update({
      'participantCount': FieldValue.increment(1),
    });
  }

  /// Guardar ID de historia de resultados
  Future<void> saveResultsStoryId(String triviaId, String storyId) async {
    await _triviasCollection.doc(triviaId).update({
      'resultsStoryId': storyId,
    });
  }

  // ==================== Trivia Queries ====================

  /// Stream de trivias activas disponibles para el usuario actual
  Stream<List<Trivia>> watchActiveTrivias() {
    final userId = currentUserId;
    if (userId.isEmpty) return Stream.value([]);

    return _triviasCollection
        .where('availableFor', arrayContains: userId)
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map(Trivia.fromFirestore)
            .where((t) => !t.isExpired && !t.blockedUsers.contains(userId))
            .toList());
  }

  /// Stream de trivias creadas por el usuario actual
  Stream<List<Trivia>> watchMyTrivias() {
    final userId = currentUserId;
    if (userId.isEmpty) return Stream.value([]);

    return _triviasCollection
        .where('creatorId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(Trivia.fromFirestore).toList());
  }

  // ==================== Questions ====================

  /// Obtener todas las preguntas de una trivia
  Future<List<TriviaQuestion>> getQuestions(String triviaId) async {
    final snapshot = await _questionsCollection(triviaId)
        .orderBy('order', descending: false)
        .get();
    return snapshot.docs
        .map((doc) => TriviaQuestion.fromFirestore(doc, triviaId))
        .toList();
  }

  /// Stream de preguntas de una trivia
  Stream<List<TriviaQuestion>> watchQuestions(String triviaId) {
    return _questionsCollection(triviaId)
        .orderBy('order', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => TriviaQuestion.fromFirestore(doc, triviaId))
            .toList());
  }

  /// Actualizar una pregunta
  Future<void> updateQuestion(
    String triviaId,
    String questionId,
    Map<String, dynamic> updates,
  ) async {
    await _questionsCollection(triviaId).doc(questionId).update(updates);
  }

  // ==================== Responses ====================

  /// Crear una respuesta inicial
  Future<void> createResponse(TriviaResponse response) async {
    await _responsesCollection.doc(response.id).set(response.toFirestore());
    ReleaseLogger.log(
        '📝 [TriviaRepo] Respuesta creada: ${response.id}');
  }

  /// Obtener respuesta de un usuario a una trivia
  Future<TriviaResponse?> getResponse(String oderId, String triviaId) async {
    final id = TriviaResponse.generateId(oderId, triviaId);
    final doc = await _responsesCollection.doc(id).get();
    if (!doc.exists) return null;
    return TriviaResponse.fromFirestore(doc);
  }

  /// Verificar si usuario ya respondió
  Future<bool> hasUserResponded(String oderId, String triviaId) async {
    final id = TriviaResponse.generateId(oderId, triviaId);
    final doc = await _responsesCollection.doc(id).get();
    return doc.exists;
  }

  /// Actualizar respuesta
  Future<void> updateResponse(
      String responseId, Map<String, dynamic> updates) async {
    await _responsesCollection.doc(responseId).update(updates);
  }

  /// Agregar respuesta a una pregunta
  Future<void> addAnswer(String responseId, QuestionAnswer answer) async {
    await _responsesCollection.doc(responseId).update({
      'answers': FieldValue.arrayUnion([answer.toMap()]),
      'totalScore': FieldValue.increment(answer.pointsEarned),
      'correctCount': FieldValue.increment(answer.isCorrect ? 1 : 0),
    });
  }

  /// Marcar respuesta como completada
  Future<void> completeResponse(String responseId, int timeSpentSeconds) async {
    await _responsesCollection.doc(responseId).update({
      'status': ResponseStatus.completed.name,
      'completedAt': FieldValue.serverTimestamp(),
      'timeSpentSeconds': timeSpentSeconds,
    });
  }

  /// Marcar respuesta como parcial (interrumpida)
  Future<void> markResponseAsPartial(
      String responseId, int timeSpentSeconds) async {
    await _responsesCollection.doc(responseId).update({
      'status': ResponseStatus.partial.name,
      'completedAt': FieldValue.serverTimestamp(),
      'timeSpentSeconds': timeSpentSeconds,
    });
  }

  /// Stream de respuesta del usuario actual
  Stream<TriviaResponse?> watchMyResponse(String triviaId) {
    final userId = currentUserId;
    if (userId.isEmpty) return Stream.value(null);

    final id = TriviaResponse.generateId(userId, triviaId);
    return _responsesCollection.doc(id).snapshots().map((doc) {
      if (!doc.exists) return null;
      return TriviaResponse.fromFirestore(doc);
    });
  }

  /// Stream del leaderboard de una trivia
  Stream<List<TriviaResponse>> watchLeaderboard(String triviaId) {
    return _responsesCollection
        .where('triviaId', isEqualTo: triviaId)
        .where('status', whereIn: ['completed', 'partial'])
        .orderBy('totalScore', descending: true)
        .orderBy('completedAt', descending: false)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map(TriviaResponse.fromFirestore).toList());
  }

  /// Obtener top N respuestas
  Future<List<TriviaResponse>> getTopResponses(String triviaId,
      {int limit = 3}) async {
    final snapshot = await _responsesCollection
        .where('triviaId', isEqualTo: triviaId)
        .where('status', whereIn: ['completed', 'partial'])
        .orderBy('totalScore', descending: true)
        .orderBy('completedAt', descending: false)
        .limit(limit)
        .get();
    return snapshot.docs.map(TriviaResponse.fromFirestore).toList();
  }

  /// Contar participantes de una trivia
  Future<int> countParticipants(String triviaId) async {
    final snapshot = await _responsesCollection
        .where('triviaId', isEqualTo: triviaId)
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  // ==================== Bulk Operations ====================

  /// Eliminar todas las respuestas de un usuario (para eliminación de cuenta)
  Future<void> deleteAllResponsesByUser(String userId) async {
    final batch = _firestore.batch();
    final responses = await _responsesCollection
        .where('oderId', isEqualTo: userId)
        .get();

    for (final doc in responses.docs) {
      batch.delete(doc.reference);
    }

    await batch.commit();
  }

  /// Eliminar todas las trivias de un usuario (para eliminación de cuenta)
  Future<void> deleteAllTriviasByUser(String userId) async {
    final trivias = await _triviasCollection
        .where('creatorId', isEqualTo: userId)
        .get();

    for (final doc in trivias.docs) {
      await deleteTrivia(doc.id);
    }
  }
}
