import 'package:flutter/material.dart';
import '../models/mood_poll.dart';
import '../services/mood_polls/mood_poll_service.dart';

/// Widget de encuesta de mood que se muestra entre stories
///
/// Diseño moderno con emojis grandes y animaciones.
class MoodPollStoryWidget extends StatefulWidget {
  final MoodPollQuestion question;
  final VoidCallback onSkip;
  final Function(MoodPollResponse response) onAnswered;
  final VoidCallback? onClose;
  final VoidCallback? onShareAsStory;

  const MoodPollStoryWidget({
    super.key,
    required this.question,
    required this.onSkip,
    required this.onAnswered,
    this.onClose,
    this.onShareAsStory,
  });

  @override
  State<MoodPollStoryWidget> createState() => _MoodPollStoryWidgetState();
}

class _MoodPollStoryWidgetState extends State<MoodPollStoryWidget>
    with SingleTickerProviderStateMixin {
  final MoodPollService _pollService = MoodPollService();
  MoodPollOption? _selectedOption;
  bool _isSubmitting = false;
  bool _showShareOption = false;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutBack,
      ),
    );
    _animationController.forward();

    // Registrar que se mostró la encuesta
    _pollService.recordPollShown(widget.question.id);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _selectOption(MoodPollOption option) async {
    if (_isSubmitting || _selectedOption != null) return;

    setState(() {
      _selectedOption = option;
      _isSubmitting = true;
    });

    try {
      final response = await _pollService.submitResponse(
        question: widget.question,
        selectedOption: option,
      );

      setState(() {
        _isSubmitting = false;
        _showShareOption = true;
      });

      await Future.delayed(const Duration(milliseconds: 300));
      widget.onAnswered(response);
    } catch (e) {
      setState(() {
        _isSubmitting = false;
        _selectedOption = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF667eea),
                Color(0xFF764ba2),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF667eea).withValues(alpha: 0.4),
                blurRadius: 30,
                offset: const Offset(0, 15),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              children: [
                // Patrón de fondo decorativo
                Positioned(
                  top: -50,
                  right: -50,
                  child: Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                Positioned(
                  bottom: -30,
                  left: -30,
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),

                // Contenido scrolleable
                SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header
                      _buildHeader(),
                      const SizedBox(height: 20),

                      // Pregunta
                      Text(
                        widget.question.text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.3,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Opciones o sección de compartir
                      if (!_showShareOption) _buildOptionsList(),
                      if (_showShareOption) _buildShareSection(),

                      const SizedBox(height: 16),

                      // Botón de saltar
                      if (!_showShareOption)
                        TextButton(
                          onPressed: widget.onSkip,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                          ),
                          child: Text(
                            'Ahora no',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.psychology_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          '¿Cómo te sentís?',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white70,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildOptionsList() {
    final options = widget.question.options;

    return Column(
      children: options.map((option) {
        final isSelected = _selectedOption?.id == option.id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildOptionRow(option, isSelected),
        );
      }).toList(),
    );
  }

  Widget _buildOptionRow(MoodPollOption option, bool isSelected) {
    return GestureDetector(
      onTap: _isSubmitting ? null : () => _selectOption(option),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white
              : Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.3),
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            // Emoji
            AnimatedScale(
              scale: isSelected ? 1.1 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Text(
                option.emoji,
                style: const TextStyle(fontSize: 32),
              ),
            ),
            const SizedBox(width: 14),
            // Texto - ahora ocupa todo el espacio disponible
            Expanded(
              child: Text(
                option.text,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected
                      ? const Color(0xFF667eea)
                      : Colors.white,
                  height: 1.3,
                ),
              ),
            ),
            // Indicador de selección
            if (isSelected) ...[
              const SizedBox(width: 10),
              if (_isSubmitting)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF667eea)),
                  ),
                )
              else
                const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF667eea),
                  size: 24,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildShareSection() {
    return Column(
      children: [
        // Respuesta seleccionada con animación
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.8, end: 1.0),
          duration: const Duration(milliseconds: 400),
          curve: Curves.elasticOut,
          builder: (context, scale, child) {
            return Transform.scale(scale: scale, child: child);
          },
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              children: [
                Text(
                  _selectedOption?.emoji ?? '',
                  style: const TextStyle(fontSize: 60),
                ),
                const SizedBox(height: 12),
                Text(
                  _selectedOption?.text ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '¡Respuesta guardada!',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF22C55E),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Pregunta si quiere compartir
        const Text(
          '¿Querés compartirlo en tu historia?',
          style: TextStyle(
            fontSize: 16,
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 16),

        // Botones
        Row(
          children: [
            // No compartir
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  widget.onClose?.call();
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.5),
                    width: 2,
                  ),
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'No, gracias',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Compartir
            Expanded(
              child: ElevatedButton.icon(
                onPressed: widget.onShareAsStory,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF667eea),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                icon: const Icon(Icons.share_rounded, size: 20),
                label: const Text(
                  'Compartir',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Dialog para mostrar la encuesta en fullscreen (como story)
class MoodPollDialog extends StatelessWidget {
  final MoodPollQuestion question;
  final Function(MoodPollResponse? response, bool shareAsStory)? onComplete;

  const MoodPollDialog({
    super.key,
    required this.question,
    this.onComplete,
  });

  static Future<void> show({
    required BuildContext context,
    required MoodPollQuestion question,
    Function(MoodPollResponse? response, bool shareAsStory)? onComplete,
  }) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (context) => MoodPollDialog(
        question: question,
        onComplete: onComplete,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    MoodPollResponse? response;

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 60),
        child: MoodPollStoryWidget(
          question: question,
          onSkip: () {
            Navigator.of(context).pop();
            onComplete?.call(null, false);
          },
          onAnswered: (r) {
            response = r;
          },
          onClose: () {
            Navigator.of(context).pop();
            onComplete?.call(response, false);
          },
          onShareAsStory: () {
            Navigator.of(context).pop();
            onComplete?.call(response, true);
          },
        ),
      ),
    );
  }
}

/// Widget compacto para mostrar en el perfil del hijo (para padres)
class MoodPollSummaryWidget extends StatelessWidget {
  final MoodPollStats stats;

  const MoodPollSummaryWidget({
    super.key,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                stats.moodEmoji,
                style: const TextStyle(fontSize: 32),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Estado de ánimo',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  Text(
                    stats.moodDescription,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // Participación
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${stats.totalResponses}/${stats.totalQuestions}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'respondidas',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ],
          ),

          if (stats.responses.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),

            // Últimas respuestas
            const Text(
              'Respuestas recientes',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            ...stats.responses.take(3).map((response) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Text(response.selectedEmoji),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          response.questionText,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        response.selectedOptionText,
                        style: TextStyle(
                          fontSize: 13,
                          color: _getSentimentColor(response.sentimentScore),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Color _getSentimentColor(int score) {
    if (score >= 1) return Colors.green;
    if (score <= -1) return Colors.red;
    return Colors.orange;
  }
}
