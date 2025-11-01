import 'package:flutter/material.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../../../story_approval_screen.dart';
import '../../contacts/child_contacts_filter_screen.dart';

/// Pantalla que muestra todas las notificaciones/alertas de un hijo específico
///
/// Muestra:
/// - Solicitudes de contacto pendientes
/// - Historias pendientes de aprobación
/// - Alertas de moderación (bullying, contenido inapropiado)
/// - Cambios en whitelist
/// - Todas las notificaciones relacionadas al hijo
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
  final ScrollController _scrollController = ScrollController();

  // Paginación
  static const int _pageSize = 20;
  DocumentSnapshot? _lastDocument;
  bool _isLoadingMore = false;
  bool _hasMoreData = true;
  final List<DocumentSnapshot> _notifications = [];

  // Tracking de notificaciones marcadas como leídas
  final Set<String> _markedAsRead = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Marcar notificaciones visibles como leídas después de 2 segundos
    Future.delayed(Duration(seconds: 2), _markVisibleNotificationsAsRead);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _hasMoreData) {
        _loadMoreNotifications();
      }
    }
  }

  Future<void> _loadMoreNotifications() async {
    if (_isLoadingMore || !_hasMoreData) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      Query query = _firestore
          .collection('notifications')
          .where('userId', isEqualTo: currentUser.uid)
          .orderBy('timestamp', descending: true)
          .limit(_pageSize);

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();

      if (snapshot.docs.isEmpty) {
        setState(() {
          _hasMoreData = false;
          _isLoadingMore = false;
        });
        return;
      }

      setState(() {
        _lastDocument = snapshot.docs.last;
        _notifications.addAll(snapshot.docs);
        _isLoadingMore = false;
        if (snapshot.docs.length < _pageSize) {
          _hasMoreData = false;
        }
      });
    } catch (e) {
      appLogger.log('❌ Error cargando más notificaciones: $e', level: 'ERROR');
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

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
            .collection('notifications')
            .where('userId', isEqualTo: currentUserId)
            // ✅ Ahora mostramos TODAS las notificaciones (leídas y no leídas)
            .orderBy('timestamp', descending: true)
            .limit(50) // Cargar las primeras 50 notificaciones
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && _notifications.isEmpty) {
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
                  Text('Error al cargar notificaciones'),
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

          // Combinar notificaciones del stream inicial con las cargadas por paginación
          final firstPageDocs = snapshot.data?.docs ?? [];
          final allDocs = [...firstPageDocs, ..._notifications.where((doc) {
            return !firstPageDocs.any((firstDoc) => firstDoc.id == doc.id);
          })];

          print('🔍 Total documentos: ${allDocs.length}, Buscando notificaciones para childId: ${widget.childId}');
          print('📋 IDs de documentos: ${allDocs.map((d) => d.id.substring(0, 8)).join(", ")}');

          // Filtrar solo las notificaciones relacionadas a este hijo
          // Y EXCLUIR notificaciones de mensajes de chat
          final allChildNotifications = allDocs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final notifData = data['data'] as Map<String, dynamic>?;
            final senderId = data['senderId'] as String?;
            final type = data['type'] as String?;
            final read = data['read'] as bool?;

            // Debug: mostrar TODAS las notificaciones primero
            print('  📧 Notificación ${doc.id.substring(0, 8)}: '
                'type=$type, '
                'senderId=$senderId, '
                'read=$read, '
                'data.childId=${notifData?['childId']}, '
                'data.senderId=${notifData?['senderId']}, '
                'buscando=${widget.childId}');

            // Filtrar notificaciones de chat
            if (type == 'chat_message') {
              print('    ⏭️  Saltando: es chat_message');
              return false; // Skip chat notifications
            }

            // Verificar si la notificación está relacionada con este hijo
            final isRelated = notifData?['childId'] == widget.childId ||
                   notifData?['senderId'] == widget.childId ||
                   senderId == widget.childId;

            if (isRelated) {
              print('    ✅ MATCH! Relacionada con ${widget.childName}');
            }

            return isRelated;
          }).toList();

          // ✅ Separar notificaciones leídas y no leídas
          final unreadNotifications = allChildNotifications.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return !(data['read'] as bool? ?? false);
          }).toList();

          final readNotifications = allChildNotifications.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return data['read'] as bool? ?? false;
          }).toList();

          // ✅ Combinar: NO LEÍDAS primero, luego LEÍDAS
          final childNotifications = [...unreadNotifications, ...readNotifications];

          print('🎯 Notificaciones filtradas para ${widget.childName}: ${childNotifications.length} (${unreadNotifications.length} no leídas, ${readNotifications.length} leídas)');

          // ✅ Actualizar _hasMoreData basado en el número de documentos recibidos
          // Si recibimos menos de 50 documentos (el límite), no hay más datos
          if (allDocs.length < 50) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _hasMoreData) {
                setState(() {
                  _hasMoreData = false;
                });
              }
            });
          }

          // Ya vienen ordenadas por timestamp desde Firestore

          if (childNotifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No hay notificaciones',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Las notificaciones de ${widget.childName} aparecerán aquí',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.all(16),
            itemCount: childNotifications.length + (_hasMoreData ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == childNotifications.length) {
                // Loading indicator al final
                return Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF9D7FE8),
                    ),
                  ),
                );
              }

              // ✅ Agregar separador entre notificaciones no leídas y leídas
              if (index == unreadNotifications.length && unreadNotifications.isNotEmpty && readNotifications.isNotEmpty) {
                return Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          Expanded(child: Divider(thickness: 1)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'LEÍDAS',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(thickness: 1)),
                        ],
                      ),
                    ),
                    _buildNotificationCard(
                      childNotifications[index].id,
                      childNotifications[index].data() as Map<String, dynamic>,
                    ),
                  ],
                );
              }

              final notification = childNotifications[index];
              final data = notification.data() as Map<String, dynamic>;
              return _buildNotificationCard(notification.id, data);
            },
          );
        },
      ),
    );
  }

  Widget _buildNotificationCard(String notificationId, Map<String, dynamic> data) {
    final isRead = data['read'] as bool? ?? false;
    final type = data['type'] as String? ?? 'general';
    final title = data['title'] as String? ?? 'Notificación';
    final body = data['body'] as String? ?? '';
    final timestamp = data['timestamp'] as Timestamp?;
    final priority = data['priority'] as String? ?? 'normal';
    final notifData = data['data'] as Map<String, dynamic>? ?? {};

    // Determinar color e icono según tipo y prioridad
    final notifStyle = _getNotificationStyle(type, priority);
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Opacity(
      opacity: isRead ? 0.6 : 1.0, // ✅ Notificaciones leídas con opacidad reducida
      child: Card(
        margin: EdgeInsets.only(bottom: 12),
        elevation: isRead ? 0 : 3,
        color: isDarkMode
            ? (isRead ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5) : colorScheme.surfaceContainer)
            : (isRead ? colorScheme.surface.withValues(alpha: 0.7) : colorScheme.surfaceContainerHighest),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isRead
                ? (isDarkMode ? colorScheme.outline.withValues(alpha: 0.2) : Colors.grey.shade200)
                : notifStyle.color.withValues(alpha: isDarkMode ? 0.5 : 0.3),
            width: isRead ? 1 : 2,
          ),
        ),
      child: InkWell(
        onTap: () => _handleNotificationTap(notificationId, type, notifData, isRead),
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
                      color: notifStyle.color.withValues(alpha: isDarkMode ? 0.2 : 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      notifStyle.icon,
                      color: notifStyle.color,
                      size: 20,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          notifStyle.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: notifStyle.color,
                          ),
                        ),
                        if (timestamp != null) ...[
                          SizedBox(height: 4),
                          Text(
                            _formatTimestamp(timestamp),
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurface.withValues(alpha: 0.6),
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
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              if (body.isNotEmpty) ...[
                SizedBox(height: 6),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface.withValues(alpha: 0.8),
                    fontWeight: isRead ? FontWeight.normal : FontWeight.w500,
                  ),
                ),
              ],
              // Botón de acción si aplica
              if (_hasAction(type)) ...[
                SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _handleNotificationAction(type, notifData),
                    icon: Icon(Icons.arrow_forward, size: 16),
                    label: Text(_getActionLabel(type)),
                    style: TextButton.styleFrom(
                      foregroundColor: notifStyle.color,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ), // Cierre del Opacity
    );
  }

  NotificationStyle _getNotificationStyle(String type, String priority) {
    switch (type) {
      case 'contact_request':
        return NotificationStyle(
          color: Colors.blue,
          icon: Icons.person_add,
          label: 'Solicitud de Contacto',
        );
      case 'story_approval_request':
        return NotificationStyle(
          color: Colors.purple,
          icon: Icons.photo_library,
          label: 'Historia Pendiente',
        );
      case 'story_approved':
        return NotificationStyle(
          color: Colors.green,
          icon: Icons.check_circle,
          label: 'Historia Aprobada',
        );
      case 'story_rejected':
        return NotificationStyle(
          color: Colors.orange,
          icon: Icons.cancel,
          label: 'Historia Rechazada',
        );
      case 'bullying_alert':
      case 'activity_alert':
        return NotificationStyle(
          color: Colors.red,
          icon: Icons.warning,
          label: type == 'bullying_alert' ? 'Alerta de Bullying' : 'Alerta de Actividad',
        );
      case 'contact_approved':
        return NotificationStyle(
          color: Colors.green,
          icon: Icons.check_circle,
          label: 'Contacto Aprobado',
        );
      case 'whitelist_change':
        return NotificationStyle(
          color: Colors.indigo,
          icon: Icons.shield,
          label: 'Cambio en Lista Blanca',
        );
      default:
        return NotificationStyle(
          color: priority == 'high' ? Colors.orange : Colors.blue,
          icon: Icons.notifications,
          label: 'Notificación',
        );
    }
  }

  bool _hasAction(String type) {
    return [
      'contact_request',
      'story_approval_request',
    ].contains(type);
  }

  String _getActionLabel(String type) {
    switch (type) {
      case 'contact_request':
        return 'Ver Solicitud';
      case 'story_approval_request':
        return 'Revisar Historia';
      default:
        return 'Ver Detalles';
    }
  }

  Future<void> _handleNotificationTap(
    String notificationId,
    String type,
    Map<String, dynamic> notifData,
    bool isRead,
  ) async {
    // SIEMPRE marcar como leída al tocar (incluso si ya está marcada)
    // Esto asegura que se marca al visualizar
    await _markAsRead(notificationId);

    // Navegar según el tipo
    _handleNotificationAction(type, notifData);
  }

  // Marcar todas las notificaciones visibles en el viewport como leídas
  Future<void> _markVisibleNotificationsAsRead() async {
    if (!mounted) return;

    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      // Obtener notificaciones no leídas del hijo actual
      final unreadSnapshot = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: currentUser.uid)
          .where('read', isEqualTo: false)
          .limit(10) // Solo las primeras 10 visibles
          .get();

      final batch = _firestore.batch();
      int markedCount = 0;

      for (final doc in unreadSnapshot.docs) {
        final data = doc.data();
        final notifData = data['data'] as Map<String, dynamic>?;

        // Filtrar notificaciones de chat
        if (data['type'] == 'chat_message') {
          continue; // Skip chat notifications
        }

        // Verificar si está relacionada con este hijo
        final isRelatedToChild = notifData?['childId'] == widget.childId ||
            notifData?['senderId'] == widget.childId ||
            data['senderId'] == widget.childId;

        if (isRelatedToChild && !_markedAsRead.contains(doc.id)) {
          batch.update(doc.reference, {
            'read': true,
            'readAt': FieldValue.serverTimestamp(),
          });
          _markedAsRead.add(doc.id);
          markedCount++;
        }
      }

      if (markedCount > 0) {
        await batch.commit();
        print('✅ Marcadas $markedCount notificaciones como leídas automáticamente');
      }
    } catch (e) {
      appLogger.log('❌ Error marcando notificaciones visibles: $e', level: 'ERROR');
    }
  }

  void _handleNotificationAction(String type, Map<String, dynamic> notifData) {
    switch (type) {
      case 'contact_request':
        // Navegar a pantalla de contactos del hijo
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChildContactsFilterScreen(
              childId: widget.childId,
              childName: widget.childName,
            ),
          ),
        );
        break;

      case 'story_approval_request':
        // Navegar a pantalla de aprobación de historias
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => StoryApprovalScreen(
              childId: widget.childId,
            ),
          ),
        );
        break;

      default:
        // Para otros tipos, solo mostrar un mensaje
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Notificación vista'),
            duration: Duration(seconds: 1),
          ),
        );
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

  Future<void> _markAsRead(String notificationId) async {
    try {
      await _firestore.collection('notifications').doc(notificationId).update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      appLogger.log('❌ Error marcando notificación como leída: $e', level: 'ERROR');
    }
  }

  Future<void> _markAllAsRead(String parentId) async {
    try {
      final batch = _firestore.batch();

      // Obtener todas las notificaciones no leídas del padre
      final notificationsSnapshot = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: parentId)
          .where('read', isEqualTo: false)
          .get();

      // Filtrar solo las relacionadas a este hijo y excluir notificaciones de chat
      int markedCount = 0;
      for (final doc in notificationsSnapshot.docs) {
        final data = doc.data();
        final notifData = data['data'] as Map<String, dynamic>?;

        // Filtrar notificaciones de chat
        if (data['type'] == 'chat_message') {
          continue; // Skip chat notifications
        }

        // Verificar si la notificación está relacionada con este hijo
        if (notifData?['childId'] == widget.childId ||
            notifData?['senderId'] == widget.childId ||
            data['senderId'] == widget.childId) {
          batch.update(doc.reference, {
            'read': true,
            'readAt': FieldValue.serverTimestamp(),
          });
          markedCount++;
        }
      }

      await batch.commit();

      if (mounted && markedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$markedCount notificación${markedCount > 1 ? 'es' : ''} marcada${markedCount > 1 ? 's' : ''} como leída${markedCount > 1 ? 's' : ''}'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      appLogger.log('❌ Error marcando todas las notificaciones como leídas: $e', level: 'ERROR');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al marcar notificaciones'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Clase auxiliar para estilos de notificaciones
class NotificationStyle {
  final Color color;
  final IconData icon;
  final String label;

  NotificationStyle({
    required this.color,
    required this.icon,
    required this.label,
  });
}
