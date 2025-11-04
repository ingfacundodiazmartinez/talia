import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'dashboard/parent_dashboard_screen.dart';
import 'chats/parent_chats_screen.dart';
import 'contacts/parent_contacts_screen.dart';
import 'whitelist/whitelist_screen.dart';
import 'profile/parent_profile_screen.dart';
import 'group_invitations_screen.dart';
import '../chat_detail_screen.dart';
import '../group_chat_screen.dart';
import '../../controllers/parent_main_shell_controller.dart';

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
    final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser!.uid;
    _controller = ParentMainShellController(
      parentId: currentUserId,
    );

    // Configurar callback para navegación desde notificaciones
    _controller.onChatNotificationTap = _handleChatNotificationTap;

    _controller.initialize();
  }


  @override
  void dispose() {
    // ✅ CORRECTO: Solo disponer controller
    _controller.dispose();
    super.dispose();
  }



  Future<void> _handleChatNotificationTap(Map<String, dynamic> data) async {
    try {
      final groupId = data['groupId'] as String?;
      final chatId = data['chatId'] as String?;
      final isGroup = data['isGroup'] == true || data['isGroup'] == 'true';

      // Primero cambiar al tab de chats
      setState(() => _selectedIndex = 1);

      // Determinar si es un chat grupal o 1-on-1
      // Si isGroup es true, el chatId es en realidad el groupId
      if (groupId != null || (isGroup && chatId != null)) {
        // Notificación de mensaje grupal
        final effectiveGroupId = groupId ?? chatId!;
        final groupName = data['groupName'] as String? ?? 'Grupo';
        print('✅ [ParentMainShell] Navigating to group chat: $groupName (groupId: $effectiveGroupId)');

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
          print('⚠️ [ParentMainShell] Missing senderId in notification data');
          return;
        }

        print('📂 [ParentMainShell] Fetching contact info for senderId: $senderId');

        // ✅ CORRECTO: Usar controller para obtener datos
        final contactInfo = await _controller.getContactInfo(senderId);
        final correctChatId = _controller.getChatId(senderId);

        print('✅ [ParentMainShell] Navigating to 1-on-1 chat with ${contactInfo.name}');
        print('   Notification chatId: $chatId');
        print('   Correct chatId: $correctChatId');

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
        print('⚠️ [ParentMainShell] Missing both groupId and chatId in notification data');
      }
    } catch (e) {
      print('❌ [ParentMainShell] Error handling chat notification tap: $e');
    }
  }

  /// Construye un Navigator para un tab específico
  Widget _buildNavigator(GlobalKey<NavigatorState> key, Widget child) {
    return Navigator(
      key: key,
      onGenerateRoute: (RouteSettings settings) {
        return MaterialPageRoute(
          builder: (BuildContext context) => child,
        );
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
      floatingActionButton: currentUserId != null
          ? StreamBuilder<int>(
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
                    child: const Icon(Icons.group_add),
                    tooltip: 'Invitaciones a Grupos ($count)',
                  ),
                );
              },
            )
          : null,
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

    // ✅ CORRECTO: Usar controller streams en lugar de queries directas
    return StreamBuilder<DocumentSnapshot>(
      stream: _controller.getCurrentUserStream(),
      builder: (context, userSnapshot) {
        List<String> childrenIds = [];
        if (userSnapshot.hasData && userSnapshot.data != null) {
          final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
          if (userData != null) {
            childrenIds = List<String>.from(userData['linkedChildrenIds'] ?? []);
          }
        }

        // Dashboard badge: historias pendientes + emergencias activas
        return StreamBuilder<int>(
          stream: _controller.getPendingStoryRequestsStream(),
          builder: (context, storiesSnapshot) {
            final pendingStoriesCount = storiesSnapshot.data ?? 0;

            return StreamBuilder<int>(
              stream: _controller.getActiveEmergenciesStream(childrenIds),
              builder: (context, emergenciesSnapshot) {
                final emergenciesCount = emergenciesSnapshot.data ?? 0;
                final dashboardBadgeCount = pendingStoriesCount + emergenciesCount;

                // Chats badge: chats no leídos
                return StreamBuilder<int>(
                  stream: _controller.getUnreadChatsStream(),
                  builder: (context, chatsSnapshot) {
                    final unreadChatsCount = chatsSnapshot.data ?? 0;

                    // Whitelist badge: notificaciones no leídas
                    return StreamBuilder<int>(
                      stream: _controller.getUnreadNotificationsStream(),
                      builder: (context, notificationsSnapshot) {
                        final unreadNotificationsCount = notificationsSnapshot.data ?? 0;

                        return _buildBottomNavBar(
                          colorScheme,
                          showLabels,
                          dashboardBadgeCount,
                          unreadChatsCount,
                          unreadNotificationsCount,
                        );
                      },
                    );
                  },
                );
              },
            );
          },
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
