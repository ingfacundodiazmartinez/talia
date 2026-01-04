import 'dart:async';

import '../../models/trivia.dart';
import '../../models/trivia_question.dart';
import '../../models/trivia_response.dart';
import '../../utils/release_logger.dart';
import 'trivia_creation_service.dart';
import 'trivia_participation_service.dart';
import 'trivia_repository.dart';
import 'trivia_results_service.dart';
import 'trivia_scoring_service.dart';
import 'trivia_suggestion_service.dart';

/// Orquestador principal para todas las operaciones de trivia
///
/// Es el punto de entrada único para:
/// - Creación y gestión de trivias
/// - Participación y respuestas
/// - Resultados y rankings
/// - Sugerencias de preguntas
class TriviaOrchestrator {
  static TriviaOrchestrator? _instance;

  late final TriviaRepository _repository;
  late final TriviaCreationService _creationService;
  late final TriviaParticipationService _participationService;
  late final TriviaResultsService _resultsService;
  late final TriviaScoringService _scoringService;
  late final TriviaSuggestionService _suggestionService;

  TriviaOrchestrator._internal() {
    _repository = TriviaRepository();
    _creationService = TriviaCreationService(repository: _repository);
    _participationService = TriviaParticipationService(repository: _repository);
    _resultsService = TriviaResultsService(repository: _repository);
    _scoringService = TriviaScoringService();
    _suggestionService = TriviaSuggestionService();

    ReleaseLogger.log('🎯 [TriviaOrchestrator] Inicializado');
  }

  factory TriviaOrchestrator() {
    _instance ??= TriviaOrchestrator._internal();
    return _instance!;
  }

  /// Resetear instancia (para testing)
  static void resetInstance() {
    _instance = null;
    TriviaRepository.resetInstance();
  }

  // ==================== CREATION ====================

  /// Crear una nueva trivia con preguntas
  Future<String> createTrivia({
    required String title,
    required List<TriviaQuestionDraft> questions,
    String? backgroundImagePath,
  }) {
    return _creationService.createTrivia(
      title: title,
      questions: questions,
      backgroundImagePath: backgroundImagePath,
    );
  }

  /// Editar una trivia existente (solo si no tiene respuestas)
  Future<void> editTrivia({
    required String triviaId,
    String? title,
    String? backgroundImagePath,
  }) {
    return _creationService.editTrivia(
      triviaId: triviaId,
      title: title,
      backgroundImagePath: backgroundImagePath,
    );
  }

  /// Eliminar una trivia
  Future<void> deleteTrivia(String triviaId) {
    return _creationService.deleteTrivia(triviaId);
  }

  /// Cerrar una trivia manualmente
  Future<void> closeTrivia(String triviaId) {
    return _creationService.closeTrivia(triviaId);
  }

  // ==================== PARTICIPATION ====================

  /// Verificar si el usuario puede participar
  Future<TriviaEligibility> checkEligibility(String triviaId) {
    return _participationService.checkEligibility(triviaId);
  }

  /// Iniciar participación en una trivia
  Future<TriviaStartResult> startTrivia(String triviaId) {
    return _participationService.startTrivia(triviaId);
  }

  /// Enviar respuesta a una pregunta
  Future<QuestionResult> submitAnswer({
    required String triviaId,
    required String questionId,
    required String selectedOptionId,
    required int responseTimeMs,
  }) {
    return _participationService.submitAnswer(
      triviaId: triviaId,
      questionId: questionId,
      selectedOptionId: selectedOptionId,
      responseTimeMs: responseTimeMs,
    );
  }

  /// Completar una trivia
  Future<TriviaResponse> completeTrivia(String triviaId) {
    return _participationService.completeTrivia(triviaId);
  }

  /// Guardar progreso parcial (cuando la app se interrumpe)
  Future<void> savePartialProgress(String triviaId) {
    return _participationService.savePartialProgress(triviaId);
  }

  /// Obtener mi respuesta actual
  Future<TriviaResponse?> getMyResponse(String triviaId) {
    return _participationService.getMyResponse(triviaId);
  }

  /// Stream de mi respuesta
  Stream<TriviaResponse?> watchMyResponse(String triviaId) {
    return _participationService.watchMyResponse(triviaId);
  }

