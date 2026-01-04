import 'package:flutter/material.dart';

import '../../models/trivia_response.dart';
import '../../services/trivia/trivia_orchestrator.dart';
import 'trivia_results_screen.dart';

/// Pantalla mostrada al completar una trivia (resultado personal)
class TriviaCompletionScreen extends StatefulWidget {
  final String triviaId;
  final TriviaResponse response;

  const TriviaCompletionScreen({
    super.key,
    required this.triviaId,
    required this.response,
  });

  @override
  State<TriviaCompletionScreen> createState() => _TriviaCompletionScreenState();
}

class _TriviaCompletionScreenState extends State<TriviaCompletionScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.elasticOut,
      ),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  String _getResultEmoji() {
    final accuracy = widget.response.accuracy;
    if (accuracy >= 0.9) return '🏆';
    if (accuracy >= 0.7) return '🥳';
    if (accuracy >= 0.5) return '😊';
    if (accuracy >= 0.3) return '😅';
    return '💪';
  }

  String _getResultMessage() {
    final accuracy = widget.response.accuracy;
    if (accuracy >= 0.9) return '¡Excelente!';
    if (accuracy >= 0.7) return '¡Muy bien!';
    if (accuracy >= 0.5) return '¡Bien hecho!';
    if (accuracy >= 0.3) return '¡Sigue intentando!';
    return '¡No te rindas!';
  }

  String _getResultSubtitle() {
    final accuracy = widget.response.accuracy;
    if (accuracy >= 0.9) return 'Eres un experto';
    if (accuracy >= 0.7) return 'Gran conocimiento';
    if (accuracy >= 0.5) return 'Buen intento';
    if (accuracy >= 0.3) return 'Puedes mejorar';
    return 'La próxima será mejor';
  }

  Color _getAccentColor() {
    final accuracy = widget.response.accuracy;
    if (accuracy >= 0.7) return const Color(0xFF4CAF50);
    if (accuracy >= 0.5) return const Color(0xFFFF9800);
    return const Color(0xFFE91E63);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = _getAccentColor();

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    const Color(0xFF1a1a2e),
                    const Color(0xFF16213e),
                  ]
                : [
                    const Color(0xFFF8F9FA),
                    Colors.white,
                  ],
          ),
        ),
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    const SizedBox(height: 40),

                    // Emoji animado
                    Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accentColor.withValues(alpha: 0.1),
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.2),
                              blurRadius: 30,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            _getResultEmoji(),
                            style: const TextStyle(fontSize: 64),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Mensaje principal
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: Column(
                        children: [
                          Text(
                            _getResultMessage(),
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _getResultSubtitle(),
                            style: TextStyle(
                              fontSize: 16,
                              color: isDark
                                  ? Colors.white60
                                  : Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),

                    // Card de puntuación
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: _buildScoreCard(isDark),
                    ),

                    const Spacer(),

                    // Botones de acción
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: _buildActionButtons(context, isDark),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildScoreCard(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF667eea),
            Color(0xFF764ba2),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF667eea).withValues(alpha: 0.35),
            blurRadius: 25,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          // Puntuación principal
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withValues(alpha: 0.4),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.stars_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Text(
                '${widget.response.totalScore}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  'pts',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),

          // Divider decorativo
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 0),
                  Colors.white.withValues(alpha: 0.3),
                  Colors.white.withValues(alpha: 0),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Estadísticas
          Row(
            children: [
              Expanded(
                child: _StatItem(
                  icon: Icons.check_circle_rounded,
                  value:
                      '${widget.response.correctCount}/${widget.response.totalQuestions}',
                  label: 'Correctas',
                ),
              ),
              Container(
                width: 1,
                height: 50,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.percent_rounded,
                  value: '${(widget.response.accuracy * 100).round()}%',
                  label: 'Precisión',
                ),
              ),
              Container(
                width: 1,
                height: 50,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.timer_rounded,
                  value: _formatTime(widget.response.timeSpentSeconds),
                  label: 'Tiempo',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, bool isDark) {
    return Column(
      children: [
        // Botón principal - Ver ranking
        Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF667eea), Color(0xFF764ba2)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF667eea).withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TriviaResultsScreen(
                      triviaId: widget.triviaId,
                      isCreator: false,
                    ),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(16),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.leaderboard_rounded, color: Colors.white, size: 22),
                  SizedBox(width: 10),
                  Text(
                    'Ver ranking',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 14),

        // Botón secundario - Invitar amigos
        Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF667eea).withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                final url =
                    TriviaOrchestrator().generateTriviaUrl(widget.triviaId);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Compartir: $url')),
                );
              },
              borderRadius: BorderRadius.circular(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.share_rounded,
                    color: const Color(0xFF667eea),
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Invitar amigos',
                    style: TextStyle(
                      color: const Color(0xFF667eea),
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Botón terciario - Volver
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: Text(
            'Volver al inicio',
            style: TextStyle(
              color: isDark ? Colors.white60 : Colors.grey.shade600,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  String _formatTime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes}m ${remainingSeconds}s';
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatItem({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.8), size: 22),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
