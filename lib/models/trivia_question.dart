import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipo de pregunta de trivia
enum QuestionType {
  multipleChoice, // 4 opciones
  trueFalse,      // Verdadero/Falso
}

/// Opción de respuesta para una pregunta de trivia
class TriviaOption {
  final String id;
  final String text;
  final String? emoji;

  TriviaOption({
    required this.id,
    required this.text,
    this.emoji,
  });

  factory TriviaOption.fromMap(Map<String, dynamic> data) {
    return TriviaOption(
      id: data['id'] ?? '',
      text: data['text'] ?? '',
      emoji: data['emoji'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'text': text,
      'emoji': emoji,
    };
  }

  TriviaOption copyWith({
    String? id,
    String? text,
    String? emoji,
  }) {
    return TriviaOption(
      id: id ?? this.id,
      text: text ?? this.text,
      emoji: emoji ?? this.emoji,
    );
  }

  @override
  String toString() => 'TriviaOption(id: $id, text: $text)';
}

/// Modelo para preguntas de trivia (subcolección de trivias)
///
/// Cada pregunta pertenece a una trivia y contiene el texto,
/// opciones de respuesta y la respuesta correcta.
class TriviaQuestion {
  final String id;
  final String triviaId;
  final int order;
  final String text;
  final QuestionType type;
  final List<TriviaOption> options;
  final String correctOptionId;
  final String? imageUrl;
  final int basePoints;

  TriviaQuestion({
    required this.id,
    required this.triviaId,
    required this.order,
    required this.text,
    required this.type,
    required this.options,
    required this.correctOptionId,
    this.imageUrl,
    this.basePoints = 100,
  });

  // ==================== Factory Constructors ====================

  factory TriviaQuestion.fromFirestore(DocumentSnapshot doc, String triviaId) {
    final data = doc.data() as Map<String, dynamic>;
    return TriviaQuestion.fromMap(doc.id, triviaId, data);
  }

  factory TriviaQuestion.fromMap(
      String id, String triviaId, Map<String, dynamic> data) {
    return TriviaQuestion(
      id: id,
      triviaId: triviaId,
      order: data['order'] ?? 0,
      text: data['text'] ?? '',
      type: _parseType(data['type']),
      options: (data['options'] as List<dynamic>?)
              ?.map((e) => TriviaOption.fromMap(e as Map<String, dynamic>))
              .toList() ??
          [],
      correctOptionId: data['correctOptionId'] ?? '',
      imageUrl: data['imageUrl'],
      basePoints: data['basePoints'] ?? 100,
    );
  }

  static QuestionType _parseType(String? type) {
    switch (type) {
      case 'multipleChoice':
        return QuestionType.multipleChoice;
      case 'trueFalse':
        return QuestionType.trueFalse;
      default:
        return QuestionType.multipleChoice;
    }
  }

  // ==================== Serialization ====================

  Map<String, dynamic> toFirestore() {
    return {
      'order': order,
      'text': text,
      'type': type.name,
      'options': options.map((o) => o.toMap()).toList(),
      'correctOptionId': correctOptionId,
      'imageUrl': imageUrl,
      'basePoints': basePoints,
    };
  }

  // ==================== Computed Getters ====================

  /// Cantidad de opciones disponibles
  int get optionCount => options.length;

  /// Verifica si es pregunta de verdadero/falso
  bool get isTrueFalse => type == QuestionType.trueFalse;

  /// Verifica si es pregunta de opción múltiple
  bool get isMultipleChoice => type == QuestionType.multipleChoice;

  /// Obtiene la opción correcta
  TriviaOption? get correctOption {
    try {
      return options.firstWhere((o) => o.id == correctOptionId);
    } catch (_) {
      return null;
    }
  }

  /// Verifica si una opción es la correcta
  bool isCorrectOption(String optionId) => optionId == correctOptionId;

  /// Obtiene las opciones en orden aleatorio basado en un seed
  /// Esto asegura que el orden sea consistente para cada usuario
  /// pero diferente entre usuarios
  List<TriviaOption> getShuffledOptions(String oderId) {
    final seed = '$id$oderId'.hashCode;
    final shuffled = List<TriviaOption>.from(options);
    shuffled.shuffle(_SeededRandom(seed));
    return shuffled;
  }

  // ==================== Static Query Methods ====================

  /// Referencia a la colección de preguntas de una trivia
  static CollectionReference<Map<String, dynamic>> _questionsCollection(
      String triviaId) {
    return FirebaseFirestore.instance
        .collection('trivias')
        .doc(triviaId)
        .collection('questions');
  }

  /// Obtener una pregunta por ID
  static Future<TriviaQuestion?> getById(
      String triviaId, String questionId) async {
    final doc = await _questionsCollection(triviaId).doc(questionId).get();
    if (!doc.exists) return null;
    return TriviaQuestion.fromFirestore(doc, triviaId);
  }

  /// Obtener todas las preguntas de una trivia ordenadas
  static Future<List<TriviaQuestion>> getAllByTrivia(String triviaId) async {
    final snapshot = await _questionsCollection(triviaId)
        .orderBy('order', descending: false)
        .get();
    return snapshot.docs
        .map((doc) => TriviaQuestion.fromFirestore(doc, triviaId))
        .toList();
  }

  /// Stream de preguntas de una trivia
  static Stream<List<TriviaQuestion>> watchByTrivia(String triviaId) {
    return _questionsCollection(triviaId)
        .orderBy('order', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => TriviaQuestion.fromFirestore(doc, triviaId))
            .toList());
  }

  // ==================== Copy With ====================

  TriviaQuestion copyWith({
    String? id,
    String? triviaId,
    int? order,
    String? text,
    QuestionType? type,
    List<TriviaOption>? options,
    String? correctOptionId,
    String? imageUrl,
    int? basePoints,
  }) {
    return TriviaQuestion(
      id: id ?? this.id,
      triviaId: triviaId ?? this.triviaId,
      order: order ?? this.order,
      text: text ?? this.text,
      type: type ?? this.type,
      options: options ?? this.options,
      correctOptionId: correctOptionId ?? this.correctOptionId,
      imageUrl: imageUrl ?? this.imageUrl,
      basePoints: basePoints ?? this.basePoints,
    );
  }

  @override
  String toString() {
    return 'TriviaQuestion(id: $id, order: $order, text: $text, type: $type)';
  }
}

/// Random con seed para shuffling consistente
class _SeededRandom implements Random {
  int _seed;

  _SeededRandom(this._seed);

  @override
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }

  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);

  @override
  bool nextBool() => nextInt(2) == 0;
}

