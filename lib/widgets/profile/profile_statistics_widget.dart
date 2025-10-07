import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/parent.dart';
import '../../services/chat_permission_service.dart';

/// Widget que muestra las estadísticas del perfil del padre
class ProfileStatisticsWidget extends StatelessWidget {
  final String parentId;

  const ProfileStatisticsWidget({
    super.key,
    required this.parentId,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final parent = Parent(id: parentId, name: '');

    return StreamBuilder<DocumentSnapshot>(
      stream: parent.getUserDataStream(),
      builder: (context, userSnapshot) {
        // Calcular días activos
        int daysActive = 0;
        if (userSnapshot.hasData && userSnapshot.data!.exists) {
          final data = userSnapshot.data!.data() as Map<String, dynamic>?;
          final createdAt = data?['createdAt'] as Timestamp?;
          daysActive = Parent.calculateDaysActive(createdAt);
        }

        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    context: context,
                    icon: Icons.calendar_today,
                    title: 'Días activo',
                    value: '$daysActive',
                    color: colorScheme.primary,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: parent.getAlertsStream(),
                    builder: (context, alertsSnapshot) {
                      final reportCount = alertsSnapshot.hasData
                          ? alertsSnapshot.data!.docs.length
                          : 0;
                      return _buildStatCard(
                        context: context,
                        icon: Icons.assessment,
                        title: 'Reportes',
                        value: '$reportCount',
                        color: Color(0xFF4CAF50),
                      );
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FutureBuilder<List<String>>(
                    future: ChatPermissionService()
                        .getBidirectionallyApprovedContacts(parentId),
                    builder: (context, contactsSnapshot) {
                      final totalContacts = contactsSnapshot.hasData
                          ? contactsSnapshot.data!.length
                          : 0;
                      return _buildStatCard(
                        context: context,
                        icon: Icons.contacts,
                        title: 'Contactos',
                        value: '$totalContacts',
                        color: Color(0xFF2196F3),
                      );
                    },
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: parent.getApprovedContactsStream(),
                    builder: (context, approvedSnapshot) {
                      final approvedCount = approvedSnapshot.hasData
                          ? approvedSnapshot.data!.docs.length
                          : 0;
                      return _buildStatCard(
                        context: context,
                        icon: Icons.check_circle,
                        title: 'Aprobados',
                        value: '$approvedCount',
                        color: Color(0xFFFF9800),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
