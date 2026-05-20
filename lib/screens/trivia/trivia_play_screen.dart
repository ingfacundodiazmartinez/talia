import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../controllers/trivia_play_controller.dart';
import '../../models/trivia_question.dart';
import '../../services/trivia/trivia_participation_service.dart';
import 'trivia_completion_screen.dart';
import 'widgets/trivia_question_widget.dart';
import 'widgets/trivia_timer_widget.dart';

/// Pantalla para jugar/responder una trivia
class TriviaPlayScreen extends StatefulWidget {
  final String triviaId;

  const TriviaPlayScreen({
    super.key,
    required this.triviaId,
  });

  @override
  State<TriviaPlayScreen> createState() => _TriviaPlayScreenState();
}

class _TriviaPlayScreenState extends State<TriviaPlayScreen>
    with WidgetsBindingObserver {
  late final TriviaPlayController _controller;
  String? _selectedOptionId;
  List<TriviaOption>? _shuffledOptions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = TriviaPlayController();
    _setupCallbacks();
    _controller.startTrivia(widget.triviaId);
  }

  void _setupCallbacks() {
    _controller.onStateChanged = (state) {
      if (mounted) setState(() {});
    };

    _controller.onQuestionChanged = (index) {
      if (mounted) {
        final question = _controller.currentQuestion;
        if (question != null) {
          final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
          setState(() {
            _selectedOptionId = null;
            _shuffledOptions = question.getShuffledOptions(userId);
          });
        }
      }
    };

    _controller.onTimerTick = (remainingMs) {
      if (mounted) setState(() {});
    };

    _controller.onAnswerResult = (result) {
      if (mounted) setState(() {});
    };

    _controller.onTriviaCompleted = (response) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => TriviaCompletionScreen(
              triviaId: widget.triviaId,
              response: response,
            ),
          ),
        );
      }
    };

    _controller.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red),
        );
      }
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Guardar progreso si la app pasa a segundo plano
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controller.saveAndExit();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    if (_controller.state == TriviaPlayState.playing ||
        _controller.state == TriviaPlayState.showingResult) {
      final shouldExit = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Abandonar trivia?'),
          content: const Text(
            'Si sales ahora, se guardará tu progreso parcial pero no podrás continuar después.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Continuar jugando'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Salir'),
            ),
          ],
        ),
      );

      if (shouldExit == true) {
        await _controller.saveAndExit();
        return true;
      }
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_controller.state) {
      case TriviaPlayState.loading:
        return _buildLoadingState();
      case TriviaPlayState.ready:
        return _buildReadyState();
      case TriviaPlayState.playing:
      case TriviaPlayState.answering:
      case TriviaPlayState.showingResult:
        return _buildPlayingState();
      case TriviaPlayState.completed:
        return _buildCompletedState();
      case TriviaPlayState.error:
        return _buildErrorState();
    }
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Cargando trivia...'),
        ],
      ),
    );
  }

  Widget _buildReadyState() {
    final trivia = _controller.trivia;
    if (trivia == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Stack(
      children: [
        // Botón de cerrar
        Positioned(
          top: 8,
          right: 8,
          child: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            style: IconButton.styleFrom(
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          ),
        ),

        // Contenido principal
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icono de trivia
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [colorScheme.primary, colorScheme.secondary],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.quiz_rounded,
                  color: Colors.white,
                  size: 64,
                ),
              ),
              const SizedBox(height: 32),

              // Título
              Text(
                trivia.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Creador
              Text(
                'Creada por ${trivia.creatorName}',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),

              // Info
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _InfoItem(
                      icon: Icons.help_outline_rounded,
                      label: '${_controller.totalQuestions}',
                      sublabel: 'Preguntas',
                    ),
                    _InfoItem(
                      icon: Icons.timer_outlined,
                      label: '30',
                      sublabel: 'Seg/pregunta',
                    ),
                    _InfoItem(
                      icon: Icons.stars_rounded,
                      label: '${_controller.totalQuestions * 150}',
                      sublabel: 'Pts máx',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Instrucciones
              Text(
                'Responde las preguntas lo más rápido posible.\n'
                '¡Ganas más puntos por velocidad!',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              // Botón comenzar
              FilledButton.icon(
                onPressed: _controller.beginPlaying,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Comenzar'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(200, 56),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlayingState() {
    final question = _controller.currentQuestion;
    if (question == null || _shuffledOptions == null) {
      return const SizedBox.shrink();
    }

    final isShowingResult = _controller.state == TriviaPlayState.showingResult;
    final lastResult = _controller.lastResult;
    final colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        // Contenido principal
        Column(
          children: [
            // Header con progreso y timer
            _buildHeader(colorScheme),

            // Pregunta y opciones
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                child: TriviaQuestionWidget(
                  question: question,
                  shuffledOptions: _shuffledOptions!,
                  selectedOptionId:
                      _selectedOptionId ?? _controller.selectedOptionId,
                  correctOptionId:
                      isShowingResult ? lastResult?.correctOptionId : null,
                  showResult: isShowingResult,
                  isAnswering: _controller.state == TriviaPlayState.answering,
                  onOptionSelected: isShowingResult
                      ? null
                      : (optionId) {
                          setState(() => _selectedOptionId = optionId);
                        },
                ),
              ),
            ),
          ],
        ),

        // Botón responder (fijo abajo)
        if (!isShowingResult)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0),
                    Theme.of(context).scaffoldBackgroundColor,
                  ],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: _selectedOptionId != null
                        ? () => _controller.submitAnswer(_selectedOptionId!)
                        : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 56),
                      backgroundColor: const Color(0xFF667eea),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _controller.state == TriviaPlayState.answering
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Responder',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),

        // Overlay de resultado
        if (isShowingResult && lastResult != null)
          _buildResultOverlay(lastResult, colorScheme),
      ],
    );
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      child: Row(
        children: [
          // Botón cerrar
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 28),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && context.mounted) {
                // ignore: use_build_context_synchronously
                Navigator.pop(context);
              }
            },
          ),

          // Progreso central
          Expanded(
            child: Column(
              children: [
                Text(
                  'Pregunta ${_controller.currentQuestionIndex + 1} de ${_controller.totalQuestions}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _controller.progress,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF667eea),
                    ),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 6),
                // Puntuación
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.stars_rounded,
                        color: Color(0xFF667eea), size: 18),
                    const SizedBox(width: 4),
                    Text(
                      '${_controller.totalScore} pts',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF667eea),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Timer
          TriviaTimerWidget(
            remainingMs: _controller.remainingTimeMs,
            totalMs: 30000,
            size: 56,
          ),
        ],
      ),
    );
  }

  Widget _buildResultOverlay(QuestionResult result, ColorScheme colorScheme) {
    final isCorrect = result.isCorrect;
    final backgroundColor = isCorrect ? Colors.green : Colors.red;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: Colors.black54,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.8, end: 1.0),
          duration: const Duration(milliseconds: 400),
          curve: Curves.elasticOut,
          builder: (context, scale, child) {
            return Transform.scale(scale: scale, child: child);
          },
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: backgroundColor.withValues(alpha: 0.3),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icono animado
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: backgroundColor.withValues(alpha: 0.15),
                    border: Border.all(color: backgroundColor, width: 4),
                  ),
                  child: Icon(
                    isCorrect
                        ? Icons.check_rounded
                        : Icons.close_rounded,
                    size: 60,
                    color: backgroundColor,
                  ),
                ),
                const SizedBox(height: 24),

                // Mensaje
                Text(
                  isCorrect ? '¡Correcto!' : 'Incorrecto',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: backgroundColor,
                  ),
                ),
                const SizedBox(height: 8),

                // Puntos
                if (result.pointsEarned > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.stars_rounded,
                            color: Colors.amber, size: 24),
                        const SizedBox(width: 8),
                        Text(
                          '+${result.pointsEarned} pts',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Respuesta correcta si falló
                if (!isCorrect && _shuffledOptions != null) ...[
                  Text(
                    'La respuesta correcta era:',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      _shuffledOptions!
                          .firstWhere((o) => o.id == result.correctOptionId)
                          .text,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.green,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Botón continuar
                FilledButton(
                  onPressed: _controller.nextQuestion,
                  style: FilledButton.styleFrom(
                    backgroundColor: backgroundColor,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(200, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _controller.isLastQuestion ? 'Ver resultados' : 'Siguiente',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompletedState() {
    // Este estado normalmente redirige a TriviaCompletionScreen
    return const Center(
      child: CircularProgressIndicator(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 80,
              color: Colors.red.shade300,
            ),
            const SizedBox(height: 24),
            Text(
              _controller.errorMessage ?? 'Error al cargar la trivia',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Volver'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;

  const _InfoItem({
    required this.icon,
    required this.label,
    required this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Icon(icon, color: colorScheme.primary),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          sublabel,
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
