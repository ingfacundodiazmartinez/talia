import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../controllers/group_message_info_controller.dart';

/// Pantalla que muestra información detallada del mensaje en grupos V2
/// Muestra para cada miembro: leído con timestamps
class GroupMessageInfoScreen extends StatelessWidget {
  final String groupId;
  final String messageId;

  GroupMessageInfoScreen({
    super.key,
    required this.groupId,
    required this.messageId,
  });

  late final GroupMessageInfoController _controller =
      GroupMessageInfoController();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Información del mensaje'),
        backgroundColor: colorScheme.surface,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _controller.getMessageStream(groupId, messageId),
        builder: (context, messageSnapshot) {
          if (messageSnapshot.hasError) {
            return Center(
              child: Text('Error al cargar mensaje: ${messageSnapshot.error}'),
            );
          }

          if (!messageSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          try {
            final messageData =
                messageSnapshot.data!.data() as Map<String, dynamic>?;
            if (messageData == null) {
              return const Center(child: Text('Mensaje no encontrado'));
            }

            final readBy = messageData['readBy'] != null
                ? List<String>.from(messageData['readBy'] as List)
                : <String>[];
            final senderId = messageData['senderId'] as String?;

            return StreamBuilder<DocumentSnapshot>(
              stream: _controller.getGroupStream(groupId),
              builder: (context, groupSnapshot) {
                if (!groupSnapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final groupData =
                    groupSnapshot.data!.data() as Map<String, dynamic>?;
                if (groupData == null) {
                  return const Center(child: Text('Grupo no encontrado'));
                }

                // Get members from groups_v2 structure
                final members = groupData['members'] != null
                    ? List<String>.from(groupData['members'] as List)
                    : <String>[];

                // Filter out sender
                final otherMembers =
                    members.where((m) => m != senderId).toList();

                // Separate read and pending members
                final readMembers =
                    otherMembers.where((m) => readBy.contains(m)).toList();
                final pendingMembers =
                    otherMembers.where((m) => !readBy.contains(m)).toList();

                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Section: Read by
                      if (readMembers.isNotEmpty) ...[
                        _buildSectionHeader(
                          context,
                          'Leído por',
                          Icons.drafts_outlined,
                        ),
                        ...readMembers.map((userId) => _buildMemberTile(
                              context,
                              userId,
                              'read',
                              messageData['readAt_$userId'] as Timestamp?,
                            )),
                      ],

                      // Section: Pending
                      if (pendingMembers.isNotEmpty) ...[
                        _buildSectionHeader(
                          context,
                          'Pendiente',
                          Icons.mail_outline,
                        ),
                        ...pendingMembers.map((userId) => _buildMemberTile(
                              context,
                              userId,
                              'pending',
                              null,
                            )),
                      ],

                      // Empty state
                      if (readMembers.isEmpty && pendingMembers.isEmpty)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No hay información de lectura disponible',
                                  style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
          } catch (e) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Error al cargar información del mensaje',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      e.toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
            : colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberTile(
    BuildContext context,
    String userId,
    String status,
    Timestamp? timestamp,
  ) {
    return FutureBuilder<DocumentSnapshot>(
      future: _controller.getUserInfo(userId),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) {
          return const ListTile(
            leading: CircleAvatar(child: Icon(Icons.person)),
            title: Text('Cargando...'),
          );
        }

        final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
        final name = userData?['name'] as String? ?? 'Usuario';
        final photoURL = userData?['photoURL'] as String?;

        IconData statusIcon;
        String statusLabel;

        switch (status) {
          case 'read':
            statusIcon = Icons.drafts_outlined;
            statusLabel = _formatTimestamp(timestamp);
            break;
          case 'pending':
          default:
            statusIcon = Icons.mail_outline;
            statusLabel = 'Pendiente';
            break;
        }

        return ListTile(
          leading: CircleAvatar(
            radius: 20,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            backgroundImage: photoURL != null && photoURL.isNotEmpty
                ? CachedNetworkImageProvider(photoURL)
                : null,
            child: photoURL == null || photoURL.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : null,
          ),
          title: Text(
            name,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                statusIcon,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTimestamp(Timestamp? timestamp) {
    if (timestamp == null) return '';

    final date = timestamp.toDate();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      return DateFormat('HH:mm').format(date);
    } else {
      return DateFormat('dd/MM HH:mm').format(date);
    }
  }
}
