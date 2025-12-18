import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../models/child.dart';
import '../../../../theme_service.dart';
import '../../../../services/dashboard_cache_service.dart';
import '../../../../services/permission_sync_service.dart';
import '../../../../widgets/synced_user_widgets.dart';
import '../../../child_location_screen.dart';
import '../../parent_main_shell.dart';
import '../../../story_approval_screen.dart';
import 'child_notifications_screen.dart';

class ChildDashboardCard extends StatefulWidget {
  final String childId;

  const ChildDashboardCard({
    super.key,
    required this.childId,
  });

  @override
  State<ChildDashboardCard> createState() => _ChildDashboardCardState();
}

class _ChildDashboardCardState extends State<ChildDashboardCard> {
  final _cacheService = DashboardCacheService();
  Child? _cachedChild;

  @override
  void initState() {
    super.initState();
    _loadChild();
  }

  Future<void> _loadChild() async {
    // 1. Intentar cargar desde cache primero (instantáneo)
    final cachedChild = await _cacheService.getChild(widget.childId);
    if (cachedChild != null && mounted) {
      setState(() {
        _cachedChild = cachedChild;
      });
    }

    // 2. Cargar desde Firestore en segundo plano
    try {
      final freshChild = await Child.getById(widget.childId);
      if (freshChild != null) {
        // 3. Actualizar cache con datos frescos
        await _cacheService.saveChild(freshChild);

        // 4. Actualizar UI
        if (mounted) {
          setState(() {
            _cachedChild = freshChild;
          });
        }
      }
    } catch (e) {
      // Error loading child - silent (will use cached data if available)
    }
  }

