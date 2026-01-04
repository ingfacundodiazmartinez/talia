import 'dart:async';
import 'package:flutter/material.dart';
import 'dashboard/parent_dashboard_screen.dart';
import 'chats/parent_chats_screen.dart';
import 'contacts/parent_contacts_screen.dart';
import 'whitelist/whitelist_screen.dart';
import 'profile/parent_profile_screen.dart';
import 'group_invitations_screen.dart';
import '../chat_detail_screen.dart';
import '../../groups/groups.dart'; // Groups V2
import '../story_approval_screen.dart';
import '../trivia/trivia_results_screen.dart';
import 'dashboard/widgets/child_notifications_screen.dart';
import '../../controllers/parent_main_shell_controller.dart';
import '../../utils/release_logger.dart';
import '../../notification_service.dart';
import '../../reports_screen.dart';

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

  /// GlobalKey para acceder al estado del shell desde otros widgets
  static final GlobalKey<_ParentMainShellState> shellKey =
      GlobalKey<_ParentMainShellState>();

  /// Navegar al tab de whitelist con un filtro de hijo específico
  static void navigateToWhitelistWithFilter(String childId) {
    WhitelistScreen.setChildFilter(childId);
    shellKey.currentState?._navigateToTab(3);
  }

  @override
  State<ParentMainShell> createState() => _ParentMainShellState();
}

class _ParentMainShellState extends State<ParentMainShell> {
  // ✅ CORRECTO: Solo estado UI y controller
  int _selectedIndex = 0;

