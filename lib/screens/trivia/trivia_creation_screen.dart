import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../controllers/trivia_creation_controller.dart';
import '../../models/trivia_question.dart';
import '../../services/trivia/trivia_creation_service.dart';
import '../../services/trivia/trivia_suggestion_service.dart';
import 'widgets/trivia_question_form.dart';
import 'widgets/trivia_suggestion_button.dart';

/// Pantalla de creación de trivia (wizard multi-paso)
class TriviaCreationScreen extends StatefulWidget {
  const TriviaCreationScreen({super.key});

  @override
  State<TriviaCreationScreen> createState() => _TriviaCreationScreenState();
}

class _TriviaCreationScreenState extends State<TriviaCreationScreen> {
  late final TriviaCreationController _controller;
  late final TextEditingController _titleController;
  final _imagePicker = ImagePicker();

  bool _isAddingQuestion = false;
  int? _editingQuestionIndex;

  @override
  void initState() {
    super.initState();
    _controller = TriviaCreationController();
    _titleController = TextEditingController();
    _setupCallbacks();
  }

  void _setupCallbacks() {
    _controller.onStepChanged = (step) {
      if (mounted) setState(() {});
    };

    _controller.onQuestionsChanged = (questions) {
      if (mounted) setState(() {});
    };

    _controller.onPublishingChanged = (isPublishing) {
      if (mounted) setState(() {});
    };

    _controller.onSuggestingChanged = (isSuggesting) {
      if (mounted) setState(() {});
    };

    _controller.onMetadataChanged = () {
      if (mounted) setState(() {});
    };

    _controller.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red),
        );
      }
    };

    _controller.onPublishSuccess = (triviaId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trivia publicada'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, triviaId);
      }
    };

    _controller.onSuggestionReceived = (suggestion) {
      if (mounted) {
        _showSuggestionDialog(suggestion);
      }
    };
  }

  @override
  void dispose() {
    _titleController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickBackgroundImage() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1080,
      maxHeight: 1920,
    );

    if (picked != null) {
      _controller.setBackgroundImage(File(picked.path));
      setState(() {});
    }
  }

  void _showSuggestionDialog(TriviaSuggestion suggestion) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Controllers para editar la sugerencia
    final questionController = TextEditingController(text: suggestion.question);
    final optionControllers = suggestion.options
        .map((o) => TextEditingController(text: o))
        .toList();
    int selectedCorrectIndex = suggestion.correctOptionIndex;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: colorScheme.primary),
                const SizedBox(width: 8),
                const Text('Sugerencia'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Puedes editar la pregunta antes de agregarla:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Campo de pregunta editable
                  TextField(
                    controller: questionController,
                    decoration: InputDecoration(
                      labelText: 'Pregunta',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      isDense: true,
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Opciones (toca para marcar correcta):',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...List.generate(optionControllers.length, (index) {
                    final isCorrect = index == selectedCorrectIndex;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () {
                              setDialogState(() {
                                selectedCorrectIndex = index;
                              });
                            },
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isCorrect
                                    ? Colors.green.shade100
                                    : colorScheme.surfaceContainerHighest,
                                border: Border.all(
                                  color: isCorrect
                                      ? Colors.green
                                      : colorScheme.outline,
                                  width: 2,
                                ),
                              ),
                              child: isCorrect
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.green,
                                      size: 16,
                                    )
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: optionControllers[index],
                              decoration: InputDecoration(
                                hintText: 'Opción ${index + 1}',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                filled: true,
                                fillColor: isCorrect
                                    ? Colors.green.withValues(alpha: 0.1)
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  for (final c in optionControllers) {
                    c.dispose();
                  }
                  questionController.dispose();
                  Navigator.pop(context);
                },
                child: const Text('Descartar'),
              ),
              FilledButton(
                onPressed: () {
                  // Crear draft con valores editados
                  final draft = TriviaQuestionDraft(
                    text: questionController.text.trim(),
                    type: optionControllers.length == 2
                        ? QuestionType.trueFalse
                        : QuestionType.multipleChoice,
                    optionTexts:
                        optionControllers.map((c) => c.text.trim()).toList(),
                    correctOptionIndex: selectedCorrectIndex,
                  );

                  for (final c in optionControllers) {
                    c.dispose();
                  }
                  questionController.dispose();
                  Navigator.pop(context);

                  // Agregar pregunta directamente
                  _controller.addQuestion(draft);
                },
                child: const Text('Agregar pregunta'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _onWillPop() async {
    // Si no hay progreso, permitir salir directamente
    if (_controller.title.isEmpty && _controller.questionCount == 0) {
      return true;
    }

    // Mostrar diálogo de confirmación
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Salir sin guardar?'),
        content: const Text(
          'Si sales ahora, perderás todo el progreso de tu trivia.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Salir'),
          ),
        ],
      ),
    );

    return shouldExit ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Crear Trivia'),
        actions: [
          if (_controller.currentStep == 2 && _controller.canPublish)
            TextButton(
              onPressed: _controller.isPublishing
                  ? null
                  : () => _controller.publishTrivia(),
              child: _controller.isPublishing
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
                    )
                  : const Text('Publicar'),
            ),
        ],
      ),
      body: _isAddingQuestion || _editingQuestionIndex != null
          ? _buildQuestionForm()
          : _buildStepContent(),
      bottomNavigationBar: !_isAddingQuestion && _editingQuestionIndex == null
          ? _buildBottomBar()
          : null,
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_controller.currentStep) {
      case 0:
        return _buildStep1TitleAndImage();
      case 1:
        return _buildStep2Questions();
      case 2:
        return _buildStep3Preview();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildStep1TitleAndImage() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Indicador de paso
          _buildStepIndicator(),
          const SizedBox(height: 32),

          // Titulo
          Text(
            'Dale un título a tu trivia',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Este título aparecerá cuando compartas tu trivia',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _titleController,
            onChanged: _controller.setTitle,
            decoration: InputDecoration(
              hintText: 'Ej: "Cuánto me conoces?"',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              prefixIcon: const Icon(Icons.quiz_rounded),
            ),
            maxLength: 50,
            textCapitalization: TextCapitalization.sentences,
          ),

          const SizedBox(height: 32),

          // Imagen de fondo
          Text(
            'Imagen de fondo (opcional)',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Agrega una imagen personalizada para tu trivia',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),

          GestureDetector(
            onTap: _pickBackgroundImage,
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                image: _controller.backgroundImage != null
                    ? DecorationImage(
                        image: FileImage(_controller.backgroundImage!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _controller.backgroundImage == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_rounded,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Toca para agregar',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  : Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: CircleAvatar(
                          radius: 16,
                          backgroundColor: Colors.black54,
                          child: IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            color: Colors.white,
                            onPressed: () {
                              _controller.setBackgroundImage(null);
                              setState(() {});
                            },
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2Questions() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final questions = _controller.questions;

    return Column(
      children: [
        // Indicador de paso
        Padding(
          padding: const EdgeInsets.all(20),
          child: _buildStepIndicator(),
        ),

        // Header con boton de sugerencia
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Preguntas',
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    '${questions.length}/10 preguntas',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              TriviaSuggestionButton(
                isLoading: _controller.isSuggestingQuestion,
                categories: _controller.categories,
                onGenerateRandom: () => _controller.generateSuggestion(),
                onGenerateWithCategory: (categoryId) =>
                    _controller.generateSuggestion(categoryId: categoryId),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Lista de preguntas
        Expanded(
          child: questions.isEmpty
              ? _buildEmptyQuestionsState()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: questions.length,
                  onReorder: _controller.reorderQuestions,
                  itemBuilder: (context, index) {
                    return _buildQuestionCard(
                      key: ValueKey(index),
                      question: questions[index],
                      index: index,
                    );
                  },
                ),
        ),

        // Boton agregar pregunta
        if (_controller.canAddQuestion)
          Padding(
            padding: const EdgeInsets.all(20),
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _isAddingQuestion = true),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Agregar pregunta manual'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyQuestionsState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.quiz_rounded,
            size: 64,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Aún no tienes preguntas',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Agrega preguntas manualmente o\nusa el botón "Sugerir pregunta"',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionCard({
    required Key key,
    required TriviaQuestionDraft question,
    required int index,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        title: Text(
          question.text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          question.type == QuestionType.trueFalse
              ? 'Verdadero/Falso'
              : '${question.optionTexts.length} opciones',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => setState(() => _editingQuestionIndex = index),
            ),
            IconButton(
              icon: const Icon(Icons.delete_rounded),
              color: colorScheme.error,
              onPressed: () => _confirmDeleteQuestion(index),
            ),
            ReorderableDragStartListener(
              index: index,
              child: Icon(
                Icons.drag_handle_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteQuestion(int index) {
    final colorScheme = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar pregunta'),
        content: const Text('Esta acción no se puede deshacer.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _controller.removeQuestion(index);
            },
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  Widget _buildStep3Preview() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final preview = _controller.getPreview();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Indicador de paso
          _buildStepIndicator(),
          const SizedBox(height: 32),

          Text(
            'Vista previa',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 16),

          // Card de preview
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: colorScheme.primaryContainer,
              boxShadow: [
                BoxShadow(
                  color: colorScheme.shadow.withValues(alpha: 0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              children: [
                if (preview.backgroundImage != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(
                      preview.backgroundImage!,
                      width: double.infinity,
                      height: 200,
                      fit: BoxFit.cover,
                    ),
                  ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: preview.backgroundImage != null
                        ? LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.3),
                              Colors.black.withValues(alpha: 0.7),
                            ],
                          )
                        : null,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.quiz_rounded,
                        color: preview.backgroundImage != null
                            ? Colors.white
                            : colorScheme.onPrimaryContainer,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        preview.title.isNotEmpty ? preview.title : 'Sin título',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: preview.backgroundImage != null
                              ? Colors.white
                              : colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${preview.questionCount} preguntas',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: preview.backgroundImage != null
                              ? Colors.white70
                              : colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Resumen de preguntas
          Text(
            'Resumen de preguntas',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),

          ...preview.questions.asMap().entries.map((entry) {
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: colorScheme.primary,
                  child: Text(
                    '${entry.key + 1}',
                    style: TextStyle(color: colorScheme.onPrimary),
                  ),
                ),
                title: Text(
                  entry.value.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'Correcta: ${entry.value.optionTexts[entry.value.correctOptionIndex]}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.green),
                ),
              ),
            );
          }),

          if (!_controller.canPublish) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_rounded,
                    color: colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Necesitas al menos 1 pregunta y un título para publicar',
                      style: TextStyle(color: colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuestionForm() {
    final isEditing = _editingQuestionIndex != null;
    final initialQuestion =
        isEditing ? _controller.getQuestion(_editingQuestionIndex!) : null;
    final questionNumber =
        isEditing ? _editingQuestionIndex! + 1 : _controller.questionCount + 1;

    return TriviaQuestionForm(
      initialQuestion: initialQuestion,
      questionNumber: questionNumber,
      onCancel: () {
        setState(() {
          _isAddingQuestion = false;
          _editingQuestionIndex = null;
        });
      },
      onSave: (draft) {
        if (isEditing) {
          _controller.editQuestion(_editingQuestionIndex!, draft);
        } else {
          _controller.addQuestion(draft);
        }
        setState(() {
          _isAddingQuestion = false;
          _editingQuestionIndex = null;
        });
      },
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      children: [
        _buildStepDot(0, 'Título'),
        _buildStepLine(0),
        _buildStepDot(1, 'Preguntas'),
        _buildStepLine(1),
        _buildStepDot(2, 'Preview'),
      ],
    );
  }

  Widget _buildStepDot(int step, String label) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isActive = _controller.currentStep >= step;
    final isCurrent = _controller.currentStep == step;

    return Expanded(
      child: Column(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? colorScheme.primary : colorScheme.surfaceContainerHighest,
              border: isCurrent
                  ? Border.all(
                      color: colorScheme.primary,
                      width: 3,
                    )
                  : null,
            ),
            child: Center(
              child: isActive && !isCurrent
                  ? Icon(Icons.check, color: colorScheme.onPrimary, size: 18)
                  : Text(
                      '${step + 1}',
                      style: TextStyle(
                        color: isActive
                            ? colorScheme.onPrimary
                            : colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: isActive ? colorScheme.primary : colorScheme.onSurfaceVariant,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepLine(int step) {
    final colorScheme = Theme.of(context).colorScheme;
    final isCompleted = _controller.currentStep > step;

    return Container(
      width: 40,
      height: 3,
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: isCompleted ? colorScheme.primary : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (_controller.currentStep > 0)
              Expanded(
                child: OutlinedButton(
                  onPressed: _controller.previousStep,
                  child: const Text('Anterior'),
                ),
              ),
            if (_controller.currentStep > 0) const SizedBox(width: 12),
            Expanded(
              flex: _controller.currentStep == 0 ? 2 : 1,
              child: FilledButton(
                onPressed: _canContinue() ? _onContinue : null,
                child: Text(
                  _controller.currentStep == 2 ? 'Publicar' : 'Siguiente',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canContinue() {
    switch (_controller.currentStep) {
      case 0:
        return _controller.title.isNotEmpty;
      case 1:
        return _controller.questionCount >= 1;
      case 2:
        return _controller.canPublish && !_controller.isPublishing;
      default:
        return false;
    }
  }

  void _onContinue() {
    if (_controller.currentStep == 2) {
      _controller.publishTrivia();
    } else {
      _controller.nextStep();
    }
  }
}
