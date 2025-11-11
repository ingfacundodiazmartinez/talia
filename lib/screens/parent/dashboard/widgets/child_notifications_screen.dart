import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../controllers/child_notifications_controller.dart';
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
  late final ChildNotificationsController _controller;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // Inicializar controller
    _controller = ChildNotificationsController(
      childId: widget.childId,
      childName: widget.childName,
    );
    _controller.initialize();

    _scrollController.addListener(_onScroll);
    // ❌ REMOVED: Automatic read marking was causing false read receipts
    // Only mark as read when user explicitly taps notifications
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_controller.isLoadingMore && _controller.hasMoreData) {
        _loadMoreNotifications();
      }
    }
  }

  Future<void> _loadMoreNotifications() async {
    final success = await _controller.loadMoreNotifications();
    if (mounted && success) {
      setState(() {}); // Refresh UI
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.isUserAuthenticated) {
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
            onPressed: _markAllAsRead,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _controller.getNotificationsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && _controller.notifications.isEmpty) {
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
          final allDocs = [...firstPageDocs, ..._controller.notifications.where((doc) {
            return !firstPageDocs.any((firstDoc) => firstDoc.id == doc.id);
          })];

          _controller.logDebugInfo('Total documentos: ${allDocs.length}, Buscando notificaciones para childId: ${widget.childId}');

          // Filtrar solo las notificaciones relacionadas a este hijo
          final allChildNotifications = _controller.filterNotificationsForChild(allDocs);

          // ✅ Separar notificaciones leídas y no leídas
          final separatedNotifications = _controller.separateReadUnread(allChildNotifications);
          final unreadNotifications = separatedNotifications['unread']!;
          final readNotifications = separatedNotifications['read']!;

          // ✅ Combinar: NO LEÍDAS primero, luego LEÍDAS
          final childNotifications = [...unreadNotifications, ...readNotifications];

          // ✅ Actualizar _hasMoreData basado en el número de documentos recibidos
          // Si recibimos menos de 50 documentos (el límite), no hay más datos
          if (allDocs.length < 50) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _controller.hasMoreData) {
                setState(() {}); // Trigger rebuild
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
            itemCount: childNotifications.length + (_controller.hasMoreData ? 1 : 0),
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
    final notifStyle = _controller.getNotificationStyle(type, priority);
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
                            _controller.formatTimestamp(timestamp),
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
              if (_controller.hasAction(type)) ...[
                SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _handleNotificationAction(type, notifData),
                    icon: Icon(Icons.arrow_forward, size: 16),
                    label: Text(_controller.getActionLabel(type)),
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


  Future<void> _handleNotificationTap(
    String notificationId,
    String type,
    Map<String, dynamic> notifData,
    bool isRead,
  ) async {
    // SIEMPRE marcar como leída al tocar (incluso si ya está marcada)
    // Esto asegura que se marca al visualizar
    await _controller.markAsRead(notificationId);

    // Navegar según el tipo
    _handleNotificationAction(type, notifData);
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

  Future<void> _markAllAsRead() async {
    final markedCount = await _controller.markAllAsRead();

    if (mounted) {
      if (markedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$markedCount notificación${markedCount > 1 ? 'es' : ''} marcada${markedCount > 1 ? 's' : ''} como leída${markedCount > 1 ? 's' : ''}'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }
}
