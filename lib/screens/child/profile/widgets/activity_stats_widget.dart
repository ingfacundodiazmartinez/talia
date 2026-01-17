import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../services/child_profile_service.dart';
import '../../../../services/chat_permission_service.dart';

/// Widget que muestra las estadísticas de actividad del usuario
class ActivityStatsWidget extends StatelessWidget {
  final String userId;

  const ActivityStatsWidget({
    super.key,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final service = ChildProfileService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mi Actividad',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: service.getChatsStream(userId),
                builder: (context, chatsSnapshot) {
                  int chatCount = 0;
                  if (chatsSnapshot.hasData) {
                    chatCount = service.countActiveChats(
                      chatsSnapshot.data!,
                      userId,
                    );
                  }
                  return _buildStatCard(
                    context: context,
                    icon: Icons.chat_bubble,
                    title: 'Chats',
                    value: '$chatCount',
                    color: colorScheme.primary,
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FutureBuilder<List<String>>(
                future: ChatPermissionService()
                    .getBidirectionallyApprovedContacts(userId),
                builder: (context, contactsSnapshot) {
                  final contactCount = contactsSnapshot.hasData
                      ? contactsSnapshot.data!.length
                      : 0;
                  return _buildStatCard(
                    context: context,
                    icon: Icons.people,
                    title: 'Contactos',
                    value: '$contactCount',
                    color: const Color(0xFF4CAF50),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
