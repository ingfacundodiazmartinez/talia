import 'dart:async';
import 'dart:io';

import '../services/trivia/trivia_creation_service.dart';
import '../services/trivia/trivia_orchestrator.dart';
import '../services/trivia/trivia_suggestion_service.dart';
import '../utils/release_logger.dart';

/// Controller para la creación de trivias (wizard multi-paso)
///
/// Responsabilidades:
/// - Manejar estado del wizard (paso actual, preguntas)
/// - Agregar, editar, eliminar y reordenar preguntas
/// - Generar sugerencias de preguntas
/// - Publicar trivia con validaciones
class TriviaCreationController {
  static const int maxQuestions = 10;
  static const int minQuestions = 1;

  // Servicios
  final TriviaOrchestrator _orchestrator;

  // Estado del wizard
  int _currentStep = 0;
  String _title = '';
  File? _backgroundImage;
  final List<TriviaQuestionDraft> _questions = [];
  bool _isLoading = false;
  bool _isPublishing = false;
  bool _isSuggestingQuestion = false;
  String? _errorMessage;

  // Callbacks
  Function(int)? onStepChanged;
  Function(List<TriviaQuestionDraft>)? onQuestionsChanged;
  Function(bool)? onLoadingChanged;
  Function(bool)? onPublishingChanged;
  Function(bool)? onSuggestingChanged;
  Function()? onMetadataChanged;
  Function(String)? onError;
  Function(String triviaId)? onPublishSuccess;
  Function(TriviaSuggestion)? onSuggestionReceived;

  TriviaCreationController({
    TriviaOrchestrator? orchestrator,
  }) : _orchestrator = orchestrator ?? TriviaOrchestrator();

  // Getters
  int get currentStep => _currentStep;
  String get title => _title;
  File? get backgroundImage => _backgroundImage;
  List<TriviaQuestionDraft> get questions => List.unmodifiable(_questions);
  int get questionCount => _questions.length;
  bool get isLoading => _isLoading;
  bool get isPublishing => _isPublishing;
  bool get isSuggestingQuestion => _isSuggestingQuestion;
  String? get errorMessage => _errorMessage;
  bool get canAddQuestion => _questions.length < maxQuestions;
  bool get canPublish => _questions.length >= minQuestions && _title.isNotEmpty;

  /// Obtener categorías disponibles para sugerencias
  List<TriviaCategory> get categories => _orchestrator.getCategories();

  // ==================== WIZARD NAVIGATION ====================

  /// Ir al siguiente paso
  void nextStep() {
    if (_currentStep < 2) {
      _currentStep++;
      onStepChanged?.call(_currentStep);
    }
  }

  /// Ir al paso anterior
  void previousStep() {
    if (_currentStep > 0) {
      _currentStep--;
      onStepChanged?.call(_currentStep);
    }
  }

  /// Ir a un paso específico
  void goToStep(int step) {
    if (step >= 0 && step <= 2) {
      _currentStep = step;
      onStepChanged?.call(_currentStep);
    }
  }

  // ==================== METADATA ====================

  /// Actualizar título de la trivia
  void setTitle(String newTitle) {
    _title = newTitle.trim();
    onMetadataChanged?.call();
  }

  /// Actualizar imagen de fondo
  void setBackgroundImage(File? image) {
    _backgroundImage = image;
    onMetadataChanged?.call();
  }

  // ==================== QUESTIONS MANAGEMENT ====================

  /// Agregar una nueva pregunta
  void addQuestion(TriviaQuestionDraft question) {
    if (!canAddQuestion) {
      onError?.call('No puedes agregar más de $maxQuestions preguntas');
      return;
    }

    _questions.add(question);
    onQuestionsChanged?.call(List.from(_questions));
    ReleaseLogger.log('🎯 [TriviaCreation] Pregunta agregada: ${_questions.length}/$maxQuestions');
  }

  /// Editar una pregunta existente
  void editQuestion(int index, TriviaQuestionDraft updatedQuestion) {
    if (index < 0 || index >= _questions.length) {
      onError?.call('Índice de pregunta inválido');
      return;
    }

    _questions[index] = updatedQuestion;
    onQuestionsChanged?.call(List.from(_questions));
    ReleaseLogger.log('🎯 [TriviaCreation] Pregunta $index editada');
  }

