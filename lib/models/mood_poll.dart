import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipos de pregunta para encuestas de mood
enum MoodPollQuestionType {
  emotional,  // Preguntas sobre emociones y sentimientos
  activity,   // Preguntas sobre actividades del día
  social,     // Preguntas sobre interacciones sociales
  wellbeing,  // Preguntas sobre bienestar general
}

/// Modelo para una pregunta de encuesta de mood
///
/// Estas preguntas se muestran entre stories para que los hijos
/// puedan expresar cómo se sienten de forma lúdica.
class MoodPollQuestion {
  final String id;
  final String text;
  final MoodPollQuestionType type;
  final List<MoodPollOption> options;
  final String? contextHint; // Para preguntas generadas por IA basadas en contexto
  final DateTime createdAt;
  final bool isActive;

  MoodPollQuestion({
    required this.id,
    required this.text,
    required this.type,
    required this.options,
    this.contextHint,
    DateTime? createdAt,
    this.isActive = true,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toFirestore() {
    return {
      'text': text,
      'type': type.name,
      'options': options.map((o) => o.toFirestore()).toList(),
      'contextHint': contextHint,
      'createdAt': Timestamp.fromDate(createdAt),
      'isActive': isActive,
    };
  }

  factory MoodPollQuestion.fromFirestore(String id, Map<String, dynamic> data) {
    return MoodPollQuestion(
      id: id,
      text: data['text'] as String,
      type: MoodPollQuestionType.values.firstWhere(
        (t) => t.name == data['type'],
        orElse: () => MoodPollQuestionType.emotional,
      ),
      options: (data['options'] as List<dynamic>)
          .map((o) => MoodPollOption.fromFirestore(o as Map<String, dynamic>))
          .toList(),
      contextHint: data['contextHint'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isActive: data['isActive'] as bool? ?? true,
    );
  }

  MoodPollQuestion copyWith({
    String? id,
    String? text,
    MoodPollQuestionType? type,
    List<MoodPollOption>? options,
    String? contextHint,
    DateTime? createdAt,
    bool? isActive,
  }) {
    return MoodPollQuestion(
      id: id ?? this.id,
      text: text ?? this.text,
      type: type ?? this.type,
      options: options ?? this.options,
      contextHint: contextHint ?? this.contextHint,
      createdAt: createdAt ?? this.createdAt,
      isActive: isActive ?? this.isActive,
    );
  }
}

/// Una opción de respuesta para una pregunta de mood poll
class MoodPollOption {
  final String id;
  final String text;
  final String emoji;
  final int sentimentScore; // -2 a +2 para análisis

  MoodPollOption({
    required this.id,
    required this.text,
    required this.emoji,
    required this.sentimentScore,
  });

  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'text': text,
      'emoji': emoji,
      'sentimentScore': sentimentScore,
    };
  }

  factory MoodPollOption.fromFirestore(Map<String, dynamic> data) {
    return MoodPollOption(
      id: data['id'] as String,
      text: data['text'] as String,
      emoji: data['emoji'] as String,
      sentimentScore: data['sentimentScore'] as int? ?? 0,
    );
  }
}

/// Respuesta de un usuario a una pregunta de mood poll
class MoodPollResponse {
  final String id;
  final String oderId;
  final String questionId;
  final String questionText;
  final String selectedOptionId;
  final String selectedOptionText;
  final String selectedEmoji;
  final int sentimentScore;
  final DateTime respondedAt;
  final bool sharedAsStory;
  final String? storyId; // Si se compartió como story

  MoodPollResponse({
    required this.id,
    required this.oderId,
    required this.questionId,
    required this.questionText,
    required this.selectedOptionId,
    required this.selectedOptionText,
    required this.selectedEmoji,
    required this.sentimentScore,
    DateTime? respondedAt,
    this.sharedAsStory = false,
    this.storyId,
  }) : respondedAt = respondedAt ?? DateTime.now();

  Map<String, dynamic> toFirestore() {
    return {
      'userId': oderId,
      'questionId': questionId,
      'questionText': questionText,
      'selectedOptionId': selectedOptionId,
      'selectedOptionText': selectedOptionText,
      'selectedEmoji': selectedEmoji,
      'sentimentScore': sentimentScore,
      'respondedAt': Timestamp.fromDate(respondedAt),
      'sharedAsStory': sharedAsStory,
      'storyId': storyId,
    };
  }

