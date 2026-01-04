import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';

import '../../models/trivia_question.dart';
import '../../utils/release_logger.dart';
import 'trivia_creation_service.dart';

/// Categoría de pregunta sugerida
class TriviaCategory {
  final String id;
  final String name;
  final String emoji;
  final String description;

  const TriviaCategory({
    required this.id,
    required this.name,
    required this.emoji,
    required this.description,
  });
}

/// Pregunta sugerida completa
class TriviaSuggestion {
  final String question;
  final List<String> options;
  final int correctOptionIndex;
  final TriviaCategory category;

  TriviaSuggestion({
    required this.question,
    required this.options,
    required this.correctOptionIndex,
    required this.category,
  });

  /// Convertir a draft de pregunta
  TriviaQuestionDraft toDraft() {
    return TriviaQuestionDraft(
      text: question,
      type: options.length == 2
          ? QuestionType.trueFalse
          : QuestionType.multipleChoice,
      optionTexts: options,
      correctOptionIndex: correctOptionIndex,
    );
  }
}

/// Servicio para generar sugerencias de preguntas de trivia
class TriviaSuggestionService {
  static TriviaSuggestionService? _instance;

  final FirebaseFunctions _functions;
  final Random _random = Random();

  /// Historial de sugerencias usadas para evitar repeticiones
  final Set<String> _usedSuggestionKeys = {};

  TriviaSuggestionService._internal({
    FirebaseFunctions? functions,
  }) : _functions = functions ?? FirebaseFunctions.instance;

  factory TriviaSuggestionService({
    FirebaseFunctions? functions,
  }) {
    _instance ??= TriviaSuggestionService._internal(
      functions: functions,
    );
    return _instance!;
  }

  /// Categorías disponibles
  static const List<TriviaCategory> categories = [
    TriviaCategory(
      id: 'familia',
      name: 'Familia',
      emoji: '👨‍👩‍👧‍👦',
      description: 'Preguntas sobre tu familia',
    ),
    TriviaCategory(
      id: 'gustos',
      name: 'Gustos',
      emoji: '❤️',
      description: 'Tus cosas favoritas',
    ),
    TriviaCategory(
      id: 'personalidad',
      name: 'Personalidad',
      emoji: '🎭',
      description: 'Cómo eres',
    ),
    TriviaCategory(
      id: 'cultura',
      name: 'Cultura',
      emoji: '🎬',
      description: 'Películas, música, series',
    ),
    TriviaCategory(
      id: 'curiosidades',
      name: 'Curiosidades',
      emoji: '🤔',
      description: 'Datos interesantes',
    ),
    TriviaCategory(
      id: 'random',
      name: 'Aleatorio',
      emoji: '🎲',
      description: 'Sorpréndeme',
    ),
  ];

  /// Obtener todas las categorías
  List<TriviaCategory> getCategories() => categories;

