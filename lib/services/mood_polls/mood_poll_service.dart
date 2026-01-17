import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/mood_poll.dart';
import 'repositories/mood_poll_repository.dart';

/// Servicio para manejar la lógica de negocio de mood polls
///
/// Responsabilidades:
/// - Decidir cuándo mostrar encuestas
/// - Seleccionar preguntas apropiadas
/// - Procesar respuestas
/// - Calcular estadísticas para reportes
class MoodPollService {
  final MoodPollRepository _repository;
  final FirebaseAuth _auth;
  final Random _random = Random();

  // Configuración
  static const int maxPollsPerWeek = 3;
  static const Duration minIntervalBetweenPolls = Duration(hours: 24);
  static const double pollShowProbability = 0.4; // 40% chance when eligible

  MoodPollService({
    MoodPollRepository? repository,
    FirebaseAuth? auth,
  })  : _repository = repository ?? MoodPollRepository(),
        _auth = auth ?? FirebaseAuth.instance;

  String? get currentUserId => _auth.currentUser?.uid;

  // ============ POLL DISPLAY LOGIC ============

  /// Determina si se debe mostrar una encuesta al usuario actual
  ///
  /// Retorna la pregunta a mostrar, o null si no se debe mostrar
  Future<MoodPollQuestion?> shouldShowPoll() async {
    final userId = currentUserId;
    if (userId == null) return null;

    // Obtener schedule del usuario
    final schedule = await _repository.getUserSchedule(userId);

    // Verificar si puede recibir encuesta
    if (schedule != null && !schedule.canShowPollNow(
      maxPollsPerWeek: maxPollsPerWeek,
      minInterval: minIntervalBetweenPolls,
    )) {
      return null;
    }

    // Probabilidad aleatoria para no saturar
    if (_random.nextDouble() > pollShowProbability) {
      return null;
    }

    // Seleccionar pregunta
    return await _selectQuestion(schedule);
  }

  /// Selecciona una pregunta apropiada para el usuario
  Future<MoodPollQuestion?> _selectQuestion(MoodPollSchedule? schedule) async {
    // Obtener preguntas activas
    List<MoodPollQuestion> questions = await _repository.getActiveQuestions();

    // Si no hay preguntas en Firestore, usar predefinidas
    if (questions.isEmpty) {
      questions = PredefinedMoodQuestions.questions;
    }

    if (questions.isEmpty) return null;

    // Filtrar preguntas ya mostradas esta semana
    if (schedule != null && schedule.shownQuestionIds.isNotEmpty) {
      final notShown = questions
          .where((q) => !schedule.shownQuestionIds.contains(q.id))
          .toList();

      // Si hay preguntas no mostradas, preferirlas
      if (notShown.isNotEmpty) {
        questions = notShown;
      }
      // Si todas fueron mostradas, resetear y usar cualquiera
    }

    // Seleccionar aleatoriamente
    return questions[_random.nextInt(questions.length)];
  }

  /// Obtener una pregunta que el usuario no haya respondido esta semana
  /// Retorna null si ya respondió todas las preguntas disponibles
  Future<MoodPollQuestion?> getRandomQuestion() async {
    final userId = currentUserId;
    if (userId == null) return null;

    // Obtener preguntas activas
    List<MoodPollQuestion> questions = await _repository.getActiveQuestions();
    if (questions.isEmpty) {
      questions = PredefinedMoodQuestions.questions;
    }

    if (questions.isEmpty) return null;

    // Obtener el schedule del usuario para saber qué preguntas ya respondió esta semana
    final schedule = await _repository.getUserSchedule(userId);

    // Filtrar preguntas no respondidas esta semana
    if (schedule != null && schedule.shownQuestionIds.isNotEmpty) {
      final notAnswered = questions
          .where((q) => !schedule.shownQuestionIds.contains(q.id))
          .toList();

      // Si hay preguntas no respondidas, usar esas
      if (notAnswered.isNotEmpty) {
        return notAnswered[_random.nextInt(notAnswered.length)];
      }

      // Si ya respondió todas, retornar null (no mostrar encuesta)
      return null;
    }

    // Si no hay schedule, seleccionar cualquiera
    return questions[_random.nextInt(questions.length)];
  }

  // ============ RESPONSE HANDLING ============

  /// Registra que se mostró una encuesta al usuario
  Future<void> recordPollShown(String questionId) async {
    final userId = currentUserId;
    if (userId == null) return;

    await _repository.recordPollShown(
      oderId: userId,
      questionId: questionId,
      shownAt: DateTime.now(),
    );
  }

  /// Guarda la respuesta del usuario a una encuesta
  Future<MoodPollResponse> submitResponse({
    required MoodPollQuestion question,
    required MoodPollOption selectedOption,
  }) async {
    final userId = currentUserId;
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    final response = MoodPollResponse(
      id: '', // Se generará en Firestore
      oderId: userId,
      questionId: question.id,
      questionText: question.text,
      selectedOptionId: selectedOption.id,
      selectedOptionText: selectedOption.text,
      selectedEmoji: selectedOption.emoji,
      sentimentScore: selectedOption.sentimentScore,
      respondedAt: DateTime.now(),
    );

    final responseId = await _repository.saveResponse(response);

    return response.copyWith(id: responseId);
  }

  /// Marca una respuesta como compartida en story
  Future<void> markResponseAsShared(String responseId, String storyId) async {
    await _repository.markAsSharedInStory(responseId, storyId);
  }

