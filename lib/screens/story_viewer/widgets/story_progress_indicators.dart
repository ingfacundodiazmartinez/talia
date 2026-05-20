import 'package:flutter/material.dart';

/// Widget que muestra los indicadores de progreso para las historias
class StoryProgressIndicators extends StatelessWidget {
  final int storyCount;
  final int currentStoryIndex;
  final Animation<double> progressAnimation;

  const StoryProgressIndicators({
    super.key,
    required this.storyCount,
    required this.currentStoryIndex,
    required this.progressAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: List.generate(
          storyCount,
          (index) {
            return Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(1.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1.5),
                  child: AnimatedBuilder(
                    animation: progressAnimation,
                    builder: (context, child) {
                      return LinearProgressIndicator(
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                        value: index < currentStoryIndex
                            ? 1.0
                            : index == currentStoryIndex
                                ? progressAnimation.value
                                : 0.0,
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
