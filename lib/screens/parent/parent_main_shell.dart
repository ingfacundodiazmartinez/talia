import 'dart:async';
import 'package:flutter/material.dart';
import 'dashboard/parent_dashboard_screen.dart';
import 'chats/parent_chats_screen.dart';
import 'contacts/parent_contacts_screen.dart';
import 'whitelist/whitelist_screen.dart';
import 'profile/parent_profile_screen.dart';
import 'group_invitations_screen.dart';
import '../chat_detail_screen.dart';
import '../group_chat_screen.dart';
import '../story_approval_screen.dart';
import '../../controllers/parent_main_shell_controller.dart';
import '../../utils/release_logger.dart';
import '../../notification_service.dart';

/// Clase para combinar todos los datos del BottomNavigationBar en un solo stream
class BottomNavData {
  final List<String> childrenIds;
  final int pendingStoriesCount;
  final int emergenciesCount;
  final int unreadChatsCount;
  final int unreadNotificationsCount;

  BottomNavData({
    required this.childrenIds,
    required this.pendingStoriesCount,
    required this.emergenciesCount,
    required this.unreadChatsCount,
    required this.unreadNotificationsCount,
  });

  int get dashboardBadgeCount => pendingStoriesCount + emergenciesCount;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BottomNavData &&
        other.childrenIds.length == childrenIds.length &&
        other.pendingStoriesCount == pendingStoriesCount &&
        other.emergenciesCount == emergenciesCount &&
        other.unreadChatsCount == unreadChatsCount &&
        other.unreadNotificationsCount == unreadNotificationsCount;
  }

  @override
  int get hashCode {
    return childrenIds.length.hashCode ^
        pendingStoriesCount.hashCode ^
        emergenciesCount.hashCode ^
        unreadChatsCount.hashCode ^
        unreadNotificationsCount.hashCode;
  }
}

/// Observer para detectar cambios en la navegación anidada
class _NavigatorObserver extends NavigatorObserver {
  final VoidCallback onNavigationChanged;

  _NavigatorObserver(this.onNavigationChanged);

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    onNavigationChanged();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    onNavigationChanged();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    onNavigationChanged();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    onNavigationChanged();
  }
}

/// Shell principal de la aplicación para padres
///
/// Responsabilidades:
/// - Proveer BottomNavigationBar para navegación principal
/// - Manejar navegación entre las 5 secciones principales
/// - Mantener el estado del tab seleccionado
///
/// NO contiene lógica de negocio, solo navegación UI
class ParentMainShell extends StatefulWidget {
  const ParentMainShell({super.key});

  @override
  State<ParentMainShell> createState() => _ParentMainShellState();
}

class _ParentMainShellState extends State<ParentMainShell> {
  // ✅ CORRECTO: Solo estado UI y controller
  int _selectedIndex = 0;
  late ParentMainShellController _controller;

  // ✅ OPTIMIZACIÓN: Stream combinado para evitar 5 StreamBuilders anidados
  StreamController<BottomNavData>? _bottomNavDataController;
  Stream<BottomNavData>? _bottomNavDataStream;
  List<StreamSubscription>? _subscriptions;

  // Helper method to get current user ID
  String _getCurrentUserId() {
    return _controller.currentUserId ?? '';
  }

  // GlobalKeys para mantener el estado de navegación de cada tab
  final GlobalKey<NavigatorState> _dashboardNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentDashboard');
  final GlobalKey<NavigatorState> _chatsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentChats');
  final GlobalKey<NavigatorState> _contactsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentContacts');
  final GlobalKey<NavigatorState> _whitelistNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentWhitelist');
  final GlobalKey<NavigatorState> _profileNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentProfile');

  @override
  void initState() {
    super.initState();
    // ✅ CORRECTO: Solo inicializar controller
    _controller = ParentMainShellController();

    // Configurar callbacks para navegación desde notificaciones
    _controller.onChatNotificationTap = _handleChatNotificationTap;
    _controller.onStoryApprovalNotificationTap = _handleStoryApprovalNotificationTap;

    _controller.initialize();

    // ✅ OPTIMIZACIÓN: Inicializar stream combinado
    _initializeCombinedStream();

    // ✅ FIX: Limpiar current_chat_id cuando llegas a ParentMainShell (lista de chats)
    // Esto asegura que las notificaciones se muestren correctamente
    NotificationService().clearCurrentChat();
  }


  @override
  void dispose() {
    // ✅ OPTIMIZACIÓN: Disponer streams combinados
    _disposeCombinedStream();

    // ✅ CORRECTO: Solo disponer controller
    _controller.dispose();
    super.dispose();
  }



