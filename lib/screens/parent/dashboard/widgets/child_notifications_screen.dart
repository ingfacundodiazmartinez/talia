import 'package:flutter/material.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

/// Pantalla que muestra las alertas/notificaciones de un hijo específico
///
/// Permite al padre ver todas las alertas (leídas y no leídas) de su hijo
class ChildNotificationsScreen extends StatefulWidget {
  final String childId;
  final String childName;

  const ChildNotificationsScreen({
    super.key,
    required this.childId,
    required this.childName,
  });

  @override
  State<ChildNotificationsScreen> createState() => _ChildNotificationsScreenState();
}

class _ChildNotificationsScreenState extends State<ChildNotificationsScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  Widget build(BuildContext context) {
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Alertas de ${widget.childName}'),
          backgroundColor: Color(0xFF9D7FE8),
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Text('Error: Usuario no autenticado'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Alertas de ${widget.childName}'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(Icons.done_all),
            tooltip: 'Marcar todas como leídas',
            onPressed: () => _markAllAsRead(currentUserId),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('alerts')
            .where('childId', isEqualTo: widget.childId)
            .where('parentId', isEqualTo: currentUserId)
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(
                color: Color(0xFF9D7FE8),
              ),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red),
                  SizedBox(height: 16),
                  Text('Error al cargar alertas'),
                  SizedBox(height: 8),
                  Text(
                    snapshot.error.toString(),
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          final alerts = snapshot.data?.docs ?? [];

          if (alerts.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 64,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No hay alertas',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700],
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Las alertas de ${widget.childName} aparecerán aquí',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: alerts.length,
            itemBuilder: (context, index) {
              final alert = alerts[index];
              final data = alert.data() as Map<String, dynamic>;
              return _buildAlertCard(alert.id, data);
            },
          );
        },
      ),
    );
  }

  Widget _buildAlertCard(String alertId, Map<String, dynamic> data) {
    final isRead = data['isRead'] as bool? ?? false;
    final type = data['type'] as String? ?? 'general';
    final message = data['message'] as String? ?? 'Sin mensaje';
    final timestamp = data['timestamp'] as Timestamp?;
    final severity = data['severity'] as String? ?? 'info';

    // Determinar color e icono según severidad
    Color severityColor;
    IconData severityIcon;
    switch (severity) {
      case 'high':
        severityColor = Colors.red;
        severityIcon = Icons.warning;
        break;
      case 'medium':
        severityColor = Colors.orange;
        severityIcon = Icons.info;
        break;
      default:
        severityColor = Colors.blue;
        severityIcon = Icons.notification_important;
    }

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      elevation: isRead ? 1 : 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isRead ? Colors.grey.shade300 : severityColor.withValues(alpha: 0.3),
          width: isRead ? 1 : 2,
        ),
      ),
      child: InkWell(
        onTap: isRead ? null : () => _markAsRead(alertId),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: severityColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      severityIcon,
                      color: severityColor,
                      size: 20,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getAlertTypeLabel(type),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: severityColor,
                          ),
                        ),
                        if (timestamp != null) ...[
                          SizedBox(height: 4),
                          Text(
                            _formatTimestamp(timestamp),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!isRead)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Color(0xFF9D7FE8),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'NUEVA',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 12),
              Text(
                message,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[800],
                  fontWeight: isRead ? FontWeight.normal : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getAlertTypeLabel(String type) {
    switch (type) {
      case 'inappropriate_content':
        return 'Contenido Inapropiado';
      case 'bullying':
        return 'Posible Bullying';
      case 'safety':
        return 'Alerta de Seguridad';
      case 'general':
      default:
        return 'Alerta General';
    }
  }

  String _formatTimestamp(Timestamp timestamp) {
    final date = timestamp.toDate();
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes == 0) {
          return 'Ahora';
        }
        return 'Hace ${difference.inMinutes} min';
      }
      return 'Hace ${difference.inHours}h';
    } else if (difference.inDays == 1) {
      return 'Ayer ${DateFormat('HH:mm').format(date)}';
    } else if (difference.inDays < 7) {
      return 'Hace ${difference.inDays} días';
    } else {
      return DateFormat('dd/MM/yyyy HH:mm').format(date);
    }
  }

  Future<void> _markAsRead(String alertId) async {
    try {
      await _firestore.collection('alerts').doc(alertId).update({
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Alerta marcada como leída'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      appLogger.log('❌ Error marcando alerta como leída: $e', level: 'ERROR');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al marcar alerta'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _markAllAsRead(String parentId) async {
    try {
      final batch = _firestore.batch();
      final alertsSnapshot = await _firestore
          .collection('alerts')
          .where('childId', isEqualTo: widget.childId)
          .where('parentId', isEqualTo: parentId)
          .where('isRead', isEqualTo: false)
          .get();

      for (final doc in alertsSnapshot.docs) {
        batch.update(doc.reference, {
          'isRead': true,
          'readAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Todas las alertas marcadas como leídas'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      appLogger.log('❌ Error marcando todas las alertas como leídas: $e', level: 'ERROR');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al marcar alertas'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
