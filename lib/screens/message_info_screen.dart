import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../controllers/message_info_controller.dart';

/// Pantalla que muestra información detallada del mensaje en grupos
/// Muestra para cada miembro: entregado/leído con timestamps
class MessageInfoScreen extends StatelessWidget {
  final String groupId;
  final String messageId;

  MessageInfoScreen({
    super.key,
    required this.groupId,
    required this.messageId,
  });

  late final MessageInfoController _controller = MessageInfoController();

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
            final messageData = messageSnapshot.data!.data() as Map<String, dynamic>?;
            if (messageData == null) {
              return const Center(child: Text('Mensaje no encontrado'));
            }


          // Manejo seguro de listas que podrían no existir
          final deliveredTo = messageData['deliveredTo'] != null
              ? List<String>.from(messageData['deliveredTo'] as List)
              : <String>[];
          final readBy = messageData['readBy'] != null
              ? List<String>.from(messageData['readBy'] as List)
              : <String>[];

          return StreamBuilder<DocumentSnapshot>(
            stream: _controller.getGroupStream(groupId),
            builder: (context, groupSnapshot) {
              if (!groupSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final groupData = groupSnapshot.data!.data() as Map<String, dynamic>?;
              if (groupData == null) {
                return const Center(child: Text('Grupo no encontrado'));
              }

              // Manejo seguro de miembros
              final members = groupData['members'] != null
                  ? List<String>.from(groupData['members'] as List)
                  : <String>[];
              final senderId = messageData['senderId'] as String?;

              // Filtrar miembros para no incluir al remitente
              final otherMembers = members.where((m) => m != senderId).toList();

              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sección: Leído por
                    if (readBy.isNotEmpty) ...[
                      _buildSectionHeader(
                        context,
                        'Leído por',
                        Icons.drafts_outlined, // Sobre abierto
                      ),
                      ...readBy.map((userId) => _buildMemberTile(
                            context,
                            userId,
                            'read',
                            messageData['readAt_$userId'] as Timestamp?,
                          )),
                    ],

                    // Sección: Entregado a
                    if (deliveredTo.isNotEmpty) ...[
                      _buildSectionHeader(
                        context,
                        'Entregado a',
                        Icons.markunread, // Sobre con marca
                      ),
                      ...deliveredTo
                          .where((userId) => !readBy.contains(userId))
                          .map((userId) => _buildMemberTile(
                                context,
                                userId,
                                'delivered',
                                messageData['deliveredAt_$userId'] as Timestamp?,
                              )),
                    ],

                    // Sección: Pendiente
                    if (otherMembers.any((m) => !deliveredTo.contains(m) && !readBy.contains(m))) ...[
                      _buildSectionHeader(
                        context,
                        'Pendiente',
                        Icons.mail_outline, // Sobre cerrado
                      ),
                      ...otherMembers
                          .where((m) => !deliveredTo.contains(m) && !readBy.contains(m))
                          .map((userId) => _buildMemberTile(
                                context,
                                userId,
                                'pending',
                                null,
                              )),
                    ],
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
                    Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 16),
                    Text(
                      'Error al cargar información del mensaje',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      e.toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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

  /// Construye el header de cada sección
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

  /// Construye un tile para cada miembro del grupo
  Widget _buildMemberTile(
    BuildContext context,
    String userId,
    String status, // 'read', 'delivered', 'pending'
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

        // Ícono según el estado (sin color específico, usa tema)
        IconData statusIcon;
        String statusLabel;

        switch (status) {
          case 'read':
            statusIcon = Icons.drafts_outlined; // Sobre abierto
            statusLabel = _formatTimestamp(timestamp);
            break;
          case 'delivered':
            statusIcon = Icons.markunread; // Sobre con marca
            statusLabel = _formatTimestamp(timestamp);
            break;
          case 'pending':
          default:
            statusIcon = Icons.mail_outline; // Sobre cerrado
            statusLabel = 'Pendiente';
            break;
        }

        return ListTile(
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
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

  /// Formatea el timestamp
  String _formatTimestamp(Timestamp? timestamp) {
    if (timestamp == null) return '';

    final date = timestamp.toDate();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      // Hoy: mostrar solo hora
      return DateFormat('HH:mm').format(date);
    } else {
      // Otro día: mostrar fecha y hora
      return DateFormat('dd/MM HH:mm').format(date);
    }
  }
}