  factory MoodPollResponse.fromFirestore(String id, Map<String, dynamic> data) {
    return MoodPollResponse(
      id: id,
      oderId: data['userId'] as String,
      questionId: data['questionId'] as String,
      questionText: data['questionText'] as String,
      selectedOptionId: data['selectedOptionId'] as String,
      selectedOptionText: data['selectedOptionText'] as String,
      selectedEmoji: data['selectedEmoji'] as String,
      sentimentScore: data['sentimentScore'] as int? ?? 0,
      respondedAt: (data['respondedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      sharedAsStory: data['sharedAsStory'] as bool? ?? false,
      storyId: data['storyId'] as String?,
    );
  }

  MoodPollResponse copyWith({
    String? id,
    String? oderId,
    String? questionId,
    String? questionText,
    String? selectedOptionId,
    String? selectedOptionText,
    String? selectedEmoji,
    int? sentimentScore,
    DateTime? respondedAt,
    bool? sharedAsStory,
    String? storyId,
  }) {
    return MoodPollResponse(
      id: id ?? this.id,
      oderId: oderId ?? this.oderId,
      questionId: questionId ?? this.questionId,
      questionText: questionText ?? this.questionText,
      selectedOptionId: selectedOptionId ?? this.selectedOptionId,
      selectedOptionText: selectedOptionText ?? this.selectedOptionText,
      selectedEmoji: selectedEmoji ?? this.selectedEmoji,
      sentimentScore: sentimentScore ?? this.sentimentScore,
      respondedAt: respondedAt ?? this.respondedAt,
      sharedAsStory: sharedAsStory ?? this.sharedAsStory,
      storyId: storyId ?? this.storyId,
    );
  }
}

/// Estadísticas de mood polls para un período
class MoodPollStats {
  final String userId;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int totalQuestions;
  final int totalResponses;
  final double averageSentiment; // -2 a +2
  final Map<MoodPollQuestionType, int> responsesByType;
  final List<MoodPollResponse> responses;

  MoodPollStats({
    required this.userId,
    required this.periodStart,
    required this.periodEnd,
    required this.totalQuestions,
    required this.totalResponses,
    required this.averageSentiment,
    required this.responsesByType,
    required this.responses,
  });

  /// Porcentaje de participación
  double get participationRate =>
      totalQuestions > 0 ? (totalResponses / totalQuestions) * 100 : 0;

  /// Emoji que representa el mood promedio
  String get moodEmoji {
    if (averageSentiment >= 1.5) return '😊';
    if (averageSentiment >= 0.5) return '🙂';
    if (averageSentiment >= -0.5) return '😐';
    if (averageSentiment >= -1.5) return '😕';
    return '😢';
  }

  /// Descripción textual del mood
  String get moodDescription {
    if (averageSentiment >= 1.5) return 'Muy positivo';
    if (averageSentiment >= 0.5) return 'Positivo';
    if (averageSentiment >= -0.5) return 'Neutral';
    if (averageSentiment >= -1.5) return 'Algo bajo';
    return 'Preocupante';
  }
}

/// Preguntas predefinidas para usar cuando no hay contexto de IA
class PredefinedMoodQuestions {
  static final List<MoodPollQuestion> questions = [
    // Emocionales
    MoodPollQuestion(
      id: 'pred_1',
      text: '¿Cómo te sentís hoy?',
      type: MoodPollQuestionType.emotional,
      options: [
        MoodPollOption(id: 'a', text: 'Increíble', emoji: '🤩', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Bien', emoji: '😊', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Normal', emoji: '😐', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'No muy bien', emoji: '😔', sentimentScore: -1),
      ],
    ),
    MoodPollQuestion(
      id: 'pred_2',
      text: '¿Qué fue lo mejor de tu día?',
      type: MoodPollQuestionType.emotional,
      options: [
        MoodPollOption(id: 'a', text: 'Ver amigos', emoji: '👫', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Algo que aprendí', emoji: '📚', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Tiempo para mí', emoji: '🎮', sentimentScore: 1),
        MoodPollOption(id: 'd', text: 'Nada especial', emoji: '🤷', sentimentScore: -1),
      ],
    ),
    MoodPollQuestion(
      id: 'pred_3',
      text: '¿Cuánta energía tenés ahora?',
      type: MoodPollQuestionType.wellbeing,
      options: [
        MoodPollOption(id: 'a', text: 'Full power', emoji: '⚡', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Bastante bien', emoji: '💪', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Más o menos', emoji: '😴', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Agotado/a', emoji: '😩', sentimentScore: -1),
      ],
    ),
    // Sociales
    MoodPollQuestion(
      id: 'pred_4',
      text: '¿Cómo estuvo tu día con tus amigos?',
      type: MoodPollQuestionType.social,
      options: [
        MoodPollOption(id: 'a', text: 'Genial', emoji: '🎉', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Bien', emoji: '👍', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'No los vi', emoji: '🏠', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Complicado', emoji: '😓', sentimentScore: -1),
      ],
    ),
    MoodPollQuestion(
      id: 'pred_5',
      text: '¿Te sentís escuchado/a por la gente a tu alrededor?',
      type: MoodPollQuestionType.social,
      options: [
        MoodPollOption(id: 'a', text: 'Siempre', emoji: '💯', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Casi siempre', emoji: '😊', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'A veces', emoji: '🤔', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Poco', emoji: '😶', sentimentScore: -1),
      ],
    ),
    // Actividades
    MoodPollQuestion(
      id: 'pred_6',
      text: '¿Qué tenés ganas de hacer ahora?',
      type: MoodPollQuestionType.activity,
      options: [
        MoodPollOption(id: 'a', text: 'Salir', emoji: '🚶', sentimentScore: 1),
        MoodPollOption(id: 'b', text: 'Jugar', emoji: '🎮', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Descansar', emoji: '🛋️', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Nada', emoji: '😑', sentimentScore: -1),
      ],
    ),
    MoodPollQuestion(
      id: 'pred_7',
      text: '¿Cómo dormiste anoche?',
      type: MoodPollQuestionType.wellbeing,
      options: [
        MoodPollOption(id: 'a', text: 'Muy bien', emoji: '😴', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Bien', emoji: '🌙', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Regular', emoji: '😪', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Mal', emoji: '😵', sentimentScore: -1),
      ],
    ),
    MoodPollQuestion(
      id: 'pred_8',
      text: '¿Cómo te fue en el cole/escuela?',
      type: MoodPollQuestionType.activity,
      options: [
        MoodPollOption(id: 'a', text: 'Muy bien', emoji: '🌟', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Bien', emoji: '📖', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Normal', emoji: '📝', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Difícil', emoji: '😫', sentimentScore: -1),
      ],
    ),
    // Bienestar emocional profundo
    MoodPollQuestion(
      id: 'pred_9',
      text: '¿Hay algo que te preocupa?',
      type: MoodPollQuestionType.emotional,
      options: [
        MoodPollOption(id: 'a', text: 'Nada', emoji: '😌', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Cosas menores', emoji: '🤏', sentimentScore: 0),
        MoodPollOption(id: 'c', text: 'Algunas cosas', emoji: '😟', sentimentScore: -1),
        MoodPollOption(id: 'd', text: 'Sí, bastante', emoji: '😰', sentimentScore: -2),
      ],
    ),
    MoodPollQuestion(
      id: 'pred_10',
      text: '¿Cuánto disfrutaste el día de hoy?',
      type: MoodPollQuestionType.emotional,
      options: [
        MoodPollOption(id: 'a', text: 'Mucho', emoji: '🥳', sentimentScore: 2),
        MoodPollOption(id: 'b', text: 'Bastante', emoji: '😄', sentimentScore: 1),
        MoodPollOption(id: 'c', text: 'Un poco', emoji: '😐', sentimentScore: 0),
        MoodPollOption(id: 'd', text: 'Nada', emoji: '😞', sentimentScore: -2),
      ],
    ),
  ];

  /// Obtener una pregunta aleatoria
  static MoodPollQuestion getRandomQuestion() {
    final random = DateTime.now().millisecondsSinceEpoch % questions.length;
    return questions[random];
  }

  /// Obtener preguntas por tipo
  static List<MoodPollQuestion> getQuestionsByType(MoodPollQuestionType type) {
    return questions.where((q) => q.type == type).toList();
  }
}
