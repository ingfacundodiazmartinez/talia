import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Widget de timer circular animado para trivia
class TriviaTimerWidget extends StatelessWidget {
  final int remainingMs;
  final int totalMs;
  final double size;

  const TriviaTimerWidget({
    super.key,
    required this.remainingMs,
    required this.totalMs,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    final progress = remainingMs / totalMs;
    final seconds = (remainingMs / 1000).ceil();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Colores según el tiempo restante
    Color timerColor;
    Color bgColor;
    if (progress > 0.5) {
      timerColor = const Color(0xFF667eea);
      bgColor = const Color(0xFF667eea).withValues(alpha: 0.15);
    } else if (progress > 0.25) {
      timerColor = Colors.orange;
      bgColor = Colors.orange.withValues(alpha: 0.15);
    } else {
      timerColor = Colors.red;
      bgColor = Colors.red.withValues(alpha: 0.15);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        boxShadow: progress <= 0.25
            ? [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.3),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Progress arc
          CustomPaint(
            size: Size(size, size),
            painter: _TimerPainter(
              progress: progress.clamp(0.0, 1.0),
              color: timerColor,
              backgroundColor:
                  isDark ? Colors.grey.shade700 : Colors.grey.shade300,
              strokeWidth: 5,
            ),
          ),
          // Timer text
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$seconds',
                style: TextStyle(
                  fontSize: size * 0.38,
                  fontWeight: FontWeight.bold,
                  color: timerColor,
                  height: 1.0,
                ),
              ),
              Text(
                'seg',
                style: TextStyle(
                  fontSize: size * 0.16,
                  color: timerColor.withValues(alpha: 0.7),
                  height: 1.0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimerPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color backgroundColor;
  final double strokeWidth;

  _TimerPainter({
    required this.progress,
    required this.color,
    required this.backgroundColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Background circle
    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    // Progress arc
    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * math.pi * progress;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2, // Start from top
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _TimerPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// Widget de feedback inmediato (verde/rojo)
class TriviaFeedbackWidget extends StatelessWidget {
  final bool isCorrect;
  final int pointsEarned;
  final String correctAnswer;
  final VoidCallback? onContinue;

  const TriviaFeedbackWidget({
    super.key,
    required this.isCorrect,
    required this.pointsEarned,
    required this.correctAnswer,
    this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor = isCorrect ? Colors.green : Colors.red;
    final icon = isCorrect
        ? Icons.check_circle_rounded
        : Icons.cancel_rounded;
    final message = isCorrect ? 'Correcto!' : 'Incorrecto';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: backgroundColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: backgroundColor, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: backgroundColor),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: backgroundColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '+$pointsEarned puntos',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: backgroundColor,
            ),
          ),
          if (!isCorrect) ...[
            const SizedBox(height: 16),
            Text(
              'La respuesta correcta era:',
              style: TextStyle(
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              correctAnswer,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onContinue,
            style: FilledButton.styleFrom(
              backgroundColor: backgroundColor,
              minimumSize: const Size(200, 48),
            ),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }
}
