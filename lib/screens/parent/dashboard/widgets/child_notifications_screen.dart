import 'package:flutter/material.dart';
import '../../../../controllers/child_notifications_controller.dart';
import '../../../../groups/groups.dart';
import '../../../story_approval_screen.dart';
import '../../contacts/child_contacts_filter_screen.dart';
import '../../../../services/notification_tracking_service.dart';
import '../../../../utils/release_logger.dart';

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

  // Estado para cache-based architecture
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';

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

    // ✅ Auto-dismiss: Limpiar notificaciones de alertas para este hijo
    NotificationTrackingService().dismissNotificationsForContext(
      type: NotificationContext.alert,
      contextId: widget.childId,
    );
    NotificationTrackingService().dismissNotificationsForContext(
      type: NotificationContext.report,
      contextId: widget.childId,
    );

    // Sincronizar notificaciones y cargar desde cache
    _syncAndLoadNotifications();
  }

  /// Sincronizar notificaciones de Firestore al cache y cargar
  Future<void> _syncAndLoadNotifications() async {
    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      // Sincronizar: Firestore -> Cache local -> Delete de Firestore
      await _controller.syncAndGetNotifications();

      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        // Marcar todas como leídas después de sincronizar
        _markAllAsRead(showSnackbar: false);
      }
    } catch (e) {
      ReleaseLogger.error('Error sincronizando notificaciones: $e', tag: 'ChildNotifications');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
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
          title: Text('Notificaciones de ${widget.childName}'),
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
        title: Text('Notificaciones de ${widget.childName}'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        actions: [
          // Botón de refresh para sincronizar manualmente
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _controller.isSyncing ? null : _syncAndLoadNotifications,
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // Estado de carga inicial
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          color: Color(0xFF9D7FE8),
        ),
      );
    }

    // Estado de error
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red),
            SizedBox(height: 16),
            Text('Error al cargar notificaciones'),
            SizedBox(height: 8),
            Text(
              _errorMessage,
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _syncAndLoadNotifications,
              child: Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    // Obtener notificaciones del cache
    final separatedNotifications = _controller.separateCachedReadUnread();
    final unreadNotifications = separatedNotifications['unread']!;
    final readNotifications = separatedNotifications['read']!;

    // Combinar: NO LEÍDAS primero, luego LEÍDAS
    final childNotifications = [...unreadNotifications, ...readNotifications];

    _controller.logDebugInfo('Cache: ${childNotifications.length} notificaciones para ${widget.childName}');

    // Estado vacío
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

    // Lista de notificaciones desde cache
    return RefreshIndicator(
      onRefresh: _syncAndLoadNotifications,
      color: Color(0xFF9D7FE8),
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: childNotifications.length,
        itemBuilder: (context, index) {
          // Agregar separador entre notificaciones no leídas y leídas
          if (index == unreadNotifications.length && unreadNotifications.isNotEmpty && readNotifications.isNotEmpty) {
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: Divider(thickness: 0.5, color: Colors.grey.shade300)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          'Anteriores',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                      Expanded(child: Divider(thickness: 0.5, color: Colors.grey.shade300)),
                    ],
                  ),
                ),
                _buildCachedNotificationCard(childNotifications[index]),
              ],
            );
          }

          return _buildCachedNotificationCard(childNotifications[index]);
        },
      ),
    );
  }

  /// Build notification card from cached data
  Widget _buildCachedNotificationCard(Map<String, dynamic> data) {
    final notificationId = data['id'] as String? ?? '';
    final isRead = data['read'] as bool? ?? false;
    final type = data['type'] as String? ?? 'general';
    final title = data['title'] as String? ?? 'Notificación';
    final body = data['body'] as String? ?? '';
    final createdAt = data['createdAt'] as int?;
    final priority = data['priority'] as String? ?? 'normal';
    final notifData = data['data'] as Map<String, dynamic>? ?? {};

    // Determinar color e icono según tipo y prioridad
    final notifStyle = _controller.getNotificationStyle(type, priority);
    final colorScheme = Theme.of(context).colorScheme;

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Opacity(
      opacity: isRead ? 0.75 : 1.0,
      child: Container(
        margin: EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isDarkMode ? colorScheme.surfaceContainerHighest : colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDarkMode ? 0.2 : 0.06),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: () => _handleCachedNotificationTap(notificationId, type, notifData, isRead),
            borderRadius: BorderRadius.circular(14),
            child: Row(
              children: [
                // Indicador lateral de color
                Container(
                  width: 4,
                  height: 76,
                  color: isRead ? Colors.grey.shade400 : notifStyle.color,
                ),
                // Contenido principal
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Icono en círculo sutil
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            notifStyle.icon,
                            color: colorScheme.onPrimaryContainer,
                            size: 20,
                          ),
                        ),
                        SizedBox(width: 12),
                        // Contenido principal
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Primera línea: Título + timestamp
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      notifStyle.label,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  if (createdAt != null)
                                    Text(
                                      _controller.formatCachedTimestamp(createdAt),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                      ),
                                    ),
                                ],
                              ),
                              SizedBox(height: 4),
                              // Body/descripción
                              Text(
                                body.isNotEmpty ? body : title,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              // Indicador de no leída
                              if (!isRead) ...[
                                SizedBox(height: 6),
                                Container(
                                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: notifStyle.color.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Nueva',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: notifStyle.color,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        // Flecha de acción
                        if (_controller.hasAction(type)) ...[
                          SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right,
                            color: colorScheme.outlineVariant,
                            size: 22,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleCachedNotificationTap(
    String notificationId,
    String type,
    Map<String, dynamic> notifData,
    bool isRead,
  ) async {
    // Marcar como leída en cache local
    await _controller.markAsReadInCache(notificationId);

    // Actualizar UI
    if (mounted) {
      setState(() {});
    }

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

      case 'group_approval_request':
        // Navegar a pantalla de aprobación de grupos
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const GroupApprovalScreen(),
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

  Future<void> _markAllAsRead({bool showSnackbar = true}) async {
    // 1. Marcar en cache local (para UI instantánea)
    final markedCount = await _controller.markAllAsReadInCache();

    // 2. ✅ FIX: También marcar en Firestore (para que el badge se actualice)
    // Ejecutar en background sin esperar para no bloquear UI
    _controller.markAllAsRead().then((firestoreCount) {
      ReleaseLogger.log(
        '✅ Notificaciones marcadas en Firestore: $firestoreCount',
        tag: 'ChildNotifications',
      );
    });

    // Actualizar UI
    if (mounted) {
      setState(() {});
    }
  }
}