  @override
  Widget build(BuildContext context) {
    // Si no hay datos en cache, mostrar loading
    if (_cachedChild == null) {
      return Container(
        margin: EdgeInsets.only(bottom: 16),
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.customColors.gradientStart,
              context.customColors.gradientEnd,
            ],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final child = _cachedChild!;

    // OPCIÓN A: Diseño Adaptativo
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: isDarkMode
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF667eea), // Soft indigo
                  Color(0xFF764ba2), // Deep purple
                ],
              )
            : null,
        color: isDarkMode ? null : Theme.of(context).colorScheme.surfaceContainerHighest,
        border: isDarkMode
            ? null
            : Border.all(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                width: 2,
              ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: isDarkMode
                ? Color(0xFF667eea).withValues(alpha: 0.4)
                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            blurRadius: isDarkMode ? 15 : 12,
            offset: Offset(0, isDarkMode ? 8 : 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SyncedUserAvatar(
                userId: child.id,
                fallbackPhotoUrl: child.photoURL,
                userName: child.name,
                radius: 30,
                backgroundColor: isDarkMode
                    ? Colors.white.withValues(alpha: 0.3)
                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      child.name,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '${child.age} años',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDarkMode
                            ? Colors.white.withValues(alpha: 0.9)
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => ChildLocationScreen(
                        childId: child.id,
                        childName: child.name,
                      ),
                    ),
                  );
                },
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.25)
                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Stack(
                    children: [
                      // Mini mapa ilustrativo
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _MiniMapPainter(
                            isDarkMode: isDarkMode,
                            primaryColor: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      // Icono de ubicación centrado
                      Center(
                        child: Icon(
                          Icons.location_on,
                          color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.primary,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 20),
          Divider(
            color: isDarkMode
                ? Colors.white.withValues(alpha: 0.3)
                : Theme.of(context).colorScheme.outlineVariant,
            thickness: 1,
          ),
          SizedBox(height: 16),
          // Indicador de permisos faltantes
          _buildPermissionWarnings(context, child, isDarkMode),
          _buildQuickActions(context, child),
        ],
      ),
    );
  }

  Widget _buildPermissionWarnings(BuildContext context, Child child, bool isDarkMode) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: PermissionSyncService.watchPermissionStatus(child.id),
      builder: (context, snapshot) {
        final permissions = snapshot.data;

        // Si no hay datos de permisos, no mostrar nada (el hijo aún no sincronizó)
        if (permissions == null) {
          return SizedBox.shrink();
        }

        final locationEnabled = permissions['location'] == true;
        final contactsEnabled = permissions['contacts'] == true;

        // Si todos los permisos críticos están activados, no mostrar nada
        if (locationEnabled && contactsEnabled) {
          return SizedBox.shrink();
        }

        // Construir lista de permisos faltantes
        final missingPermissions = <String>[];
        if (!locationEnabled) missingPermissions.add('Ubicación');
        if (!contactsEnabled) missingPermissions.add('Contactos');

        return Container(
          margin: EdgeInsets.only(bottom: 12),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDarkMode
                ? Colors.orange.withValues(alpha: 0.2)
                : Colors.orange.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDarkMode
                  ? Colors.orange.withValues(alpha: 0.4)
                  : Colors.orange.shade200,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: isDarkMode ? Colors.orange.shade300 : Colors.orange.shade700,
                size: 18,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Permisos desactivados: ${missingPermissions.join(", ")}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDarkMode ? Colors.orange.shade200 : Colors.orange.shade800,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickActions(BuildContext context, Child child) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            context: context,
            icon: Icons.people,
            label: 'Contactos',
            color: Colors.blue,
            isDarkMode: isDarkMode,
            onTap: () {
              ParentMainShell.navigateToWhitelistWithFilter(child.id);
            },
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _buildActionButton(
            context: context,
            icon: Icons.photo_library,
            label: 'Historias',
            color: Colors.purple,
            isDarkMode: isDarkMode,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => StoryApprovalScreen(
                    childId: child.id,
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _buildNotificationsButton(
            context: context,
            child: child,
            isDarkMode: isDarkMode,
          ),
        ),
      ],
    );
  }

  Widget _buildNotificationsButton({
    required BuildContext context,
    required Child child,
    required bool isDarkMode,
  }) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      return _buildActionButton(
        context: context,
        icon: Icons.notifications,
        label: 'Alertas',
        color: Colors.orange,
        isDarkMode: isDarkMode,
        onTap: () {},
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: currentUserId)
          .where('read', isEqualTo: false)
          .snapshots(),
      builder: (context, snapshot) {
        // Contar notificaciones no leídas relacionadas a este hijo
        // EXCLUYENDO las notificaciones de mensajes de chat
        // ✅ FIX: Usar la MISMA lógica que ChildNotificationsController.filterNotificationsForChild
        int unreadCount = 0;
        if (snapshot.hasData) {
          final notifications = snapshot.data!.docs;

          for (final doc in notifications) {
            final data = doc.data() as Map<String, dynamic>;
            final notifData = data['data'] as Map<String, dynamic>?;
            final type = data['type'] as String?;

            // Filtrar notificaciones de chat (misma lógica que controller)
            if (type == 'chat_message') {
              continue; // Skip chat notifications
            }

            // ✅ FIX: Verificar si la notificación está relacionada con este hijo
            // SOLO usar campos que realmente identifican al hijo:
            // - notifData['childId']: La notificación es SOBRE este hijo
            // - notifData['senderId']: La notificación fue ENVIADA por este hijo
            // NO usar data['senderId'] ya que puede ser cualquier remitente
            final isRelated = notifData?['childId'] == child.id ||
                notifData?['senderId'] == child.id;

            if (isRelated) {
              unreadCount++;
            }
          }
        }

        return Material(
          color: isDarkMode
              ? Colors.white.withValues(alpha: 0.2)
              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ChildNotificationsScreen(
                    childId: child.id,
                    childName: child.name,
                  ),
                ),
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Icons.notifications,
                        color: isDarkMode
                            ? Colors.white
                            : Theme.of(context).colorScheme.primary,
                        size: 28,
                      ),
                      if (unreadCount > 0)
                        Positioned(
                          right: -8,
                          top: -4,
                          child: Container(
                            padding: EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: BoxConstraints(
                              minWidth: 18,
                              minHeight: 18,
                            ),
                            child: Text(
                              unreadCount > 9 ? '9+' : '$unreadCount',
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
                  SizedBox(height: 6),
                  Text(
                    'Alertas',
                    style: TextStyle(
                      color: isDarkMode
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required bool isDarkMode,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isDarkMode
          ? Colors.white.withValues(alpha: 0.2)
          : Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.primary,
                size: 28,
              ),
              SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Painter para dibujar un mini mapa ilustrativo
class _MiniMapPainter extends CustomPainter {
  final bool isDarkMode;
  final Color primaryColor;

  _MiniMapPainter({
    required this.isDarkMode,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Líneas de calles (ilustrativas)
    final streetPaint = Paint()
      ..color = isDarkMode
          ? Colors.white.withValues(alpha: 0.15)
          : primaryColor.withValues(alpha: 0.15)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Calle horizontal
    canvas.drawLine(
      Offset(0, size.height * 0.4),
      Offset(size.width, size.height * 0.4),
      streetPaint,
    );

    // Calle vertical
    canvas.drawLine(
      Offset(size.width * 0.6, 0),
      Offset(size.width * 0.6, size.height),
      streetPaint,
    );

    // Edificios/bloques pequeños (ilustrativos)
    final blockPaint = Paint()
      ..color = isDarkMode
          ? Colors.white.withValues(alpha: 0.1)
          : primaryColor.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    // Bloque superior izquierdo
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(8, 8, 18, 14),
        Radius.circular(3),
      ),
      blockPaint,
    );

    // Bloque inferior derecho
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width - 20, size.height - 18, 14, 12),
        Radius.circular(3),
      ),
      blockPaint,
    );

    // Punto de interés (pequeño círculo)
    canvas.drawCircle(
      Offset(size.width * 0.3, size.height * 0.7),
      3,
      Paint()
        ..color = isDarkMode
            ? Colors.white.withValues(alpha: 0.2)
            : primaryColor.withValues(alpha: 0.2),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
