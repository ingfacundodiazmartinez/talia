import 'package:firebase_auth/firebase_auth.dart';

import '../../models/trivia.dart';
import '../../models/trivia_question.dart';
import '../../models/trivia_response.dart';
import '../../utils/release_logger.dart';
import 'trivia_repository.dart';
import 'trivia_scoring_service.dart';

/// Resultado de responder una pregunta
class QuestionResult {
  final bool isCorrect;
  final String correctOptionId;
  final int pointsEarned;
  final int totalScore;
  final int questionNumber;
  final int totalQuestions;

  QuestionResult({
    required this.isCorrect,
    required this.correctOptionId,
    required this.pointsEarned,
    required this.totalScore,
    required this.questionNumber,
    required this.totalQuestions,
  });

  /// Porcentaje de progreso (0.0 - 1.0)
  double get progress => totalQuestions > 0 ? questionNumber / totalQuestions : 0;
}

/// Servicio atómico para participación en trivias
class TriviaParticipationService {
  static TriviaParticipationService? _instance;

  final TriviaRepository _repository;
  final TriviaScoringService _scoringService;
  final FirebaseAuth _auth;

  TriviaParticipationService._internal({
    TriviaRepository? repository,
    TriviaScoringService? scoringService,
    FirebaseAuth? auth,
  })  : _repository = repository ?? TriviaRepository(),
        _scoringService = scoringService ?? TriviaScoringService(),
        _auth = auth ?? FirebaseAuth.instance;

  factory TriviaParticipationService({
    TriviaRepository? repository,
    TriviaScoringService? scoringService,
    FirebaseAuth? auth,
  }) {
    _instance ??= TriviaParticipationService._internal(
      repository: repository,
      scoringService: scoringService,
      auth: auth,
    );
    return _instance!;
  }

  // ==================== Eligibility ====================