  Future<void> _handleChatNotificationTap(Map<String, dynamic> data) async {
    try {
      final groupId = data['groupId'] as String?;
      final chatId = data['chatId'] as String?;
      final isGroup = data['isGroup'] == true || data['isGroup'] == 'true';

      // ✅ FIX: Verificar si el chat ya está abierto para evitar navegación duplicada
      final currentOpenChatId = NotificationService().currentChatId;

      // Primero cambiar al tab de chats
      setState(() => _selectedIndex = 1);

      // Determinar si es un chat grupal o 1-on-1
      // Si isGroup es true, el chatId es en realidad el groupId
      if (groupId != null || (isGroup && chatId != null)) {
        // Notificación de mensaje grupal
        final effectiveGroupId = groupId ?? chatId!;
        final groupName = data['groupName'] as String? ?? 'Grupo';

        // ✅ FIX: Si el grupo ya está abierto, no navegar de nuevo
        if (currentOpenChatId == effectiveGroupId) {
          ReleaseLogger.log('⚠️ [ParentMainShell] Grupo $effectiveGroupId ya está abierto - SALTANDO navegación duplicada', tag: 'ParentMainShell');
          return;
        }

        ReleaseLogger.log('Navigating to group chat: $groupName (groupId: $effectiveGroupId)', tag: 'ParentMainShell');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatScreen(
              groupId: effectiveGroupId,
              groupName: groupName,
            ),
          ),
        );
      } else if (chatId != null) {
        // Notificación de mensaje 1-on-1
        final senderId = data['senderId'] as String?;

        if (senderId == null) {
          ReleaseLogger.warning('Missing senderId in notification data', tag: 'ParentMainShell');
          return;
        }

        // ✅ CORRECTO: Usar controller para obtener datos
        final contactInfo = await _controller.getContactInfo(senderId);
        final correctChatId = _controller.getChatId(senderId);

        // ✅ FIX: Si el chat ya está abierto, no navegar de nuevo
        if (currentOpenChatId == correctChatId) {
          ReleaseLogger.log('⚠️ [ParentMainShell] Chat $correctChatId ya está abierto - SALTANDO navegación duplicada', tag: 'ParentMainShell');
          return;
        }

        ReleaseLogger.log('Fetching contact info for senderId: $senderId', tag: 'ParentMainShell');
        ReleaseLogger.log('Navigating to 1-on-1 chat with ${contactInfo.name}', tag: 'ParentMainShell');
        ReleaseLogger.log('Notification chatId: $chatId', tag: 'ParentMainShell');
        ReleaseLogger.log('Correct chatId: $correctChatId', tag: 'ParentMainShell');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              contactId: senderId,
              contactName: contactInfo.name,
              chatId: correctChatId,
            ),
          ),
        );
      } else {
        ReleaseLogger.warning('Missing both groupId and chatId in notification data', tag: 'ParentMainShell');
      }
    } catch (e) {
      ReleaseLogger.error('Error handling chat notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de aprobación de historia
  Future<void> _handleStoryApprovalNotificationTap(Map<String, dynamic> data) async {
    try {
      ReleaseLogger.log('Navigating to story approval screen from notification', tag: 'ParentMainShell');

      // Extraer childId de la notificación si existe
      final notifData = data['data'] as Map<String, dynamic>?;
      final childId = notifData?['childId'] as String?;

      // Navegar a la pantalla de aprobación de historias
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => StoryApprovalScreen(
            childId: childId, // Filtrar por hijo específico si viene en la notificación
          ),
        ),
      );
    } catch (e) {
      ReleaseLogger.error('Error handling story approval notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Construye un Navigator para un tab específico
  Widget _buildNavigator(GlobalKey<NavigatorState> key, Widget child) {
    return Navigator(
      key: key,
      pages: [
        MaterialPage(
          key: ValueKey('tab_root'),
          child: child,
        ),
      ],
      onPopPage: (route, result) {
        if (!route.didPop(result)) {
          return false;
        }
        return true;
      },
      observers: [_NavigatorObserver(_onNavigationChanged)],
    );
  }

  /// Callback cuando cambia la navegación en cualquier tab
  void _onNavigationChanged() {
    // Usar addPostFrameCallback para evitar llamar setState durante build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          // Rebuild para actualizar visibilidad del bottom nav bar
        });
      }
    });
  }

  /// Verifica si el tab actual tiene rutas push (para ocultar bottom nav bar)
  bool get _hasNestedRoute {
    GlobalKey<NavigatorState> currentKey;
    switch (_selectedIndex) {
      case 0:
        currentKey = _dashboardNavigatorKey;
        break;
      case 1:
        currentKey = _chatsNavigatorKey;
        break;
      case 2:
        currentKey = _contactsNavigatorKey;
        break;
      case 3:
        currentKey = _whitelistNavigatorKey;
        break;
      case 4:
        currentKey = _profileNavigatorKey;
        break;
      default:
        return false;
    }
    final navigator = currentKey.currentState;
    if (navigator == null) return false;
    // Si el navigator puede hacer pop, significa que hay rutas anidadas
    return navigator.canPop();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = _getCurrentUserId();

    return PopScope(
      canPop: false,
      onPopInvoked: (bool didPop) async {
        if (didPop) return;

        // Si hay navegación anidada, hacer pop en el navegador del tab actual
        if (_hasNestedRoute) {
          GlobalKey<NavigatorState> currentKey;
          switch (_selectedIndex) {
            case 0:
              currentKey = _dashboardNavigatorKey;
              break;
            case 1:
              currentKey = _chatsNavigatorKey;
              break;
            case 2:
              currentKey = _contactsNavigatorKey;
              break;
            case 3:
              currentKey = _whitelistNavigatorKey;
              break;
            case 4:
              currentKey = _profileNavigatorKey;
              break;
            default:
              currentKey = _dashboardNavigatorKey;
          }

          if (currentKey.currentState?.canPop() ?? false) {
            currentKey.currentState!.pop();
            return;
          }
        }

        // Si estamos en otro tab que no sea Dashboard (0), volver al tab de Dashboard
        if (_selectedIndex != 0) {
          setState(() => _selectedIndex = 0);
          return;
        }

        // Si estamos en el tab de Dashboard y no hay navegación anidada, salir de la app
        // (El sistema Android manejará la salida)
      },
      child: Scaffold(
      body: Stack(
        children: [
          Offstage(
            offstage: _selectedIndex != 0,
            child: _buildNavigator(_dashboardNavigatorKey, ParentDashboardScreen()),
          ),
          Offstage(
            offstage: _selectedIndex != 1,
            child: _buildNavigator(_chatsNavigatorKey, ParentChatsScreen()),
          ),
          Offstage(
            offstage: _selectedIndex != 2,
            child: _buildNavigator(_contactsNavigatorKey, ParentContactsScreen()),
          ),
          Offstage(
            offstage: _selectedIndex != 3,
            child: _buildNavigator(_whitelistNavigatorKey, WhitelistScreen()),
          ),
          Offstage(
            offstage: _selectedIndex != 4,
            child: _buildNavigator(_profileNavigatorKey, ParentProfileScreen()),
          ),
        ],
      ),
      // Ocultar bottom nav bar cuando hay rutas anidadas (ej: chat abierto)
      bottomNavigationBar: _hasNestedRoute ? null : _buildBottomNavigationBar(),
      // ✅ CORRECTO: Usar controller para datos de floating action button
      floatingActionButton: StreamBuilder<int>(
              stream: _controller.getPendingGroupInvitationsStream(),
              builder: (context, snapshot) {
                final count = snapshot.data ?? 0;
                if (count == 0) return const SizedBox.shrink();

                return Badge(
                  label: Text(count.toString()),
                  child: FloatingActionButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const GroupInvitationsScreen(),
                        ),
                      );
                    },
                    tooltip: 'Invitaciones a Grupos ($count)',
                    child: const Icon(Icons.group_add),
                  ),
                );
              },
            ),
      ),
    );
  }

  /// Construye el BottomNavigationBar con las 5 secciones principales
  Widget _buildBottomNavigationBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    // Con 5 tabs necesitamos más espacio - aumentar umbral para dispositivos pequeños
    final showLabels = screenWidth >= 430;
    final currentUserId = _getCurrentUserId();

    if (currentUserId.isEmpty) {
      return Container(); // Usuario no autenticado
    }

    // ✅ OPTIMIZACIÓN: Un solo StreamBuilder en lugar de 5 anidados
    if (_bottomNavDataStream == null) {
      // Fallback mientras se inicializa el stream combinado
      return _buildBottomNavBar(colorScheme, showLabels, 0, 0, 0);
    }

    return StreamBuilder<BottomNavData>(
      stream: _bottomNavDataStream!,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          // Mientras no tengamos datos, mostrar sin badges
          return _buildBottomNavBar(colorScheme, showLabels, 0, 0, 0);
        }

        final data = snapshot.data!;

        return _buildBottomNavBar(
          colorScheme,
          showLabels,
          data.dashboardBadgeCount,
          data.unreadChatsCount,
          data.unreadNotificationsCount,
        );
      },
    );
  }

  /// Construye el widget del BottomNavigationBar
  Widget _buildBottomNavBar(
    ColorScheme colorScheme,
    bool showLabels,
    int dashboardBadgeCount,
    int totalUnreadMessages,
    int whitelistBadgeCount,
  ) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: Offset(0, -5),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        showSelectedLabels: showLabels,
        showUnselectedLabels: showLabels,
        items: [
          BottomNavigationBarItem(
            icon: _buildIconWithBadge(
              Icons.dashboard_outlined,
              dashboardBadgeCount, // ✅ Historias pendientes + emergencias no resueltas
            ),
            activeIcon: _buildIconWithBadge(
              Icons.dashboard,
              dashboardBadgeCount,
            ),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: _buildIconWithBadge(
              Icons.chat_bubble_outline,
              totalUnreadMessages, // ✅ Chats no leídos
            ),
            activeIcon: _buildIconWithBadge(
              Icons.chat_bubble,
              totalUnreadMessages,
            ),
            label: 'Chats',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people_outline),
            activeIcon: Icon(Icons.people),
            label: 'Contactos',
          ),
          BottomNavigationBarItem(
            icon: _buildIconWithBadge(
              Icons.shield_outlined,
              whitelistBadgeCount, // ✅ Solicitudes de contacto pendientes
            ),
            activeIcon: _buildIconWithBadge(
              Icons.shield,
              whitelistBadgeCount,
            ),
            label: 'Lista Blanca',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Perfil',
          ),
        ],
      ),
    );
  }

  /// ✅ OPTIMIZACIÓN: Inicializar stream combinado para evitar 5 StreamBuilders anidados
  void _initializeCombinedStream() {
    _bottomNavDataController = StreamController<BottomNavData>.broadcast();
    _bottomNavDataStream = _bottomNavDataController!.stream;
    _subscriptions = [];

    // Variables para mantener el estado actual de cada stream
    List<String> currentChildrenIds = [];
    int currentPendingStories = 0;
    int currentEmergencies = 0;
    int currentUnreadChats = 0;
    int currentUnreadNotifications = 0;

    void emitCombinedData() {
      if (!_bottomNavDataController!.isClosed) {
        final data = BottomNavData(
          childrenIds: currentChildrenIds,
          pendingStoriesCount: currentPendingStories,
          emergenciesCount: currentEmergencies,
          unreadChatsCount: currentUnreadChats,
          unreadNotificationsCount: currentUnreadNotifications,
        );
        _bottomNavDataController!.add(data);
      }
    }

    // 1. Escuchar cambios en datos del usuario (linkedChildrenIds)
    _subscriptions!.add(
      _controller.getCurrentUserStream().listen((userSnapshot) {
        if (userSnapshot.exists) {
          final userData = userSnapshot.data() as Map<String, dynamic>?;
          currentChildrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);
          emitCombinedData();
        }
      })
    );

    // 2. Escuchar cambios en historias pendientes
    _subscriptions!.add(
      _controller.getPendingStoryRequestsStream().listen((count) {
        currentPendingStories = count;
        emitCombinedData();
      })
    );

    // 3. Escuchar cambios en emergencias activas
    _subscriptions!.add(
      _controller.getActiveEmergenciesStream(currentChildrenIds).listen((count) {
        currentEmergencies = count;
        emitCombinedData();
      })
    );

    // 4. Escuchar cambios en chats no leídos
    _subscriptions!.add(
      _controller.getUnreadChatsStream().listen((count) {
        currentUnreadChats = count;
        emitCombinedData();
      })
    );

    // 5. Escuchar cambios en notificaciones no leídas
    _subscriptions!.add(
      _controller.getUnreadNotificationsStream().listen((count) {
        currentUnreadNotifications = count;
        emitCombinedData();
      })
    );
  }

  /// ✅ OPTIMIZACIÓN: Disponer stream combinado
  void _disposeCombinedStream() {
    _subscriptions?.forEach((sub) => sub.cancel());
    _subscriptions?.clear();
    _bottomNavDataController?.close();
    _bottomNavDataController = null;
    _bottomNavDataStream = null;
  }

  /// Construye un ícono con badge si el count > 0
  Widget _buildIconWithBadge(IconData icon, int count) {
    if (count == 0) {
      return Icon(icon);
    }

    return Badge(
      label: Text(count > 99 ? '99+' : count.toString()),
      child: Icon(icon),
    );
  }
}
