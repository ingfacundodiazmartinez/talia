import 'package:flutter/material.dart';

import '../../../models/trivia_question.dart';
import '../../../services/trivia/trivia_creation_service.dart';

/// Formulario para crear/editar una pregunta de trivia
class TriviaQuestionForm extends StatefulWidget {
  final TriviaQuestionDraft? initialQuestion;
  final int questionNumber;
  final VoidCallback? onCancel;
  final Function(TriviaQuestionDraft) onSave;

  const TriviaQuestionForm({
    super.key,
    this.initialQuestion,
    required this.questionNumber,
    this.onCancel,
    required this.onSave,
  });

  @override
  State<TriviaQuestionForm> createState() => _TriviaQuestionFormState();
}

class _TriviaQuestionFormState extends State<TriviaQuestionForm> {
  late final TextEditingController _questionController;
  late final List<TextEditingController> _optionControllers;
  late QuestionType _questionType;
  int _correctOptionIndex = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuestion;

    _questionController = TextEditingController(text: initial?.text ?? '');
    _questionType = initial?.type ?? QuestionType.multipleChoice;

    // Inicializar controladores de opciones
    if (initial != null && initial.optionTexts.isNotEmpty) {
      _optionControllers = initial.optionTexts
          .map((text) => TextEditingController(text: text))
          .toList();
      _correctOptionIndex = initial.correctOptionIndex;
    } else {
      _optionControllers = _questionType == QuestionType.trueFalse
          ? [
              TextEditingController(text: 'Verdadero'),
              TextEditingController(text: 'Falso'),
            ]
          : List.generate(4, (_) => TextEditingController());
    }
  }

  @override
  void dispose() {
    _questionController.dispose();
    for (final controller in _optionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onTypeChanged(QuestionType? type) {
    if (type == null || type == _questionType) return;

    setState(() {
      _questionType = type;
      _correctOptionIndex = 0;

      // Limpiar y reconstruir opciones
      for (final controller in _optionControllers) {
        controller.dispose();
      }

      if (type == QuestionType.trueFalse) {
        _optionControllers.clear();
        _optionControllers.addAll([
          TextEditingController(text: 'Verdadero'),
          TextEditingController(text: 'Falso'),
        ]);
      } else {
        _optionControllers.clear();
        _optionControllers.addAll(
          List.generate(4, (_) => TextEditingController()),
        );
      }
    });
  }

  void _saveQuestion() {
    final questionText = _questionController.text.trim();
    if (questionText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe la pregunta')),
      );
      return;
    }

    final optionTexts = _optionControllers
        .map((c) => c.text.trim())
        .toList();

    // Validar opciones
    final emptyOptions = optionTexts.where((t) => t.isEmpty).length;
    if (emptyOptions > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa todas las opciones')),
      );
      return;
    }

    final draft = TriviaQuestionDraft(
      text: questionText,
      type: _questionType,
      optionTexts: optionTexts,
      correctOptionIndex: _correctOptionIndex,
    );

    widget.onSave(draft);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF667eea), Color(0xFF764ba2)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    '${widget.questionNumber}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                widget.initialQuestion == null
                    ? 'Nueva pregunta'
                    : 'Editar pregunta',
                style: theme.textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Tipo de pregunta
          Text(
            'Tipo de pregunta',
            style: theme.textTheme.titleSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<QuestionType>(
            segments: const [
              ButtonSegment(
                value: QuestionType.multipleChoice,
                label: Text('4 opciones'),
                icon: Icon(Icons.list_rounded),
              ),
              ButtonSegment(
                value: QuestionType.trueFalse,
                label: Text('V/F'),
                icon: Icon(Icons.check_circle_outline),
              ),
            ],
            selected: {_questionType},
            onSelectionChanged: (selection) {
              _onTypeChanged(selection.first);
            },
          ),
          const SizedBox(height: 24),

          // Campo de pregunta
          TextField(
            controller: _questionController,
            decoration: InputDecoration(
              labelText: 'Pregunta',
              hintText: 'Ej: Cuál es mi comida favorita?',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              prefixIcon: const Icon(Icons.help_outline_rounded),
            ),
            maxLines: 2,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),

          // Opciones
          Text(
            'Opciones de respuesta',
            style: theme.textTheme.titleSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Toca el círculo para marcar la respuesta correcta',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),

          ..._buildOptionFields(),

          const SizedBox(height: 32),

          // Botones
          Row(
            children: [
              if (widget.onCancel != null) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                flex: widget.onCancel != null ? 1 : 2,
                child: FilledButton.icon(
                  onPressed: _saveQuestion,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    widget.initialQuestion == null ? 'Agregar' : 'Guardar',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildOptionFields() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final widgets = <Widget>[];

    for (int i = 0; i < _optionControllers.length; i++) {
      final isCorrect = i == _correctOptionIndex;
      final labels = ['A', 'B', 'C', 'D'];

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              // Radio para seleccionar correcta
              GestureDetector(
                onTap: () => setState(() => _correctOptionIndex = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isCorrect
                        ? Colors.green.withValues(alpha: isDark ? 0.3 : 0.2)
                        : colorScheme.surfaceContainerHighest,
                    border: Border.all(
                      color: isCorrect ? Colors.green : colorScheme.outline,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: isCorrect
                        ? const Icon(Icons.check, color: Colors.green, size: 20)
                        : Text(
                            labels[i],
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Campo de texto
              Expanded(
                child: TextField(
                  controller: _optionControllers[i],
                  decoration: InputDecoration(
                    hintText: 'Opción ${labels[i]}',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    filled: true,
                    fillColor: isCorrect
                        ? Colors.green.withValues(alpha: isDark ? 0.15 : 0.1)
                        : colorScheme.surfaceContainerHighest,
                  ),
                  enabled: _questionType != QuestionType.trueFalse,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return widgets;
  }
}
