import 'dart:async';

import '../models/trivia.dart';
import '../models/trivia_question.dart';
import '../models/trivia_response.dart';
import '../services/trivia/trivia_orchestrator.dart';
import '../services/trivia/trivia_participation_service.dart';
import '../utils/release_logger.dart';

/// Estado del juego de trivia
enum TriviaPlayState {
  loading,
  ready,
  playing,
  answering,
  showingResult,
  completed,
  error,
}

/// Controller para jugar una trivia
///
/// Responsabilidades:
/// - Cargar trivia y preguntas
/// - Manejar timer por pregunta
/// - Enviar respuestas y calcular puntos
/// - Mostrar feedback verde/rojo
/// - Manejar progreso y finalización
class TriviaPlayController {
  static const int defaultQuestionTimeMs = 30000; // 30 segundos por pregunta

  // Servicios
  final TriviaOrchestrator _orchestrator;

  // Estado del juego
  TriviaPlayState _state = TriviaPlayState.loading;
  Trivia? _trivia;
  List<TriviaQuestion> _questions = [];
  TriviaResponse? _response;
  int _currentQuestionIndex = 0;
  DateTime? _questionStartTime;
  Timer? _questionTimer;
  int _remainingTimeMs = defaultQuestionTimeMs;

  // Resultado de la última respuesta
  QuestionResult? _lastResult;
  String? _selectedOptionId;

  // Error
  String? _errorMessage;
  TriviaEligibility? _ineligibilityReason;

  // Callbacks
  Function(TriviaPlayState)? onStateChanged;
  Function(int)? onQuestionChanged;
  Function(int)? onTimerTick;
  Function(QuestionResult)? onAnswerResult;
  Function(TriviaResponse)? onTriviaCompleted;
  Function(String)? onError;

  TriviaPlayController({
    TriviaOrchestrator? orchestrator,
  }) : _orchestrator = orchestrator ?? TriviaOrchestrator();

  // Getters
  TriviaPlayState get state => _state;
  Trivia? get trivia => _trivia;
  List<TriviaQuestion> get questions => _questions;
  TriviaResponse? get response => _response;
  int get currentQuestionIndex => _currentQuestionIndex;
  int get remainingTimeMs => _remainingTimeMs;
  String? get errorMessage => _errorMessage;
  TriviaEligibility? get ineligibilityReason => _ineligibilityReason;
  QuestionResult? get lastResult => _lastResult;
  String? get selectedOptionId => _selectedOptionId;

  TriviaQuestion? get currentQuestion {
    if (_currentQuestionIndex < 0 || _currentQuestionIndex >= _questions.length) {
      return null;
    }
    return _questions[_currentQuestionIndex];
  }

  bool get isLastQuestion => _currentQuestionIndex == _questions.length - 1;
  int get totalQuestions => _questions.length;
  int get answeredQuestions => _response?.answeredCount ?? 0;
  int get totalScore => _response?.totalScore ?? 0;

  double get progress {
    if (_questions.isEmpty) return 0;
    return (_currentQuestionIndex + 1) / _questions.length;
  }

  // ==================== INITIALIZATION ====================

