import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'notification_service.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final NotificationService _notificationService = NotificationService();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Notificaciones'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        actions: [
          TextButton.icon(
            onPressed: () async {
              await _notificationService.markAllAsRead(_auth.currentUser!.uid);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('✅ Todas marcadas como leídas')),
              );
            },
            icon: Icon(Icons.done_all, color: Colors.white),
            label: Text('Marcar todas', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('notifications')
            .where('recipientId', isEqualTo: _auth.currentUser?.uid)
            .orderBy('createdAt', descending: true)
            .limit(50)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 80,
                    color: Colors.grey[300],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No tienes notificaciones',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: EdgeInsets.all(8),
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final doc = snapshot.data!.docs[index];
              final data = doc.data() as Map<String, dynamic>;

              return _buildNotificationItem(doc.id, data);
            },
          );
        },
      ),
    );
  }

  Widget _buildNotificationItem(
    String notificationId,
    Map<String, dynamic> data,
  ) {
    final type = data['type'] ?? 'general';
    final title = data['title'] ?? 'Notificación';
    final body = data['body'] ?? '';
    final isRead = data['isRead'] ?? false;
    final timestamp = data['createdAt'] as Timestamp?;
    final priority = data['priority'] ?? 'normal';

    IconData icon;
    Color iconColor;

    switch (type) {
      case 'contact_request':
        icon = Icons.person_add;
        iconColor = Colors.blue;
        break;
      case 'contact_approved':
        icon = Icons.check_circle;
        iconColor = Colors.green;
        break;
      case 'bullying_alert':
        icon = Icons.warning;
        iconColor = Colors.red;
        break;
      case 'report_ready':
        icon = Icons.analytics;
        iconColor = Colors.purple;
        break;
      default:
        icon = Icons.notifications;
        iconColor = Colors.grey;
    }

    return Dismissible(
      key: Key(notificationId),
      background: Container(
        color: Colors.green,
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.only(left: 20),
        child: Icon(Icons.done, color: Colors.white),
      ),
      secondaryBackground: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: 20),
        child: Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Marcar como leída
          await _notificationService.markAsRead(notificationId);
          return false;
        } else {
          // Eliminar
          return await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Eliminar notificación'),
              content: Text('¿Estás seguro?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Cancelar'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text('Eliminar', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          );
        }
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          FirebaseFirestore.instance
              .collection('notifications')
              .doc(notificationId)
              .delete();
        }
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isRead ? Colors.white : Color(0xFF9D7FE8).withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: priority == 'high'
                ? Colors.red.withOpacity(0.3)
                : Colors.grey.withOpacity(0.2),
            width: priority == 'high' ? 2 : 1,
          ),
        ),
        child: ListTile(
          leading: Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor),
          ),
          title: Text(
            title,
            style: TextStyle(
              fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
              fontSize: 16,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 4),
              Text(body, style: TextStyle(fontSize: 14)),
              if (timestamp != null) ...[
                SizedBox(height: 8),
                Text(
                  _formatTime(timestamp),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ],
          ),
          trailing: !isRead
              ? Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Color(0xFF9D7FE8),
                    shape: BoxShape.circle,
                  ),
                )
              : null,
          onTap: () async {
            if (!isRead) {
              await _notificationService.markAsRead(notificationId);
            }
            _handleNotificationTap(type, data);
          },
        ),
      ),
    );
  }

  String _formatTime(Timestamp timestamp) {
    final date = timestamp.toDate();
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      if (difference.inDays == 1) return 'Ayer';
      if (difference.inDays < 7) return 'Hace ${difference.inDays} días';
      return '${date.day}/${date.month}/${date.year}';
    } else if (difference.inHours > 0) {
      return 'Hace ${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return 'Hace ${difference.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }

  void _handleNotificationTap(String type, Map<String, dynamic> data) {
    // Aquí puedes navegar a pantallas específicas según el tipo
    print('👆 Tap en notificación tipo: $type');

    switch (type) {
      case 'contact_request':
        // Navegar a panel de control parental
        break;
      case 'bullying_alert':
        // Navegar a reportes y alertas
        break;
      case 'report_ready':
        // Navegar a reportes
        break;
      default:
        break;
    }
  }
}

// Widget del badge de notificaciones (para usar en AppBar)
class NotificationBadge extends StatelessWidget {
  final String userId;
  final VoidCallback onTap;

  const NotificationBadge({
    super.key,
    required this.userId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: NotificationService().getUnreadCount(userId),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;

        return IconButton(
          icon: Stack(
            children: [
              Icon(Icons.notifications),
              if (count > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    constraints: BoxConstraints(minWidth: 18, minHeight: 18),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          onPressed: onTap,
        );
      },
    );
  }
}
