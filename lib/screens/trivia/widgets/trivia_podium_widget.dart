import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../models/trivia_response.dart';

/// Widget de podio para los ganadores de trivia
class TriviaPodiumWidget extends StatelessWidget {
  final List<TriviaLeaderboardEntry> winners;

  const TriviaPodiumWidget({
    super.key,
    required this.winners,
  });

  @override
  Widget build(BuildContext context) {
    if (winners.isEmpty) {
      return _buildEmptyPodium();
    }

    // Obtener los 3 primeros lugares (o null si no existen)
    final first = winners.isNotEmpty ? winners[0] : null;
    final second = winners.length >= 2 ? winners[1] : null;
    final third = winners.length >= 3 ? winners[2] : null;

    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 2do lugar (izquierda, más bajo)
          if (second != null)
            _PodiumPosition(
              entry: second,
              position: 2,
              height: 80,
            )
          else
            _EmptyPodiumPosition(position: 2, height: 80),

          const SizedBox(width: 8),

          // 1er lugar (centro, más alto)
          if (first != null)
            _PodiumPosition(
              entry: first,
              position: 1,
              height: 110,
            )
          else
            _EmptyPodiumPosition(position: 1, height: 110),

          const SizedBox(width: 8),

          // 3er lugar (derecha, más bajo)
          if (third != null)
            _PodiumPosition(
              entry: third,
              position: 3,
              height: 60,
            )
          else
            _EmptyPodiumPosition(position: 3, height: 60),
        ],
      ),
    );
  }

  Widget _buildEmptyPodium() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.emoji_events_outlined,
            size: 64,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          const Text(
            'Aún no hay participantes',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Comparte tu trivia para ver el podio',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

class _PodiumPosition extends StatelessWidget {
  final TriviaLeaderboardEntry entry;
  final int position;
  final double height;

  const _PodiumPosition({
    required this.entry,
    required this.position,
    required this.height,
  });

  Color get _podiumColor {
    switch (position) {
      case 1:
        return const Color(0xFFFFD700); // Gold
      case 2:
        return const Color(0xFFC0C0C0); // Silver
      case 3:
        return const Color(0xFFCD7F32); // Bronze
      default:
        return Colors.grey;
    }
  }

  Color get _podiumColorDark {
    switch (position) {
      case 1:
        return const Color(0xFFDAA520); // Dark Gold
      case 2:
        return const Color(0xFF808080); // Dark Silver
      case 3:
        return const Color(0xFF8B4513); // Dark Bronze
      default:
        return Colors.grey.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Avatar y medal
        Stack(
          alignment: Alignment.bottomCenter,
          children: [
            // Avatar
            Container(
              width: position == 1 ? 70 : 60,
              height: position == 1 ? 70 : 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _podiumColor,
                  width: 3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: _podiumColor.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipOval(
                child: entry.response.oderPhotoURL != null
                    ? CachedNetworkImage(
                        imageUrl: entry.response.oderPhotoURL!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.person, color: Colors.grey),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.person, color: Colors.grey),
                        ),
                      )
                    : Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.person, color: Colors.grey),
                      ),
              ),
            ),
            // Medal badge
            Positioned(
              bottom: -5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _podiumColor,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  entry.medalEmoji,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        // Nombre
        SizedBox(
          width: 80,
          child: Text(
            entry.response.oderName,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: position == 1 ? 14 : 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        const SizedBox(height: 4),

        // Puntuación
        Text(
          '${entry.response.totalScore} pts',
          style: TextStyle(
            color: _podiumColorDark,
            fontWeight: FontWeight.bold,
            fontSize: position == 1 ? 16 : 14,
          ),
        ),

        const SizedBox(height: 8),

        // Pedestal
        Container(
          width: position == 1 ? 90 : 80,
          height: height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _podiumColor,
                _podiumColorDark,
              ],
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
            boxShadow: [
              BoxShadow(
                color: _podiumColor.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              '$position',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyPodiumPosition extends StatelessWidget {
  final int position;
  final double height;

  const _EmptyPodiumPosition({
    required this.position,
    required this.height,
  });

  Color get _podiumColor {
    switch (position) {
      case 1:
        return Colors.grey.shade300;
      case 2:
        return Colors.grey.shade300;
      case 3:
        return Colors.grey.shade300;
      default:
        return Colors.grey.shade300;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Avatar placeholder
        Container(
          width: position == 1 ? 70 : 60,
          height: position == 1 ? 70 : 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.grey.shade200,
            border: Border.all(
              color: _podiumColor,
              width: 3,
            ),
          ),
          child: Icon(
            Icons.person_outline,
            color: Colors.grey.shade400,
            size: 32,
          ),
        ),

        const SizedBox(height: 12),

        // Nombre placeholder
        SizedBox(
          width: 80,
          child: Text(
            '---',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: position == 1 ? 14 : 12,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 4),

        // Puntuación placeholder
        Text(
          '-- pts',
          style: TextStyle(
            color: Colors.grey.shade400,
            fontSize: position == 1 ? 16 : 14,
          ),
        ),

        const SizedBox(height: 8),

        // Pedestal
        Container(
          width: position == 1 ? 90 : 80,
          height: height,
          decoration: BoxDecoration(
            color: _podiumColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          ),
          child: Center(
            child: Text(
              '$position',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
