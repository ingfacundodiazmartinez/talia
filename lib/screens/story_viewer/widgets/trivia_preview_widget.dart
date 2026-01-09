import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../models/trivia.dart';
import '../../../models/trivia_response.dart';

/// Widget de preview de trivia en el visor de historias
/// Muestra la trivia como una "historia" con opción de jugar
class TriviaPreviewWidget extends StatelessWidget {
  final Trivia trivia;
  final TriviaResponse? userResponse;
  final bool isCreator;
  final VoidCallback onPlay;
  final VoidCallback onViewResults;
  final VoidCallback? onLoaded;

  const TriviaPreviewWidget({
    super.key,
    required this.trivia,
    this.userResponse,
    required this.isCreator,
    required this.onPlay,
    required this.onViewResults,
    this.onLoaded,
  });

  @override
  Widget build(BuildContext context) {
    // Notificar que el contenido está listo
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onLoaded?.call();
    });

    final hasResponded = userResponse != null &&
        userResponse!.status != ResponseStatus.inProgress;
    // ✅ FIX: No permitir jugar si la trivia no tiene preguntas
    final hasQuestions = trivia.questionIds.isNotEmpty;
    final canPlay = !isCreator && !hasResponded && trivia.isActive && hasQuestions;
    final hasBackgroundImage = trivia.backgroundImageUrl != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Fondo: Imagen o gradiente
        if (hasBackgroundImage)
          _buildImageBackground()
        else
          _buildGradientBackground(),

        // Overlay oscuro para legibilidad (solo si hay imagen)
        if (hasBackgroundImage)
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.4),
                  Colors.black.withValues(alpha: 0.2),
                  Colors.black.withValues(alpha: 0.6),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),

        // Contenido
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const Spacer(flex: 2),

                // Icono de trivia
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.quiz_rounded,
                    size: 40,
                    color: Colors.white,
                  ),
                ),

                const SizedBox(height: 24),

                // Título de la trivia
                Text(
                  trivia.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                    shadows: [
                      Shadow(
                        color: Colors.black54,
                        blurRadius: 10,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),

                const SizedBox(height: 20),

                // Info de la trivia
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _InfoChip(
                      icon: Icons.help_outline_rounded,
                      text: '${trivia.questionIds.length} preguntas',
                    ),
                    const SizedBox(width: 12),
                    _InfoChip(
                      icon: Icons.people_outline_rounded,
                      text: '${trivia.participantCount} participantes',
                    ),
                  ],
                ),

                const Spacer(flex: 3),

                // Botón de acción
                _buildActionButton(context, canPlay, hasResponded),

                const SizedBox(height: 16),

                // Mensaje de estado
                if (!hasQuestions)
                  _StatusMessage(
                    icon: Icons.warning_amber_rounded,
                    text: 'Esta trivia no tiene preguntas',
                  )
                else if (!trivia.isActive)
                  _StatusMessage(
                    icon: Icons.lock_clock_rounded,
                    text: 'Esta trivia ha finalizado',
                  )
                else if (isCreator)
                  _StatusMessage(
                    icon: Icons.info_outline_rounded,
                    text: 'No puedes responder tu propia trivia',
                  )
                else if (hasResponded)
                  _StatusMessage(
                    icon: Icons.check_circle_outline_rounded,
                    text: 'Ya respondiste esta trivia',
                  )
                else
                  const SizedBox(height: 20),

                // Espacio para UI inferior (input bar ~100px + safe area)
                const SizedBox(height: 120),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImageBackground() {
    return CachedNetworkImage(
      imageUrl: trivia.backgroundImageUrl!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      placeholder: (context, url) => _buildGradientBackground(),
      errorWidget: (context, url, error) => _buildGradientBackground(),
    );
  }

  Widget _buildGradientBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF667eea),
            Color(0xFF764ba2),
            Color(0xFF6B73FF),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
      BuildContext context, bool canPlay, bool hasResponded) {
    final hasQuestions = trivia.questionIds.isNotEmpty;

    if (canPlay) {
      return _PlayButton(onPressed: onPlay);
    } else if (hasResponded || isCreator || !trivia.isActive || !hasQuestions) {
      // ✅ FIX: Mostrar "Ver resultados" también para trivias sin preguntas
      return _ResultsButton(onPressed: onViewResults);
    }
    return const SizedBox.shrink();
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PlayButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.play_arrow_rounded,
              color: Color(0xFF667eea),
              size: 28,
            ),
            SizedBox(width: 8),
            Text(
              'Jugar',
              style: TextStyle(
                color: Color(0xFF667eea),
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _ResultsButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
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
            Icon(
              Icons.leaderboard_rounded,
              color: Colors.white,
              size: 24,
            ),
            SizedBox(width: 8),
            Text(
              'Ver resultados',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusMessage extends StatelessWidget {
  final IconData icon;
  final String text;

  const _StatusMessage({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white70, size: 16),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
