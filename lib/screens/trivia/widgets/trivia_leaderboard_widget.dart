import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/trivia_response.dart';
import '../../../widgets/synced_user_widgets.dart';

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
      return _buildEmptyState(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.leaderboard_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Ranking (${entries.length} participantes)',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
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

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'Sin participantes aún',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCurrentUser
            ? const Color(0xFF667eea).withValues(alpha: isDark ? 0.2 : 0.1)
            : isDark
                ? theme.colorScheme.surfaceContainerHighest
                : theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: isCurrentUser
            ? Border.all(color: const Color(0xFF667eea), width: 2)
            : Border.all(
                color: isDark
                    ? theme.colorScheme.outline.withValues(alpha: 0.3)
                    : theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
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
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
            ),
          ),

          const SizedBox(width: 12),

          // Avatar usando SyncedUserAvatar para foto correcta
          SyncedUserAvatar(
            userId: entry.response.oderId,
            fallbackPhotoUrl: entry.response.oderPhotoURL,
            userName: entry.response.oderName,
            radius: 20,
            backgroundColor: theme.colorScheme.primaryContainer,
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
                      child: SyncedUserName(
                        userId: entry.response.oderId,
                        fallbackName: entry.response.oderName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isCurrentUser
                              ? const Color(0xFF667eea)
                              : theme.colorScheme.onSurface,
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
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
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