  // ============ STATS & REPORTING ============

  /// Obtiene estadísticas de la semana actual para el usuario
  Future<MoodPollStats> getCurrentWeekStats() async {
    final userId = currentUserId;
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final startOfWeek = DateTime(weekStart.year, weekStart.month, weekStart.day);

    return _repository.calculateStats(
      oderId: userId,
      startDate: startOfWeek,
      endDate: now,
    );
  }

  /// Obtiene estadísticas para un hijo (usado por padres en reportes)
  Future<MoodPollStats> getChildWeekStats(String childId) async {
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final startOfWeek = DateTime(weekStart.year, weekStart.month, weekStart.day);

    return _repository.calculateStats(
      oderId: childId,
      startDate: startOfWeek,
      endDate: now,
    );
  }

  /// Obtiene respuestas de la última semana para un usuario
  Future<List<MoodPollResponse>> getWeeklyResponses(String userId) async {
    return _repository.getWeeklyResponses(userId);
  }

  /// Obtiene el promedio de sentimiento para un período
  Future<double> getAverageSentiment({
    required String userId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final responses = await _repository.getUserResponses(
      oderId: userId,
      startDate: startDate,
      endDate: endDate,
    );

    if (responses.isEmpty) return 0;

    final total = responses.fold<int>(
      0,
      (sum, response) => sum + response.sentimentScore,
    );

    return total / responses.length;
  }

  // ============ ADMIN / SETUP ============

  /// Inicializa las preguntas predefinidas en Firestore
  Future<void> initializePredefinedQuestions() async {
    await _repository.initializePredefinedQuestions();
  }

  /// Crea una pregunta personalizada (para IA o admin)
  Future<String> createCustomQuestion({
    required String text,
    required MoodPollQuestionType type,
    required List<MoodPollOption> options,
    String? contextHint,
    bool isAiGenerated = true,
  }) async {
    final question = MoodPollQuestion(
      id: '', // Se generará en Firestore
      text: text,
      type: type,
      options: options,
      isAiGenerated: isAiGenerated,
      contextHint: contextHint,
    );

    return _repository.createQuestion(question);
  }

  // ============ HELPER METHODS ============

  /// Genera un resumen textual de las respuestas para el reporte semanal
  String generateResponsesSummary(List<MoodPollResponse> responses) {
    if (responses.isEmpty) {
      return 'No respondió a las encuestas de mood esta semana.';
    }

    final positiveCount = responses.where((r) => r.sentimentScore > 0).length;
    final negativeCount = responses.where((r) => r.sentimentScore < 0).length;
    // neutralCount = responses.length - positiveCount - negativeCount if needed

    final avgSentiment = responses.fold<int>(0, (sum, r) => sum + r.sentimentScore) / responses.length;

    String summary = 'Respondió ${responses.length} encuestas de mood. ';

    if (avgSentiment > 0.5) {
      summary += 'En general mostró un estado de ánimo positivo';
      if (positiveCount > negativeCount * 2) {
        summary += ' consistente';
      }
      summary += '.';
    } else if (avgSentiment < -0.5) {
      summary += 'Mostró señales de un estado de ánimo bajo que podría requerir atención.';
    } else {
      summary += 'Su estado de ánimo fue variable durante la semana.';
    }

    // Agregar respuestas destacadas
    final mostNegative = responses
        .where((r) => r.sentimentScore <= -1)
        .toList();

    if (mostNegative.isNotEmpty) {
      summary += '\n\nRespuestas que requieren atención:\n';
      for (final response in mostNegative.take(3)) {
        summary += '• ${response.questionText}: "${response.selectedOptionText}" ${response.selectedEmoji}\n';
      }
    }

    return summary;
  }

  /// Obtiene sugerencias de temas para conversar basadas en las respuestas
  List<String> getSuggestedConversationTopics(List<MoodPollResponse> responses) {
    final topics = <String>[];

    for (final response in responses) {
      if (response.sentimentScore <= -1) {
        // Respuesta negativa - sugerir tema de conversación
        if (response.questionText.contains('amigos') ||
            response.questionText.contains('social')) {
          topics.add('Preguntale sobre sus amistades y cómo se lleva con ellos');
        } else if (response.questionText.contains('cole') ||
            response.questionText.contains('escuela')) {
          topics.add('Conversá sobre cómo le está yendo en el colegio');
        } else if (response.questionText.contains('preocupa')) {
          topics.add('Preguntale si hay algo que le esté preocupando últimamente');
        } else if (response.questionText.contains('energía') ||
            response.questionText.contains('dormiste')) {
          topics.add('Consultá cómo está durmiendo y si descansa bien');
        } else {
          topics.add('Preguntale cómo se siente y si quiere hablar sobre algo');
        }
      } else if (response.sentimentScore >= 1) {
        // Respuesta positiva - reforzar
        topics.add('Felicitalo por ${_extractTopic(response.questionText)}');
      }
    }

    // Eliminar duplicados y limitar
    return topics.toSet().take(5).toList();
  }

  String _extractTopic(String questionText) {
    if (questionText.contains('amigos')) return 'su relación con sus amigos';
    if (questionText.contains('cole')) return 'cómo le va en el colegio';
    if (questionText.contains('energía')) return 'su buena energía';
    if (questionText.contains('día')) return 'su buen día';
    return 'su actitud positiva';
  }
}