  /// Verificar si el usuario puede participar en una trivia
  Future<TriviaEligibility> checkEligibility(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) {
      return TriviaEligibility.notAuthenticated;
    }

    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      return TriviaEligibility.notFound;
    }

    // Verificar si es el creador
    if (trivia.creatorId == user.uid) {
      return TriviaEligibility.isCreator;
    }

    // Verificar si la trivia está activa
    if (!trivia.isActive) {
      return TriviaEligibility.closed;
    }

    // Verificar si está bloqueado
    if (trivia.blockedUsers.contains(user.uid)) {
      return TriviaEligibility.blocked;
    }

    // Verificar si ya tiene una respuesta
    final existingResponse = await _repository.getResponse(user.uid, triviaId);
    if (existingResponse != null) {
      // Si está en progreso, puede continuar
      if (existingResponse.status == ResponseStatus.inProgress) {
        return TriviaEligibility.canContinue;
      }
      // Si ya completó o es parcial, no puede volver a responder
      return TriviaEligibility.alreadyCompleted;
    }

    return TriviaEligibility.canParticipate;
  }

  // ==================== Start Trivia ====================

  /// Iniciar o continuar participación en una trivia
  ///
  /// Si es nueva participación, crea el documento de respuesta con estado inProgress
  /// Si ya tiene respuesta en progreso, la retoma
  /// Retorna la respuesta y las preguntas
  Future<TriviaStartResult> startTrivia(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaParticipationException('Usuario no autenticado');
    }

    // Verificar elegibilidad
    final eligibility = await checkEligibility(triviaId);
    if (eligibility != TriviaEligibility.canParticipate &&
        eligibility != TriviaEligibility.canContinue) {
      throw TriviaParticipationException(_getEligibilityMessage(eligibility));
    }

    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      throw TriviaParticipationException('Trivia no encontrada');
    }

    // Obtener preguntas
    final questions = await _repository.getQuestions(triviaId);
    if (questions.isEmpty) {
      throw TriviaParticipationException('La trivia no tiene preguntas');
    }

    TriviaResponse response;

    if (eligibility == TriviaEligibility.canContinue) {
      // Retomar respuesta existente
      final existingResponse = await _repository.getResponse(user.uid, triviaId);
      if (existingResponse == null) {
        throw TriviaParticipationException('Error al retomar la trivia');
      }
      response = existingResponse;
      ReleaseLogger.log(
          '🎮 [TriviaParticipation] Retomando trivia $triviaId (${response.answeredCount}/${response.totalQuestions} respondidas)');
    } else {
      // Crear nueva respuesta
      final responseId = TriviaResponse.generateId(user.uid, triviaId);
      response = TriviaResponse(
        id: responseId,
        oderId: user.uid,
        oderName: user.displayName ?? 'Usuario',
        oderPhotoURL: user.photoURL,
        triviaId: triviaId,
        status: ResponseStatus.inProgress,
        startedAt: DateTime.now(),
        totalQuestions: questions.length,
      );

      await _repository.createResponse(response);
      ReleaseLogger.log(
          '🎮 [TriviaParticipation] Iniciada nueva participación en trivia $triviaId');
    }

    return TriviaStartResult(
      response: response,
      questions: questions,
      trivia: trivia,
    );
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

  // ==================== Submit Answer ====================

  /// Enviar respuesta a una pregunta individual
  ///
  /// [triviaId] - ID de la trivia
  /// [questionId] - ID de la pregunta
  /// [selectedOptionId] - ID de la opción seleccionada (vacío si timeout)
  /// [responseTimeMs] - Tiempo en responder (milisegundos)
  Future<QuestionResult> submitAnswer({
    required String triviaId,
    required String questionId,
    required String selectedOptionId,
    required int responseTimeMs,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaParticipationException('Usuario no autenticado');
    }

    final responseId = TriviaResponse.generateId(user.uid, triviaId);

    // Obtener respuesta actual para verificar si es la primera respuesta
    final currentResponse = await _repository.getResponse(user.uid, triviaId);
    final isFirstAnswer = currentResponse?.answeredCount == 0;

    // Obtener la pregunta para verificar respuesta
    final question = await TriviaQuestion.getById(triviaId, questionId);
    if (question == null) {
      throw TriviaParticipationException('Pregunta no encontrada');
    }

    // Verificar si la respuesta es correcta
    final isCorrect = selectedOptionId.isNotEmpty &&
        question.isCorrectOption(selectedOptionId);

    // Calcular puntos
    final points = _scoringService.calculatePoints(
      isCorrect: isCorrect,
      responseTimeMs: responseTimeMs,
    );

    // Crear objeto de respuesta
    final answer = QuestionAnswer(
      questionId: questionId,
      selectedOptionId: selectedOptionId.isEmpty ? null : selectedOptionId,
      isCorrect: isCorrect,
      pointsEarned: points,
      responseTimeMs: responseTimeMs,
      answeredAt: DateTime.now(),
    );

    // Guardar en Firestore
    await _repository.addAnswer(responseId, answer);

    // Si es la primera respuesta, marcar como participante
    if (isFirstAnswer) {
      final trivia = await _repository.getTrivia(triviaId);
      if (trivia != null) {
        // Marcar trivia como que tiene respuestas (primera vez)
        if (!trivia.hasResponses) {
          await _repository.markTriviaAsHasResponses(triviaId);
        }
        // Incrementar contador de participantes
        await _repository.incrementParticipantCount(triviaId);
        ReleaseLogger.log(
            '👤 [TriviaParticipation] Nuevo participante contabilizado en trivia $triviaId');
      }
    }

    // Obtener respuesta actualizada para el total
    final updatedResponse = await _repository.getResponse(user.uid, triviaId);
    final totalScore = updatedResponse?.totalScore ?? points;

    ReleaseLogger.log(
        '📝 [TriviaParticipation] Respuesta enviada: $questionId - ${isCorrect ? "✅" : "❌"} (+$points pts)');

    return QuestionResult(
      isCorrect: isCorrect,
      correctOptionId: question.correctOptionId,
      pointsEarned: points,
      totalScore: totalScore,
      questionNumber: updatedResponse?.answeredCount ?? 1,
      totalQuestions: updatedResponse?.totalQuestions ?? 1,
    );
  }

  // ==================== Complete ====================

  /// Marcar trivia como completada
  Future<TriviaResponse> completeTrivia(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaParticipationException('Usuario no autenticado');
    }

    final responseId = TriviaResponse.generateId(user.uid, triviaId);
    final response = await _repository.getResponse(user.uid, triviaId);

    if (response == null) {
      throw TriviaParticipationException('No se encontró tu participación');
    }

    // Calcular tiempo total
    final timeSpentSeconds =
        DateTime.now().difference(response.startedAt).inSeconds;

    await _repository.completeResponse(responseId, timeSpentSeconds);

    // Nota: El contador de participantes ya se incrementó en submitAnswer (primera respuesta)

    ReleaseLogger.log(
        '✅ [TriviaParticipation] Trivia completada: $triviaId - ${response.totalScore} pts');

    // Retornar respuesta actualizada
    return (await _repository.getResponse(user.uid, triviaId))!;
  }

  // ==================== Abandon ====================

  /// Guardar progreso parcial (cuando la app se cierra o interrumpe)
  Future<void> savePartialProgress(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final responseId = TriviaResponse.generateId(user.uid, triviaId);
    final response = await _repository.getResponse(user.uid, triviaId);

    if (response == null || response.status != ResponseStatus.inProgress) {
      return;
    }

    // Calcular tiempo total
    final timeSpentSeconds =
        DateTime.now().difference(response.startedAt).inSeconds;

    await _repository.markResponseAsPartial(responseId, timeSpentSeconds);

    // Nota: El contador de participantes ya se incrementó en submitAnswer (primera respuesta)

    ReleaseLogger.log(
        '⚠️ [TriviaParticipation] Progreso parcial guardado: $triviaId');
  }

  // ==================== Queries ====================

  /// Obtener respuesta actual del usuario
  Future<TriviaResponse?> getMyResponse(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return _repository.getResponse(user.uid, triviaId);
  }

  /// Stream de mi respuesta
  Stream<TriviaResponse?> watchMyResponse(String triviaId) {
    return _repository.watchMyResponse(triviaId);
  }
}

/// Resultado de iniciar una trivia
class TriviaStartResult {
  final TriviaResponse response;
  final List<TriviaQuestion> questions;
  final Trivia trivia;

  TriviaStartResult({
    required this.response,
    required this.questions,
    required this.trivia,
  });
}

/// Elegibilidad para participar en una trivia
enum TriviaEligibility {
  canParticipate,    // Puede iniciar nueva participación
  canContinue,       // Tiene respuesta en progreso, puede continuar
  notAuthenticated,
  notFound,
  isCreator,
  closed,
  blocked,
  alreadyCompleted,  // Ya completó o envió respuesta parcial
}

/// Excepción para errores de participación
class TriviaParticipationException implements Exception {
  final String message;

  TriviaParticipationException(this.message);

  @override
  String toString() => 'TriviaParticipationException: $message';
}