  /// Eliminar una pregunta
  void removeQuestion(int index) {
    if (index < 0 || index >= _questions.length) {
      onError?.call('Índice de pregunta inválido');
      return;
    }

    _questions.removeAt(index);
    onQuestionsChanged?.call(List.from(_questions));
    ReleaseLogger.log('🎯 [TriviaCreation] Pregunta $index eliminada');
  }

  /// Reordenar preguntas
  void reorderQuestions(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _questions.length ||
        newIndex < 0 || newIndex >= _questions.length) {
      return;
    }

    final question = _questions.removeAt(oldIndex);
    _questions.insert(newIndex, question);
    onQuestionsChanged?.call(List.from(_questions));
    ReleaseLogger.log('🎯 [TriviaCreation] Preguntas reordenadas: $oldIndex → $newIndex');
  }

  /// Obtener pregunta por índice
  TriviaQuestionDraft? getQuestion(int index) {
    if (index < 0 || index >= _questions.length) return null;
    return _questions[index];
  }

  // ==================== SUGGESTIONS ====================

  /// Generar una pregunta sugerida
  Future<void> generateSuggestion({String? categoryId}) async {
    if (_isSuggestingQuestion) return;

    try {
      _isSuggestingQuestion = true;
      onSuggestingChanged?.call(true);
      _clearError();

      ReleaseLogger.log('🎯 [TriviaCreation] Generando sugerencia...');

      final suggestion = await _orchestrator.getSuggestedQuestion(
        categoryId: categoryId,
      );

      onSuggestionReceived?.call(suggestion);
      ReleaseLogger.log('🎯 [TriviaCreation] Sugerencia recibida: ${suggestion.question}');
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaCreation] Error generando sugerencia: $e');
      _setError('Error generando sugerencia: $e');
    } finally {
      _isSuggestingQuestion = false;
      onSuggestingChanged?.call(false);
    }
  }

  /// Aplicar sugerencia como nueva pregunta
  void applySuggestion(TriviaSuggestion suggestion) {
    addQuestion(suggestion.toDraft());
  }

  // ==================== PUBLISH ====================

  /// Publicar la trivia
  Future<bool> publishTrivia() async {
    if (_isPublishing) return false;

    try {
      _setPublishing(true);
      _clearError();

      // Validaciones
      if (_title.isEmpty) {
        throw TriviaCreationException('El título es obligatorio');
      }

      if (_questions.length < minQuestions) {
        throw TriviaCreationException('Debes agregar al menos $minQuestions pregunta');
      }

      ReleaseLogger.log('🎯 [TriviaCreation] Publicando trivia: $_title con ${_questions.length} preguntas');

      final triviaId = await _orchestrator.createTrivia(
        title: _title,
        questions: _questions,
        backgroundImagePath: _backgroundImage?.path,
      );

      ReleaseLogger.log('✅ [TriviaCreation] Trivia publicada: $triviaId');
      onPublishSuccess?.call(triviaId);
      return true;
    } on TriviaCreationException catch (e) {
      ReleaseLogger.error('❌ [TriviaCreation] Error de validación: ${e.message}');
      _setError(e.message);
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaCreation] Error publicando: $e');
      _setError('Error al publicar: $e');
      return false;
    } finally {
      _setPublishing(false);
    }
  }

  // ==================== PREVIEW ====================

  /// Obtener datos de preview de la trivia
  TriviaPreview getPreview() {
    return TriviaPreview(
      title: _title,
      questionCount: _questions.length,
      questions: List.from(_questions),
      backgroundImage: _backgroundImage,
    );
  }

  // ==================== UTILITIES ====================

  void _setPublishing(bool publishing) {
    _isPublishing = publishing;
    onPublishingChanged?.call(publishing);
  }

  void _setError(String error) {
    _errorMessage = error;
    onError?.call(error);
  }

  void _clearError() {
    _errorMessage = null;
  }

  /// Limpiar estado del controller
  void reset() {
    _currentStep = 0;
    _title = '';
    _backgroundImage = null;
    _questions.clear();
    _isLoading = false;
    _isPublishing = false;
    _isSuggestingQuestion = false;
    _errorMessage = null;
  }

  void dispose() {
    reset();
  }
}

/// Preview de la trivia antes de publicar
class TriviaPreview {
  final String title;
  final int questionCount;
  final List<TriviaQuestionDraft> questions;
  final File? backgroundImage;

  TriviaPreview({
    required this.title,
    required this.questionCount,
    required this.questions,
    this.backgroundImage,
  });
}
