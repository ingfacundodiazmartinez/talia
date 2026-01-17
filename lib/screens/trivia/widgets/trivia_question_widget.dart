import 'package:flutter/material.dart';

import '../../../models/trivia_question.dart';

/// Widget para mostrar una pregunta de trivia durante el juego
class TriviaQuestionWidget extends StatelessWidget {
  final TriviaQuestion question;
  final List<TriviaOption> shuffledOptions;
  final String? selectedOptionId;
  final String? correctOptionId;
  final bool showResult;
  final bool isAnswering;
  final Function(String optionId)? onOptionSelected;

  const TriviaQuestionWidget({
    super.key,
    required this.question,
    required this.shuffledOptions,
    this.selectedOptionId,
    this.correctOptionId,
    this.showResult = false,
    this.isAnswering = false,
    this.onOptionSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Card de la pregunta
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF667eea), Color(0xFF764ba2)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF667eea).withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              if (question.imageUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    question.imageUrl!,
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                question.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Opciones
        ...shuffledOptions.map((option) {
          return _OptionButton(
            option: option,
            isSelected: selectedOptionId == option.id,
            isCorrect: correctOptionId == option.id,
            showResult: showResult,
            isDisabled: isAnswering || showResult,
            onTap: onOptionSelected != null
                ? () => onOptionSelected!(option.id)
                : null,
          );
        }),
      ],
    );
  }
}

class _OptionButton extends StatelessWidget {
  final TriviaOption option;
  final bool isSelected;
  final bool isCorrect;
  final bool showResult;
  final bool isDisabled;
  final VoidCallback? onTap;

  const _OptionButton({
    required this.option,
    required this.isSelected,
    required this.isCorrect,
    required this.showResult,
    required this.isDisabled,
    this.onTap,
  });

  static const _triviaColor = Color(0xFF667eea);

  Color _getBackgroundColor(bool isDark) {
    if (showResult) {
      if (isCorrect) {
        return Colors.green.withValues(alpha: isDark ? 0.2 : 0.1);
      }
      if (isSelected && !isCorrect) {
        return Colors.red.withValues(alpha: isDark ? 0.2 : 0.1);
      }
    }
    if (isSelected) {
      return _triviaColor.withValues(alpha: isDark ? 0.2 : 0.1);
    }
    return isDark ? Colors.grey.shade800.withValues(alpha: 0.5) : Colors.white;
  }

  Color _getBorderColor(bool isDark) {
    if (showResult) {
      if (isCorrect) return Colors.green;
      if (isSelected && !isCorrect) return Colors.red;
    }
    if (isSelected) return _triviaColor;
    return isDark ? Colors.grey.shade700 : Colors.grey.shade300;
  }

  Widget _getIndicator() {
    const size = 22.0;

    if (showResult) {
      if (isCorrect) {
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.green,
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 14),
        );
      }
      if (isSelected && !isCorrect) {
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red,
          ),
          child: const Icon(Icons.close_rounded, color: Colors.white, size: 14),
        );
      }
    }
    if (isSelected) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF667eea), Color(0xFF764ba2)],
          ),
        ),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 14),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey.shade400, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _getBackgroundColor(isDark),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _getBorderColor(isDark),
                width: isSelected || (showResult && (isCorrect || isSelected))
                    ? 2
                    : 1,
              ),
              boxShadow: isSelected && !showResult
                  ? [
                      BoxShadow(
                        color: _triviaColor.withValues(alpha: 0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                _getIndicator(),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    option.text,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: _getTextColor(isDark),
                    ),
                  ),
                ),
                if (option.emoji != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      option.emoji!,
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color? _getTextColor(bool isDark) {
    if (showResult) {
      if (isCorrect) return Colors.green.shade700;
      if (isSelected && !isCorrect) return Colors.red.shade700;
    }
    if (isSelected) return _triviaColor;
    return null;
  }
}
