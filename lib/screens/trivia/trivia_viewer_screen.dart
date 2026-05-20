import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../models/trivia.dart';
import '../../models/trivia_question.dart';
import '../../models/trivia_response.dart';
import '../../services/trivia/trivia_orchestrator.dart';
import '../../services/trivia/trivia_participation_service.dart';
import '../../services/ad_service.dart';
import '../../widgets/story_native_ad_widget.dart';
import 'trivia_results_screen.dart';
import 'widgets/trivia_question_widget.dart';
import 'widgets/trivia_timer_widget.dart';

/// Modo de visualización de la trivia
enum TriviaViewMode {
  preview, // Vista previa (comportamiento de historia)
  playing, // Jugando (interactivo, sin timer de historia)
  results, // Mostrando resultados
}

/// Pantalla tipo historia para ver trivias
/// Comportamiento similar al story viewer: timer, tap navigation, ads
class TriviaViewerScreen extends StatefulWidget {
  final List<Trivia> trivias;
  final int initialIndex;

  const TriviaViewerScreen({
    super.key,
    required this.trivias,
    this.initialIndex = 0,
  });

  @override
  State<TriviaViewerScreen> createState() => _TriviaViewerScreenState();
}

class _TriviaViewerScreenState extends State<TriviaViewerScreen>
    with TickerProviderStateMixin {
  late PageController _pageController;
  late AnimationController _progressController;

  int _currentIndex = 0;
  TriviaViewMode _viewMode = TriviaViewMode.preview;
  Timer? _autoAdvanceTimer;

  final Duration _previewDuration = const Duration(seconds: 8);
  final TriviaOrchestrator _orchestrator = TriviaOrchestrator();
  final AdService _adService = AdService();

  // Cache de respuestas del usuario
  final Map<String, TriviaResponse?> _userResponses = {};
  final Map<String, TriviaEligibility> _eligibilities = {};

  // Estado de juego inline
  TriviaStartResult? _playingTriviaData;
  int _currentQuestionIndex = 0;
  String? _selectedOptionId;
  List<TriviaOption>? _shuffledOptions;
  int _totalScore = 0;
  QuestionResult? _lastResult;
  bool _isShowingResult = false;
  int _remainingTimeMs = 30000;
  Timer? _questionTimer;

  // Ads
  int _triviasViewed = 0;
  bool _isAdLoaded = false;

  String? get _currentUserId => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _progressController = AnimationController(
      vsync: this,
      duration: _previewDuration,
    );

    _loadUserResponses();
    _loadAd();
    _startPreviewTimer();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _progressController.dispose();
    _autoAdvanceTimer?.cancel();
    _questionTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserResponses() async {
    final userId = _currentUserId;
    if (userId == null) return;

    for (final trivia in widget.trivias) {
      final response = await TriviaResponse.getByUserAndTrivia(userId, trivia.id);
      final eligibility = await _orchestrator.checkEligibility(trivia.id);
      if (mounted) {
        setState(() {
          _userResponses[trivia.id] = response;
          _eligibilities[trivia.id] = eligibility;
        });
      }
    }
  }

  void _loadAd() async {
    // Pre-cargar Native Ad para mostrar entre trivias
    await _adService.preloadStoryNativeAd();
    if (mounted && _adService.isNativeAdReady) {
      setState(() => _isAdLoaded = true);
    }
  }

  void _startPreviewTimer() {
    _autoAdvanceTimer?.cancel();
    _progressController.reset();

    if (_viewMode != TriviaViewMode.preview) return;

    _progressController.forward();
    _autoAdvanceTimer = Timer(_previewDuration, _goToNext);
  }

  void _pausePreviewTimer() {
    _autoAdvanceTimer?.cancel();
    _progressController.stop();
  }

  void _resumePreviewTimer() {
    if (_viewMode != TriviaViewMode.preview) return;

    final remaining = _previewDuration * (1 - _progressController.value);
    _progressController.forward();
    _autoAdvanceTimer = Timer(remaining, _goToNext);
  }

  void _goToNext() {
    _triviasViewed++;

    // Mostrar ad cada 3 trivias
    if (_triviasViewed % 3 == 0 && _isAdLoaded) {
      _showAd();
      return;
    }

    if (_currentIndex < widget.trivias.length - 1) {
      setState(() {
        _currentIndex++;
        _viewMode = TriviaViewMode.preview;
        _resetPlayState();
      });
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startPreviewTimer();
    } else {
      Navigator.pop(context);
    }
  }

  void _goToPrevious() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _viewMode = TriviaViewMode.preview;
        _resetPlayState();
      });
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startPreviewTimer();
    }
  }

  Future<void> _showAd() async {
    _pausePreviewTimer();

    final ad = _adService.consumeCachedNativeAd();
    if (ad != null && mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Dialog(
          insetPadding: EdgeInsets.zero,
          child: StoryNativeAdWidget(
            nativeAd: ad,
            onAdCompleted: () => Navigator.pop(context),
          ),
        ),
      );
    }

    _loadAd(); // Pre-cargar siguiente
    _goToNext();
  }

  void _resetPlayState() {
    _playingTriviaData = null;
    _currentQuestionIndex = 0;
    _selectedOptionId = null;
    _shuffledOptions = null;
    _totalScore = 0;
    _lastResult = null;
    _isShowingResult = false;
    _questionTimer?.cancel();
  }

  void _handleTap(TapUpDetails details, BuildContext context) {
    if (_viewMode == TriviaViewMode.playing) return; // No tap navigation cuando juega

    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < screenWidth / 3) {
      _goToPrevious();
    } else if (tapX > screenWidth * 2 / 3) {
      _goToNext();
    } else {
      // Centro: pausar/reanudar
      if (_progressController.isAnimating) {
        _pausePreviewTimer();
      } else {
        _resumePreviewTimer();
      }
    }
  }

  Future<void> _startPlaying() async {
    final trivia = widget.trivias[_currentIndex];

    _pausePreviewTimer();
    setState(() => _viewMode = TriviaViewMode.playing);

    try {
      final result = await _orchestrator.startTrivia(trivia.id);
      if (mounted) {
        setState(() {
          _playingTriviaData = result;
          _currentQuestionIndex = result.response.answeredCount;
          _loadCurrentQuestion();
        });
        _startQuestionTimer();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
        setState(() => _viewMode = TriviaViewMode.preview);
        _startPreviewTimer();
      }
    }
  }

  void _loadCurrentQuestion() {
    if (_playingTriviaData == null) return;

    final question = _playingTriviaData!.questions[_currentQuestionIndex];
    final oderId = _currentUserId ?? '';
    _shuffledOptions = question.getShuffledOptions(oderId);
    _selectedOptionId = null;
  }

  void _startQuestionTimer() {
    _questionTimer?.cancel();
    _remainingTimeMs = 30000;

    _questionTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_remainingTimeMs <= 0) {
        timer.cancel();
        _submitAnswer(timeout: true);
      } else if (mounted && !_isShowingResult) {
        setState(() => _remainingTimeMs -= 100);
      }
    });
  }

  Future<void> _submitAnswer({bool timeout = false}) async {
    if (_playingTriviaData == null) return;

    _questionTimer?.cancel();
    final question = _playingTriviaData!.questions[_currentQuestionIndex];

    try {
      final result = await _orchestrator.submitAnswer(
        triviaId: _playingTriviaData!.trivia.id,
        questionId: question.id,
        selectedOptionId: timeout ? '' : (_selectedOptionId ?? ''),
        responseTimeMs: 30000 - _remainingTimeMs,
      );

      if (mounted) {
        setState(() {
          _lastResult = result;
          _totalScore = result.totalScore;
          _isShowingResult = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _nextQuestion() async {
    if (_playingTriviaData == null) return;

    final isLast =
        _currentQuestionIndex >= _playingTriviaData!.questions.length - 1;

    if (isLast) {
      // Completar trivia
      await _orchestrator.completeTrivia(_playingTriviaData!.trivia.id);

      if (mounted) {
        setState(() {
          _viewMode = TriviaViewMode.results;
          _isShowingResult = false;
        });

        // Auto-avanzar después de 5 segundos mostrando resultados
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _viewMode == TriviaViewMode.results) {
            _goToNext();
          }
        });
      }
    } else {
      setState(() {
        _currentQuestionIndex++;
        _isShowingResult = false;
        _loadCurrentQuestion();
      });
      _startQuestionTimer();
    }
  }

  void _viewResults() {
    final trivia = widget.trivias[_currentIndex];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TriviaResultsScreen(
          triviaId: trivia.id,
          isCreator: trivia.creatorId == _currentUserId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (details) => _handleTap(details, context),
        onVerticalDragEnd: (details) {
          // Swipe down para cerrar
          if (details.primaryVelocity != null &&
              details.primaryVelocity! > 300) {
            Navigator.pop(context);
          }
        },
        child: Stack(
          children: [
            // Contenido principal
            PageView.builder(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.trivias.length,
              itemBuilder: (context, index) {
                final trivia = widget.trivias[index];
                return _buildTriviaContent(trivia);
              },
            ),

            // Progress indicators
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    // Progress bars
                    Row(
                      children: List.generate(widget.trivias.length, (index) {
                        return Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            height: 3,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: Colors.white.withValues(alpha: 0.3),
                            ),
                            child: AnimatedBuilder(
                              animation: _progressController,
                              builder: (context, child) {
                                double value;
                                if (index < _currentIndex) {
                                  value = 1.0;
                                } else if (index == _currentIndex &&
                                    _viewMode == TriviaViewMode.preview) {
                                  value = _progressController.value;
                                } else {
                                  value = 0.0;
                                }
                                return FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: value,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(2),
                                      color: Colors.white,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      }),
                    ),

                    const SizedBox(height: 12),

                    // Header
                    _buildHeader(),
                  ],
                ),
              ),
            ),

            // Botón cerrar
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final trivia = widget.trivias[_currentIndex];

    return Row(
      children: [
        // Avatar
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: ClipOval(
            child: trivia.creatorPhotoURL != null
                ? CachedNetworkImage(
                    imageUrl: trivia.creatorPhotoURL!,
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: const Color(0xFF667eea),
                    child: Center(
                      child: Text(
                        trivia.creatorName.isNotEmpty
                            ? trivia.creatorName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trivia.creatorName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              Text(
                _getTimeAgo(trivia.createdAt),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTriviaContent(Trivia trivia) {
    switch (_viewMode) {
      case TriviaViewMode.preview:
        return _buildPreview(trivia);
      case TriviaViewMode.playing:
        return _buildPlaying(trivia);
      case TriviaViewMode.results:
        return _buildResults(trivia);
    }
  }

  Widget _buildPreview(Trivia trivia) {
    final isCreator = trivia.creatorId == _currentUserId;
    final response = _userResponses[trivia.id];
    final eligibility = _eligibilities[trivia.id];

    final canPlay = eligibility == TriviaEligibility.canParticipate ||
        eligibility == TriviaEligibility.canContinue;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60), // Espacio para header

            const Spacer(),

            // Icono
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.quiz_rounded, size: 50, color: Colors.white),
            ),

            const SizedBox(height: 24),

            // Título
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                trivia.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            const SizedBox(height: 16),

            // Info chips
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildChip(Icons.help_outline, '${trivia.questionIds.length} preguntas'),
                const SizedBox(width: 12),
                _buildChip(Icons.people_outline, '${trivia.participantCount}'),
              ],
            ),

            const Spacer(),

            // Botón de acción
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: canPlay
                  ? _buildPlayButton()
                  : _buildResultsButton(),
            ),

            const SizedBox(height: 16),

            // Status
            if (isCreator)
              _buildStatusText('No puedes responder tu propia trivia')
            else if (response != null &&
                response.status != ResponseStatus.inProgress)
              _buildStatusText('Ya respondiste esta trivia')
            else if (!trivia.isActive)
              _buildStatusText('Esta trivia ha finalizado'),

            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaying(Trivia trivia) {
    if (_playingTriviaData == null || _shuffledOptions == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    final question = _playingTriviaData!.questions[_currentQuestionIndex];

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            // Header de juego
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'Pregunta ${_currentQuestionIndex + 1} de ${_playingTriviaData!.questions.length}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: (_currentQuestionIndex + 1) /
                                _playingTriviaData!.questions.length,
                            backgroundColor: Colors.grey.shade300,
                            valueColor: const AlwaysStoppedAnimation(Color(0xFF667eea)),
                            minHeight: 5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.stars_rounded,
                                color: Color(0xFF667eea), size: 18),
                            const SizedBox(width: 4),
                            Text(
                              '$_totalScore pts',
                              style: const TextStyle(
                                color: Color(0xFF667eea),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  TriviaTimerWidget(
                    remainingMs: _remainingTimeMs,
                    totalMs: 30000,
                    size: 56,
                  ),
                ],
              ),
            ),

            // Pregunta y opciones
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                child: TriviaQuestionWidget(
                  question: question,
                  shuffledOptions: _shuffledOptions!,
                  selectedOptionId: _selectedOptionId,
                  correctOptionId: _isShowingResult ? _lastResult?.correctOptionId : null,
                  showResult: _isShowingResult,
                  isAnswering: false,
                  onOptionSelected: _isShowingResult
                      ? null
                      : (id) => setState(() => _selectedOptionId = id),
                ),
              ),
            ),

            // Botón de acción
            if (!_isShowingResult)
              _buildAnswerButton()
            else
              _buildNextButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(Trivia trivia) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white, size: 80),
              const SizedBox(height: 24),
              const Text(
                '¡Trivia completada!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.stars_rounded, color: Colors.amber, size: 28),
                    const SizedBox(width: 8),
                    Text(
                      '$_totalScore pts',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: _viewResults,
                child: const Text(
                  'Ver ranking completo',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    return GestureDetector(
      onTap: _startPlaying,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_arrow_rounded, color: Color(0xFF667eea), size: 28),
            SizedBox(width: 8),
            Text(
              'Jugar',
              style: TextStyle(
                color: Color(0xFF667eea),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsButton() {
    return GestureDetector(
      onTap: _viewResults,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.leaderboard_rounded, color: Colors.white, size: 24),
            SizedBox(width: 8),
            Text(
              'Ver resultados',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusText(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Text(
        text,
        style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildAnswerButton() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: FilledButton(
        onPressed: _selectedOptionId != null ? () => _submitAnswer() : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 56),
          backgroundColor: const Color(0xFF667eea),
        ),
        child: const Text('Responder', style: TextStyle(fontSize: 17)),
      ),
    );
  }

  Widget _buildNextButton() {
    final isLast = _currentQuestionIndex >=
        (_playingTriviaData?.questions.length ?? 1) - 1;

    return Container(
      padding: const EdgeInsets.all(16),
      child: FilledButton(
        onPressed: _nextQuestion,
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 56),
          backgroundColor:
              _lastResult?.isCorrect == true ? Colors.green : Colors.red,
        ),
        child: Text(
          isLast ? 'Ver resultados' : 'Siguiente',
          style: const TextStyle(fontSize: 17),
        ),
      ),
    );
  }

  String _getTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes}m';
    if (diff.inHours < 24) return 'hace ${diff.inHours}h';
    return 'hace ${diff.inDays}d';
  }
}