  // ==================== RESULTS ====================

  /// Stream del leaderboard
  Stream<List<TriviaLeaderboardEntry>> watchLeaderboard(String triviaId) {
    return _resultsService.watchLeaderboard(triviaId);
  }

  /// Obtener leaderboard actual
  Future<List<TriviaLeaderboardEntry>> getLeaderboard(String triviaId) {
    return _resultsService.getLeaderboard(triviaId);
  }

  /// Obtener resultados completos
  Future<TriviaResults> getResults(String triviaId) {
    return _resultsService.getResults(triviaId);
  }

  /// Compartir resultados como historia
  Future<String> shareResultsAsStory(String triviaId) {
    return _resultsService.shareResultsAsStory(triviaId);
  }

  /// Obtener mi posición en el leaderboard
  Future<TriviaLeaderboardEntry?> getMyPosition(String triviaId) {
    return _resultsService.getMyPosition(triviaId);
  }

  /// Stream de mi posición
  Stream<TriviaLeaderboardEntry?> watchMyPosition(String triviaId) {
    return _resultsService.watchMyPosition(triviaId);
  }

  /// Obtener IDs de los ganadores (top 3)
  Future<List<String>> getTopWinnerIds(String triviaId, {int limit = 3}) {
    return _resultsService.getTopWinnerIds(triviaId, limit: limit);
  }

  // ==================== SUGGESTIONS ====================

  /// Obtener categorías de preguntas
  List<TriviaCategory> getCategories() {
    return _suggestionService.getCategories();
  }

  /// Generar una pregunta sugerida
  Future<TriviaSuggestion> getSuggestedQuestion({String? categoryId}) {
    return _suggestionService.getSuggestedQuestion(categoryId: categoryId);
  }

  /// Obtener múltiples sugerencias
  Future<List<TriviaSuggestion>> getMultipleSuggestions({
    String? categoryId,
    int count = 5,
  }) {
    return _suggestionService.getMultipleSuggestions(
      categoryId: categoryId,
      count: count,
    );
  }

  // ==================== QUERIES ====================

  /// Obtener una trivia por ID
  Future<Trivia?> getTrivia(String triviaId) {
    return _repository.getTrivia(triviaId);
  }

  /// Stream de una trivia específica
  Stream<Trivia?> watchTrivia(String triviaId) {
    return _repository.watchTrivia(triviaId);
  }

  /// Stream de trivias activas disponibles para el usuario
  Stream<List<Trivia>> watchAvailableTrivias() {
    return _repository.watchActiveTrivias();
  }

  /// Stream de trivias creadas por el usuario
  Stream<List<Trivia>> watchMyTrivias() {
    return _repository.watchMyTrivias();
  }

  /// Obtener preguntas de una trivia
  Future<List<TriviaQuestion>> getQuestions(String triviaId) {
    return _repository.getQuestions(triviaId);
  }

  /// Stream de preguntas de una trivia
  Stream<List<TriviaQuestion>> watchQuestions(String triviaId) {
    return _repository.watchQuestions(triviaId);
  }

  // ==================== SCORING ====================

  /// Calcular puntos por una respuesta
  int calculatePoints({
    required bool isCorrect,
    required int responseTimeMs,
    int maxTimeMs = 30000,
  }) {
    return _scoringService.calculatePoints(
      isCorrect: isCorrect,
      responseTimeMs: responseTimeMs,
      maxTimeMs: maxTimeMs,
    );
  }

  /// Obtener descripción del puntaje
  String getScoreDescription(int points) {
    return _scoringService.getScoreDescription(points);
  }

  /// Obtener emoji del puntaje
  String getScoreEmoji(int points) {
    return _scoringService.getScoreEmoji(points);
  }

  // ==================== DEEPLINK ====================

  /// Generar URL para compartir trivia
  String generateTriviaUrl(String triviaId) {
    return 'https://taliachat.com/t/$triviaId';
  }

  /// Generar deeplink scheme para compartir trivia
  String generateTriviaDeeplink(String triviaId) {
    return 'talia://trivia/$triviaId';
  }
}
