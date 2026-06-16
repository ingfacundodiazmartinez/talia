import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../models/child.dart';
import '../../../../theme_service.dart';
import '../../../../services/dashboard_cache_service.dart';
import '../../../../services/notification_query_service.dart';
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

        // Obtener estados granulares (con fallback a legacy)
        final locationState = PermissionSyncService.parseLocationState(
          permissions['locationState'] as String?,
        );
        final contactsState = PermissionSyncService.parseContactsState(
          permissions['contactsState'] as String?,
        );
        final devicePlatform = permissions['devicePlatform'] as String? ?? 'Android';

        // Fallback a campos legacy si no hay estados granulares
        final locationOk = locationState == LocationPermissionState.always ||
            (permissions['locationState'] == null && permissions['location'] == true);
        final contactsOk = contactsState == ContactsPermissionState.full ||
            (permissions['contactsState'] == null && permissions['contacts'] == true);

        // Si todos los permisos críticos están OK, no mostrar nada
        if (locationOk && contactsOk) {
          return SizedBox.shrink();
        }

        // Determinar color y mensaje según el estado
        final (warningColor, warningMessage) = _getWarningDetails(
          locationState: locationState,
          contactsState: contactsState,
          locationOk: locationOk,
          contactsOk: contactsOk,
        );

        return Container(
          margin: EdgeInsets.only(bottom: 12),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isDarkMode
                ? warningColor.withValues(alpha: 0.2)
                : warningColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDarkMode
                  ? warningColor.withValues(alpha: 0.4)
                  : warningColor.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                _getWarningIcon(locationState, contactsState),
                color: isDarkMode ? warningColor.withValues(alpha: 0.9) : warningColor,
                size: 20,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  warningMessage,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDarkMode
                        ? warningColor.withValues(alpha: 0.9)
                        : warningColor.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              // Icono de info para mostrar instrucciones
              GestureDetector(
                onTap: () => _showPermissionHelpSheet(
                  context,
                  locationState: locationState,
                  contactsState: contactsState,
                  devicePlatform: devicePlatform,
                  childName: child.name,
                  locationLegacy: permissions['location'] as bool?,
                  contactsLegacy: permissions['contacts'] as bool?,
                ),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.1)
                        : warningColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.help_outline_rounded,
                    color: isDarkMode ? Colors.white70 : warningColor,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Determina el color y mensaje según el estado de los permisos
  (Color, String) _getWarningDetails({
    required LocationPermissionState locationState,
    required ContactsPermissionState contactsState,
    required bool locationOk,
    required bool contactsOk,
  }) {
    // Priorizar ubicación porque es más crítica para la app
    if (!locationOk) {
      switch (locationState) {
        case LocationPermissionState.whenInUse:
          return (
            Colors.amber.shade700,
            'Ubicación parcial: solo funciona con la app abierta'
          );
        case LocationPermissionState.denied:
          return (
            Colors.orange.shade700,
            'Ubicación desactivada: no se puede rastrear'
          );
        case LocationPermissionState.restricted:
          return (
            Colors.red.shade600,
            'Ubicación restringida por control parental'
          );
        default:
          if (!contactsOk) {
            return (
              Colors.orange.shade700,
              'Permisos faltantes: Ubicación y Contactos'
            );
          }
          return (
            Colors.orange.shade700,
            'Ubicación desactivada'
          );
      }
    }

    // Solo contactos tienen problemas
    if (!contactsOk) {
      switch (contactsState) {
        case ContactsPermissionState.limited:
          return (
            Colors.amber.shade700,
            'Contactos: acceso limitado'
          );
        case ContactsPermissionState.denied:
          return (
            Colors.orange.shade700,
            'Contactos desactivados'
          );
        case ContactsPermissionState.restricted:
          return (
            Colors.red.shade600,
            'Contactos restringidos por control parental'
          );
        default:
          return (
            Colors.orange.shade700,
            'Contactos desactivados'
          );
      }
    }

    return (Colors.orange.shade700, 'Permisos incompletos');
  }

  /// Determina el icono según el estado
  IconData _getWarningIcon(
    LocationPermissionState locationState,
    ContactsPermissionState contactsState,
  ) {
    if (locationState == LocationPermissionState.restricted ||
        contactsState == ContactsPermissionState.restricted) {
      return Icons.block_rounded;
    }
    if (locationState == LocationPermissionState.whenInUse ||
        contactsState == ContactsPermissionState.limited) {
      return Icons.warning_amber_rounded;
    }
    return Icons.error_outline_rounded;
  }

  /// Muestra un bottom sheet con instrucciones para activar permisos
  void _showPermissionHelpSheet(
    BuildContext context, {
    required LocationPermissionState locationState,
    required ContactsPermissionState contactsState,
    required String devicePlatform,
    required String childName,
    bool? locationLegacy,
    bool? contactsLegacy,
  }) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isIOS = devicePlatform == 'iOS';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Título
            Text(
              '¿Por qué necesitamos estos permisos?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Estos permisos son necesarios para proteger a $childName',
              style: TextStyle(
                fontSize: 13,
                color: isDarkMode ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
            SizedBox(height: 20),

            // Explicación de ubicación
            if (locationState != LocationPermissionState.always) ...[
              _buildPermissionExplanation(
                context,
                icon: Icons.location_on_outlined,
                title: 'Ubicación en segundo plano',
                currentState: _getLocationStateText(locationState, locationLegacy),
                stateColor: _getLocationStateColor(locationState, locationLegacy),
                reason: 'Permite ver dónde está $childName en tiempo real, '
                    'incluso cuando no tiene la app abierta.',
                howToFix: isIOS
                    ? 'En el iPhone de $childName:\n'
                        '1. Ir a Ajustes → Tália\n'
                        '2. Tocar "Ubicación"\n'
                        '3. Seleccionar "Siempre"'
                    : 'En el teléfono de $childName:\n'
                        '1. Ir a Ajustes → Apps → Tália\n'
                        '2. Tocar "Permisos" → "Ubicación"\n'
                        '3. Seleccionar "Permitir siempre"',
                isDarkMode: isDarkMode,
              ),
              SizedBox(height: 16),
            ],

            // Explicación de contactos
            if (contactsState != ContactsPermissionState.full) ...[
              _buildPermissionExplanation(
                context,
                icon: Icons.contacts_outlined,
                title: 'Acceso a contactos',
                currentState: _getContactsStateText(contactsState, contactsLegacy),
                stateColor: _getContactsStateColor(contactsState, contactsLegacy),
                reason: 'Permite verificar que $childName solo hable con '
                    'contactos aprobados.',
                howToFix: isIOS
                    ? 'En el iPhone de $childName:\n'
                        '1. Ir a Ajustes → Tália\n'
                        '2. Tocar "Contactos"\n'
                        '3. Seleccionar "Acceso completo"'
                    : 'En el teléfono de $childName:\n'
                        '1. Ir a Ajustes → Apps → Tália\n'
                        '2. Tocar "Permisos" → "Contactos"\n'
                        '3. Activar el permiso',
                isDarkMode: isDarkMode,
              ),
            ],

            SizedBox(height: 20),

            // Nota sobre dispositivo
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDarkMode
                    ? Colors.blue.withValues(alpha: 0.1)
                    : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    isIOS ? Icons.phone_iphone : Icons.phone_android,
                    color: Colors.blue,
                    size: 20,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$childName usa $devicePlatform',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDarkMode ? Colors.blue.shade300 : Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionExplanation(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String currentState,
    required Color stateColor,
    required String reason,
    required String howToFix,
    required bool isDarkMode,
  }) {
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDarkMode
            ? Colors.grey.shade800.withValues(alpha: 0.5)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con estado actual
          Row(
            children: [
              Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  currentState,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          // Por qué
          Text(
            reason,
            style: TextStyle(
              fontSize: 13,
              color: isDarkMode ? Colors.grey.shade300 : Colors.grey.shade700,
            ),
          ),
          SizedBox(height: 12),
          // Cómo activar
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDarkMode
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.green.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16,
                        color: isDarkMode
                            ? Colors.green.shade400
                            : Colors.green.shade600),
                    SizedBox(width: 6),
                    Text(
                      'Cómo activarlo:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        // ✅ Contraste: verde claro en dark mode, oscuro en light.
                        color: isDarkMode
                            ? Colors.green.shade300
                            : Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6),
                Text(
                  howToFix,
                  style: TextStyle(
                    fontSize: 12,
                    // ✅ Antes shade800 (verde oscuro sobre fondo oscuro) = ilegible.
                    color: isDarkMode
                        ? Colors.green.shade200
                        : Colors.green.shade800,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getLocationStateText(LocationPermissionState state, bool? legacyValue) {
    switch (state) {
      case LocationPermissionState.always:
        return 'Activado';
      case LocationPermissionState.whenInUse:
        return 'Solo en uso';
      case LocationPermissionState.denied:
        return 'Denegado';
      case LocationPermissionState.restricted:
        return 'Restringido';
      case LocationPermissionState.unknown:
        // Usar valor legacy si está disponible
        if (legacyValue == true) return 'Activado';
        if (legacyValue == false) return 'Denegado';
        return 'Pendiente';
    }
  }

  Color _getLocationStateColor(LocationPermissionState state, bool? legacyValue) {
    switch (state) {
      case LocationPermissionState.always:
        return Colors.green;
      case LocationPermissionState.whenInUse:
        return Colors.amber.shade700;
      case LocationPermissionState.denied:
        return Colors.orange.shade700;
      case LocationPermissionState.restricted:
        return Colors.red.shade600;
      case LocationPermissionState.unknown:
        // Usar valor legacy si está disponible
        if (legacyValue == true) return Colors.green;
        if (legacyValue == false) return Colors.orange.shade700;
        return Colors.grey;
    }
  }

  String _getContactsStateText(ContactsPermissionState state, bool? legacyValue) {
    switch (state) {
      case ContactsPermissionState.full:
        return 'Activado';
      case ContactsPermissionState.limited:
        return 'Limitado';
      case ContactsPermissionState.denied:
        return 'Denegado';
      case ContactsPermissionState.restricted:
        return 'Restringido';
      case ContactsPermissionState.unknown:
        // Usar valor legacy si está disponible
        if (legacyValue == true) return 'Activado';
        if (legacyValue == false) return 'Denegado';
        return 'Pendiente';
    }
  }

  Color _getContactsStateColor(ContactsPermissionState state, bool? legacyValue) {
    switch (state) {
      case ContactsPermissionState.full:
        return Colors.green;
      case ContactsPermissionState.limited:
        return Colors.amber.shade700;
      case ContactsPermissionState.denied:
        return Colors.orange.shade700;
      case ContactsPermissionState.restricted:
        return Colors.red.shade600;
      case ContactsPermissionState.unknown:
        // Usar valor legacy si está disponible
        if (legacyValue == true) return Colors.green;
        if (legacyValue == false) return Colors.orange.shade700;
        return Colors.grey;
    }
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
        label: 'Notificaciones',
        color: Colors.orange,
        isDarkMode: isDarkMode,
        onTap: () {},
      );
    }

    final notificationService = NotificationQueryService();

    return StreamBuilder<QuerySnapshot>(
      stream: notificationService.watchUnreadNotifications(currentUserId),
      builder: (context, snapshot) {
        // Contar notificaciones no leidas relacionadas a este hijo
        // usando el servicio que encapsula la logica de filtrado
        int unreadCount = 0;
        if (snapshot.hasData) {
          unreadCount = notificationService.countUnreadForChild(
            snapshot.data!,
            child.id,
          );
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
                    'Notificaciones',
                    style: TextStyle(
                      color: isDarkMode
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                      fontSize: 11,
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