  /// Iniciar la trivia
  Future<void> startTrivia(String triviaId) async {
    try {
      _setState(TriviaPlayState.loading);
      _clearError();

      ReleaseLogger.log('🎮 [TriviaPlay] Iniciando trivia: $triviaId');

      // Verificar elegibilidad
      final eligibility = await _orchestrator.checkEligibility(triviaId);
      if (eligibility != TriviaEligibility.canParticipate &&
          eligibility != TriviaEligibility.canContinue) {
        _ineligibilityReason = eligibility;
        _setError(_getEligibilityMessage(eligibility));
        _setState(TriviaPlayState.error);
        return;
      }

      // Iniciar participación (o continuar si ya existe)
      final result = await _orchestrator.startTrivia(triviaId);
      _trivia = result.trivia;
      _questions = result.questions;
      _response = result.response;

      // Si es continuación, empezar desde la siguiente pregunta no respondida
      if (eligibility == TriviaEligibility.canContinue && _response != null) {
        _currentQuestionIndex = _response!.answeredCount;
        ReleaseLogger.log(
            '🎮 [TriviaPlay] Retomando desde pregunta ${_currentQuestionIndex + 1}/${_questions.length}');
      } else {
        _currentQuestionIndex = 0;
      }

      ReleaseLogger.log('🎮 [TriviaPlay] Trivia cargada: ${_questions.length} preguntas');

      _setState(TriviaPlayState.ready);
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaPlay] Error iniciando trivia: $e');
      _setError('Error al cargar la trivia');
      _setState(TriviaPlayState.error);
    }
  }

  /// Comenzar a jugar (muestra la primera pregunta)
  void beginPlaying() {
    if (_state != TriviaPlayState.ready) return;

    _setState(TriviaPlayState.playing);
    _startQuestionTimer();
    onQuestionChanged?.call(_currentQuestionIndex);
  }

  // ==================== ANSWER HANDLING ====================

  /// Seleccionar una opción (antes de confirmar)
  void selectOption(String optionId) {
    if (_state != TriviaPlayState.playing) return;
    _selectedOptionId = optionId;
  }

  /// Enviar respuesta
  Future<void> submitAnswer(String optionId) async {
    if (_state != TriviaPlayState.playing || _trivia == null) return;

    final question = currentQuestion;
    if (question == null) return;

    try {
      _setState(TriviaPlayState.answering);
      _stopQuestionTimer();

      final responseTimeMs = _getResponseTimeMs();
      _selectedOptionId = optionId;

      ReleaseLogger.log('📝 [TriviaPlay] Enviando respuesta: $optionId (${responseTimeMs}ms)');

      final result = await _orchestrator.submitAnswer(
        triviaId: _trivia!.id,
        questionId: question.id,
        selectedOptionId: optionId,
        responseTimeMs: responseTimeMs,
      );

      _lastResult = result;
      _setState(TriviaPlayState.showingResult);
      onAnswerResult?.call(result);

      ReleaseLogger.log(
        '📝 [TriviaPlay] Resultado: ${result.isCorrect ? "✅" : "❌"} (+${result.pointsEarned} pts)',
      );
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaPlay] Error enviando respuesta: $e');
      _setError('Error al enviar respuesta');
      _setState(TriviaPlayState.playing);
    }
  }

  /// Enviar timeout (no respondió a tiempo)
  Future<void> submitTimeout() async {
    if (_state != TriviaPlayState.playing || _trivia == null) return;

    final question = currentQuestion;
    if (question == null) return;

    try {
      _setState(TriviaPlayState.answering);
      _stopQuestionTimer();

      ReleaseLogger.log('⏰ [TriviaPlay] Timeout en pregunta ${_currentQuestionIndex + 1}');

      final result = await _orchestrator.submitAnswer(
        triviaId: _trivia!.id,
        questionId: question.id,
        selectedOptionId: '', // Vacío indica timeout
        responseTimeMs: defaultQuestionTimeMs,
      );

      _lastResult = result;
      _selectedOptionId = null;
      _setState(TriviaPlayState.showingResult);
      onAnswerResult?.call(result);
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaPlay] Error enviando timeout: $e');
      _nextQuestionOrComplete();
    }
  }

  // ==================== NAVIGATION ====================

  /// Pasar a la siguiente pregunta o completar
  void nextQuestion() {
    if (_state != TriviaPlayState.showingResult) return;

    if (isLastQuestion) {
      _completeTrivia();
    } else {
      _currentQuestionIndex++;
      _lastResult = null;
      _selectedOptionId = null;
      _setState(TriviaPlayState.playing);
      _startQuestionTimer();
      onQuestionChanged?.call(_currentQuestionIndex);
    }
  }

  void _nextQuestionOrComplete() {
    if (isLastQuestion) {
      _completeTrivia();
    } else {
      _currentQuestionIndex++;
      _lastResult = null;
      _selectedOptionId = null;
      _setState(TriviaPlayState.playing);
      _startQuestionTimer();
      onQuestionChanged?.call(_currentQuestionIndex);
    }
  }

  // ==================== COMPLETION ====================

  Future<void> _completeTrivia() async {
    if (_trivia == null) return;

    try {
      ReleaseLogger.log('✅ [TriviaPlay] Completando trivia');

      final completedResponse = await _orchestrator.completeTrivia(_trivia!.id);
      _response = completedResponse;
      _setState(TriviaPlayState.completed);
      onTriviaCompleted?.call(completedResponse);

      ReleaseLogger.log(
        '✅ [TriviaPlay] Trivia completada: ${completedResponse.totalScore} pts',
      );
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaPlay] Error completando trivia: $e');
      _setState(TriviaPlayState.completed);
    }
  }

  /// Guardar progreso parcial (cuando se abandona)
  Future<void> saveAndExit() async {
    if (_trivia == null || _state == TriviaPlayState.completed) return;

    try {
      _stopQuestionTimer();
      ReleaseLogger.log('⚠️ [TriviaPlay] Guardando progreso parcial');
      await _orchestrator.savePartialProgress(_trivia!.id);
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaPlay] Error guardando progreso: $e');
    }
  }

  // ==================== TIMER ====================

  void _startQuestionTimer() {
    _questionStartTime = DateTime.now();
    _remainingTimeMs = defaultQuestionTimeMs;

    _questionTimer?.cancel();
    _questionTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      final elapsed = DateTime.now().difference(_questionStartTime!).inMilliseconds;
      _remainingTimeMs = (defaultQuestionTimeMs - elapsed).clamp(0, defaultQuestionTimeMs);
      onTimerTick?.call(_remainingTimeMs);

      if (_remainingTimeMs <= 0) {
        timer.cancel();
        submitTimeout();
      }
    });
  }

  void _stopQuestionTimer() {
    _questionTimer?.cancel();
    _questionTimer = null;
  }

  int _getResponseTimeMs() {
    if (_questionStartTime == null) return defaultQuestionTimeMs;
    return DateTime.now().difference(_questionStartTime!).inMilliseconds;
  }

  // ==================== UTILITIES ====================

  void _setState(TriviaPlayState newState) {
    _state = newState;
    onStateChanged?.call(newState);
  }

  void _setError(String error) {
    _errorMessage = error;
    onError?.call(error);
  }

  void _clearError() {
    _errorMessage = null;
  }

  String _getEligibilityMessage(TriviaEligibility eligibility) {
    switch (eligibility) {
      case TriviaEligibility.canParticipate:
        return 'Puede participar';
      case TriviaEligibility.canContinue:
        return 'Puede continuar';
      case TriviaEligibility.notAuthenticated:
        return 'Debes iniciar sesión para participar';
      case TriviaEligibility.notFound:
        return 'La trivia no existe';
      case TriviaEligibility.isCreator:
        return 'No puedes responder tu propia trivia';
      case TriviaEligibility.closed:
        return 'Esta trivia ya no está activa';
      case TriviaEligibility.blocked:
        return 'No tienes acceso a esta trivia';
      case TriviaEligibility.alreadyCompleted:
        return 'Ya respondiste esta trivia';
    }
  }

  void dispose() {
    _stopQuestionTimer();
    _trivia = null;
    _questions = [];
    _response = null;
    _lastResult = null;
  }
}