  /// Obtener categoría por ID
  TriviaCategory? getCategoryById(String id) {
    try {
      return categories.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Limpiar historial de sugerencias usadas
  void clearUsedSuggestions() {
    _usedSuggestionKeys.clear();
  }

  /// Generar una pregunta sugerida usando IA
  ///
  /// [categoryId] - Categoría de la pregunta (opcional, default: random)
  ///
  /// Esta función llama a una Cloud Function que usa Claude/GPT
  /// para generar preguntas personalizadas.
  Future<TriviaSuggestion> getSuggestedQuestion({String? categoryId}) async {
    final category = categoryId != null
        ? getCategoryById(categoryId) ?? categories.last
        : categories.last;

    final actualCategory = category.id == 'random'
        ? categories[_random.nextInt(categories.length - 1)]
        : category;

    try {
      ReleaseLogger.log(
          '🎯 [TriviaSuggestion] Generando pregunta para: ${actualCategory.name}');

      // Llamar a Cloud Function
      final result = await _functions
          .httpsCallable('generateTriviaSuggestion')
          .call({'category': actualCategory.id});

      final data = result.data as Map<String, dynamic>;

      return TriviaSuggestion(
        question: data['question'] as String,
        options: List<String>.from(data['options']),
        correctOptionIndex: data['correctOptionIndex'] as int,
        category: actualCategory,
      );
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaSuggestion] Error generando pregunta: $e');

      // Fallback a pregunta predefinida
      return _getFallbackSuggestion(actualCategory);
    }
  }

  /// Obtener pregunta predefinida como fallback (sin repetir)
  TriviaSuggestion _getFallbackSuggestion(TriviaCategory category) {
    final suggestions = _predefinedSuggestions[category.id] ?? [];
    if (suggestions.isEmpty) {
      // Pregunta genérica
      return TriviaSuggestion(
        question: '¿Cuál es mi color favorito?',
        options: ['Azul', 'Rojo', 'Verde', 'Amarillo'],
        correctOptionIndex: 0,
        category: category,
      );
    }

    // Filtrar sugerencias no usadas
    final availableSuggestions = suggestions.where((s) {
      final key = '${category.id}_${s.question}';
      return !_usedSuggestionKeys.contains(key);
    }).toList();

    // Si todas fueron usadas, limpiar historial de esta categoría
    if (availableSuggestions.isEmpty) {
      _usedSuggestionKeys.removeWhere((k) => k.startsWith('${category.id}_'));
      return _getFallbackSuggestion(category); // Recursivo con historial limpio
    }

    // Seleccionar aleatoriamente y marcar como usada
    final suggestion = availableSuggestions[_random.nextInt(availableSuggestions.length)];
    _usedSuggestionKeys.add('${category.id}_${suggestion.question}');

    return suggestion;
  }

  /// Preguntas predefinidas por categoría (generales, no específicas)
  final Map<String, List<TriviaSuggestion>> _predefinedSuggestions = {
    'familia': [
      TriviaSuggestion(
        question: '¿Cuántos hermanos tengo?',
        options: ['Ninguno', '1', '2', '3 o más'],
        correctOptionIndex: 1,
        category: categories[0],
      ),
      TriviaSuggestion(
        question: '¿Tengo mascota?',
        options: ['Sí, un perro', 'Sí, un gato', 'Sí, otro animal', 'No tengo'],
        correctOptionIndex: 0,
        category: categories[0],
      ),
      TriviaSuggestion(
        question: '¿Soy el mayor, menor o del medio en mi familia?',
        options: ['Mayor', 'Menor', 'Del medio', 'Hijo único'],
        correctOptionIndex: 0,
        category: categories[0],
      ),
      TriviaSuggestion(
        question: '¿Dónde vivo actualmente?',
        options: ['Con mis padres', 'Solo/a', 'Con roommates', 'Con pareja'],
        correctOptionIndex: 0,
        category: categories[0],
      ),
    ],
    'gustos': [
      TriviaSuggestion(
        question: '¿Cuál es mi comida favorita?',
        options: ['Pizza', 'Hamburguesa', 'Sushi', 'Tacos'],
        correctOptionIndex: 0,
        category: categories[1],
      ),
      TriviaSuggestion(
        question: '¿Cuál es mi color favorito?',
        options: ['Azul', 'Rojo', 'Verde', 'Negro'],
        correctOptionIndex: 0,
        category: categories[1],
      ),
      TriviaSuggestion(
        question: '¿Qué tipo de música prefiero?',
        options: ['Pop', 'Rock', 'Reggaeton', 'Electrónica'],
        correctOptionIndex: 0,
        category: categories[1],
      ),
      TriviaSuggestion(
        question: '¿Cuál es mi estación del año favorita?',
        options: ['Primavera', 'Verano', 'Otoño', 'Invierno'],
        correctOptionIndex: 0,
        category: categories[1],
      ),
      TriviaSuggestion(
        question: '¿Prefiero playa o montaña?',
        options: ['Playa', 'Montaña'],
        correctOptionIndex: 0,
        category: categories[1],
      ),
      TriviaSuggestion(
        question: '¿Cuál es mi deporte favorito?',
        options: ['Fútbol', 'Basketball', 'Tennis', 'No me gusta el deporte'],
        correctOptionIndex: 0,
        category: categories[1],
      ),
    ],
    'personalidad': [
      TriviaSuggestion(
        question: '¿Qué me da más miedo?',
        options: ['Arañas/insectos', 'Alturas', 'Oscuridad', 'Hablar en público'],
        correctOptionIndex: 0,
        category: categories[2],
      ),
      TriviaSuggestion(
        question: '¿Soy más de día o de noche?',
        options: ['De día', 'De noche'],
        correctOptionIndex: 1,
        category: categories[2],
      ),
      TriviaSuggestion(
        question: '¿Soy introvertido o extrovertido?',
        options: ['Introvertido', 'Extrovertido', 'Ambivertido'],
        correctOptionIndex: 0,
        category: categories[2],
      ),
      TriviaSuggestion(
        question: '¿Cómo reacciono al estrés?',
        options: ['Me como las uñas', 'Duermo mucho', 'Como de más', 'Hago ejercicio'],
        correctOptionIndex: 0,
        category: categories[2],
      ),
      TriviaSuggestion(
        question: '¿Qué hago un domingo típico?',
        options: ['Descanso en casa', 'Salgo con amigos', 'Hago deporte', 'Trabajo/estudio'],
        correctOptionIndex: 0,
        category: categories[2],
      ),
    ],
    'cultura': [
      TriviaSuggestion(
        question: '¿Cuál es mi película favorita de todos los tiempos?',
        options: ['Una de acción', 'Una de comedia', 'Una de terror', 'Una romántica'],
        correctOptionIndex: 0,
        category: categories[3],
      ),
      TriviaSuggestion(
        question: '¿Qué plataforma de streaming uso más?',
        options: ['Netflix', 'Disney+', 'HBO Max', 'Amazon Prime'],
        correctOptionIndex: 0,
        category: categories[3],
      ),
      TriviaSuggestion(
        question: '¿Cuál es mi serie favorita?',
        options: ['Drama', 'Comedia', 'Thriller', 'Ciencia ficción'],
        correctOptionIndex: 0,
        category: categories[3],
      ),
      TriviaSuggestion(
        question: '¿Qué tipo de libros prefiero?',
        options: ['Novelas', 'No ficción', 'Fantasía', 'No leo mucho'],
        correctOptionIndex: 0,
        category: categories[3],
      ),
      TriviaSuggestion(
        question: '¿Cuál es mi videojuego favorito?',
        options: ['Shooters', 'RPG', 'Deportes', 'No juego videojuegos'],
        correctOptionIndex: 0,
        category: categories[3],
      ),
    ],
    'curiosidades': [
      TriviaSuggestion(
        question: '¿Cuál es mi superpoder deseado?',
        options: ['Volar', 'Invisibilidad', 'Leer mentes', 'Super fuerza'],
        correctOptionIndex: 0,
        category: categories[4],
      ),
      TriviaSuggestion(
        question: '¿Si ganara la lotería, qué haría primero?',
        options: ['Viajar', 'Comprar casa', 'Invertir', 'Regalar a familia'],
        correctOptionIndex: 0,
        category: categories[4],
      ),
      TriviaSuggestion(
        question: '¿Cuál sería mi trabajo soñado?',
        options: ['Artista/Músico', 'Empresario', 'Viajero profesional', 'Científico'],
        correctOptionIndex: 0,
        category: categories[4],
      ),
      TriviaSuggestion(
        question: '¿A qué época me gustaría viajar?',
        options: ['Futuro', 'Edad Media', 'Los 80s', 'Egipto antiguo'],
        correctOptionIndex: 0,
        category: categories[4],
      ),
      TriviaSuggestion(
        question: '¿Qué habilidad me gustaría aprender?',
        options: ['Tocar un instrumento', 'Nuevo idioma', 'Cocinar', 'Programar'],
        correctOptionIndex: 0,
        category: categories[4],
      ),
      TriviaSuggestion(
        question: '¿Prefiero café o té?',
        options: ['Café', 'Té', 'Ninguno'],
        correctOptionIndex: 0,
        category: categories[4],
      ),
    ],
  };

  /// Obtener multiples sugerencias (para mostrar lista)
  Future<List<TriviaSuggestion>> getMultipleSuggestions({
    String? categoryId,
    int count = 5,
  }) async {
    final suggestions = <TriviaSuggestion>[];

    for (int i = 0; i < count; i++) {
      try {
        final suggestion = await getSuggestedQuestion(categoryId: categoryId);
        suggestions.add(suggestion);
      } catch (e) {
        // Si falla, agregar fallback
        final category = categoryId != null
            ? getCategoryById(categoryId) ?? categories.last
            : categories[_random.nextInt(categories.length - 1)];
        suggestions.add(_getFallbackSuggestion(category));
      }
    }

    return suggestions;
  }
}