  /// Navegar a un tab específico
  void _navigateToTab(int index) {
    if (mounted) {
      setState(() => _selectedIndex = index);
    }
  }
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
    _controller.onGroupApprovalNotificationTap = _handleGroupApprovalNotificationTap;
    _controller.onStoryNotificationTap = _handleStoryNotificationTap;
    _controller.onContactApprovedNotificationTap = _handleContactApprovedNotificationTap;
    _controller.onContactRequestNotificationTap = _handleContactRequestNotificationTap;
    _controller.onAlertNotificationTap = _handleAlertNotificationTap;
    _controller.onReportNotificationTap = _handleReportNotificationTap;
    _controller.onEmergencyNotificationTap = _handleEmergencyNotificationTap;
    _controller.onGroupMembershipApprovedNotificationTap = _handleGroupMembershipApprovedNotificationTap;
    _controller.onTriviaNotificationTap = _handleTriviaNotificationTap;

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
            builder: (context) => GroupChatScreenV2(
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

  /// Manejar tap en notificación de aprobación de grupo
  Future<void> _handleGroupApprovalNotificationTap(Map<String, dynamic> data) async {
    try {
      ReleaseLogger.log('Navigating to group approval screen from notification', tag: 'ParentMainShell');

      // Navegar a la pantalla de aprobación de grupos
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const GroupApprovalScreen(),
        ),
      );
    } catch (e) {
      ReleaseLogger.error('Error handling group approval notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de historia (approved/rejected/reply/new_story)
  Future<void> _handleStoryNotificationTap(Map<String, dynamic> data) async {
    try {
      final storyId = data['storyId'] as String?;
      final storyOwnerId = data['storyOwnerId'] as String? ?? data['userId'] as String?;
      final type = data['type'] as String?;

      ReleaseLogger.log('Story notification tap: type=$type, storyId=$storyId, ownerId=$storyOwnerId', tag: 'ParentMainShell');

      // Navegar al dashboard donde las historias son visibles
      // El StoryViewerScreen requiere cargar las historias del usuario primero
      // Por ahora, llevamos al usuario al dashboard para ver historias
      setState(() => _selectedIndex = 0);
    } catch (e) {
      ReleaseLogger.error('Error handling story notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de contacto aprobado
  Future<void> _handleContactApprovedNotificationTap(Map<String, dynamic> data) async {
    try {
      ReleaseLogger.log('Navigating to contacts tab from notification', tag: 'ParentMainShell');
      // Cambiar al tab de contactos
      setState(() => _selectedIndex = 2);
    } catch (e) {
      ReleaseLogger.error('Error handling contact approved notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de solicitud de contacto
  Future<void> _handleContactRequestNotificationTap(Map<String, dynamic> data) async {
    try {
      final childId = data['childId'] as String?;
      ReleaseLogger.log('Navigating to whitelist screen (pendientes) from notification, childId=$childId', tag: 'ParentMainShell');

      // Cambiar al tab de whitelist
      setState(() => _selectedIndex = 3);

      // Navegar a la pantalla de whitelist con tab de pendientes
      // WhitelistScreen tiene 3 tabs: Pendientes (0), Aprobadas (1), Rechazadas (2)
      // Por ahora solo cambiamos al tab, la pantalla manejará mostrar pendientes por defecto
    } catch (e) {
      ReleaseLogger.error('Error handling contact request notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de alerta (actividad/bullying)
  Future<void> _handleAlertNotificationTap(Map<String, dynamic> data) async {
    try {
      final childId = data['childId'] as String?;
      final childName = data['childName'] as String? ?? 'Hijo';
      ReleaseLogger.log('Navigating to child notifications screen, childId=$childId', tag: 'ParentMainShell');

      if (childId != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChildNotificationsScreen(
              childId: childId,
              childName: childName,
            ),
          ),
        );
      } else {
        // Si no hay childId, ir al dashboard
        setState(() => _selectedIndex = 0);
      }
    } catch (e) {
      ReleaseLogger.error('Error handling alert notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de reporte listo
  Future<void> _handleReportNotificationTap(Map<String, dynamic> data) async {
    try {
      final childId = data['childId'] as String?;
      ReleaseLogger.log('Navigating to reports screen, childId=$childId', tag: 'ParentMainShell');

      // Navegar a la pantalla de reportes (con childId opcional para filtrar)
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ReportsScreen(childId: childId),
        ),
      );
    } catch (e) {
      ReleaseLogger.error('Error handling report notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de emergencia
  Future<void> _handleEmergencyNotificationTap(Map<String, dynamic> data) async {
    try {
      final emergencyId = data['emergencyId'] as String?;
      ReleaseLogger.log('Navigating to emergency detail screen, emergencyId=$emergencyId', tag: 'ParentMainShell');

      // Navegar al dashboard donde se muestran las emergencias
      // El EmergencyDetailScreen requiere emergencyData que no viene en la notificación
      // El dashboard mostrará la alerta de emergencia y permitirá navegar al detalle
      setState(() => _selectedIndex = 0);
    } catch (e) {
      ReleaseLogger.error('Error handling emergency notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de membresía de grupo aprobada
  Future<void> _handleGroupMembershipApprovedNotificationTap(Map<String, dynamic> data) async {
    try {
      final groupId = data['groupId'] as String?;
      final groupName = data['groupName'] as String? ?? 'Grupo';
      ReleaseLogger.log('Navigating to group chat, groupId=$groupId', tag: 'ParentMainShell');

      if (groupId != null) {
        // Primero cambiar al tab de chats
        setState(() => _selectedIndex = 1);

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatScreenV2(
              groupId: groupId,
              groupName: groupName,
            ),
          ),
        );
      } else {
        // Si no hay groupId, ir al tab de chats
        setState(() => _selectedIndex = 1);
      }
    } catch (e) {
      ReleaseLogger.error('Error handling group membership approved notification tap: $e', tag: 'ParentMainShell');
    }
  }

  /// Manejar tap en notificación de trivia
  Future<void> _handleTriviaNotificationTap(Map<String, dynamic> data) async {
    try {
      final triviaId = data['triviaId'] as String?;
      final type = data['type'] as String?;
      ReleaseLogger.log('Trivia notification tap: type=$type, triviaId=$triviaId', tag: 'ParentMainShell');

      if (triviaId != null) {
        // Determinar si es el creador basado en el tipo de notificación
        // trivia_response, trivia_expiring, trivia_expired → van al creador
        // trivia_winner → va al participante ganador
        final isCreator = type == 'trivia_response' ||
                          type == 'trivia_expiring' ||
                          type == 'trivia_expired';

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => TriviaResultsScreen(
              triviaId: triviaId,
              isCreator: isCreator,
            ),
          ),
        );
      } else {
        // Si no hay triviaId, ir al dashboard donde están las historias
        setState(() => _selectedIndex = 0);
      }
    } catch (e) {
      ReleaseLogger.error('Error handling trivia notification tap: $e', tag: 'ParentMainShell');
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
    // Ya no necesitamos padding extra - selectedFontSize: 0 maneja el centrado

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
        // Eliminar espacio de labels cuando no se muestran
        selectedFontSize: showLabels ? 14 : 0,
        unselectedFontSize: showLabels ? 12 : 0,
        items: [
          BottomNavigationBarItem(
            icon: _buildIconWithBadge(Icons.dashboard_outlined, dashboardBadgeCount),
            activeIcon: _buildIconWithBadge(Icons.dashboard, dashboardBadgeCount),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: _buildIconWithBadge(Icons.chat_bubble_outline, totalUnreadMessages),
            activeIcon: _buildIconWithBadge(Icons.chat_bubble, totalUnreadMessages),
            label: 'Chats',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people_outline),
            activeIcon: Icon(Icons.people),
            label: 'Contactos',
          ),
          BottomNavigationBarItem(
            icon: _buildIconWithBadge(Icons.shield_outlined, whitelistBadgeCount),
            activeIcon: _buildIconWithBadge(Icons.shield, whitelistBadgeCount),
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
