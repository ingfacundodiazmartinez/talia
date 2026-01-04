import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/trivia_response.dart';

/// Widget de leaderboard completo de trivia
class TriviaLeaderboardWidget extends StatelessWidget {
  final List<TriviaLeaderboardEntry> entries;
  final bool showHeader;

  const TriviaLeaderboardWidget({
    super.key,
    required this.entries,
    this.showHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return _buildEmptyState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.leaderboard_rounded, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Ranking (${entries.length} participantes)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              return _LeaderboardTile(
                entry: entries[index],
                index: index,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline_rounded,
            size: 48,
            color: Colors.grey,
          ),
          SizedBox(height: 16),
          Text(
            'Sin participantes aún',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaderboardTile extends StatelessWidget {
  final TriviaLeaderboardEntry entry;
  final int index;

  const _LeaderboardTile({
    required this.entry,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final isCurrentUser = entry.response.oderId == currentUserId;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCurrentUser
            ? const Color(0xFF667eea).withValues(alpha: 0.1)
            : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: isCurrentUser
            ? Border.all(color: const Color(0xFF667eea), width: 2)
            : Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          // Posición
          SizedBox(
            width: 40,
            child: Center(
              child: entry.isOnPodium
                  ? Text(
                      entry.medalEmoji,
                      style: const TextStyle(fontSize: 24),
                    )
                  : Text(
                      '#${entry.rank}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade600,
                      ),
                    ),
            ),
          ),

          const SizedBox(width: 12),

          // Avatar
          CircleAvatar(
            radius: 20,
            backgroundColor: Colors.grey.shade200,
            backgroundImage: entry.response.oderPhotoURL != null
                ? CachedNetworkImageProvider(entry.response.oderPhotoURL!)
                : null,
            child: entry.response.oderPhotoURL == null
                ? Icon(Icons.person, color: Colors.grey.shade400)
                : null,
          ),

          const SizedBox(width: 12),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.response.oderName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isCurrentUser
                              ? const Color(0xFF667eea)
                              : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCurrentUser)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF667eea),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'Tú',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.response.correctCount}/${entry.response.totalQuestions} correctas • ${(entry.response.accuracy * 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),

          // Puntuación
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.stars_rounded,
                    size: 18,
                    color: Color(0xFF667eea),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${entry.response.totalScore}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF667eea),
                    ),
                  ),
                ],
              ),
              Text(
                'pts',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
