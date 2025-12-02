import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../../controllers/child_main_shell_controller.dart';
import '../../notification_service.dart';
import '../../utils/release_logger.dart';
import '../../groups/groups.dart'; // Groups V2
import 'chats/child_chats_screen.dart';
import 'contacts/child_contacts_screen.dart';
import 'profile/child_profile_screen.dart';
import '../chat_detail_screen.dart';

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

/// Shell principal para la navegación de niños
///
/// Responsabilidades:
/// - Manejar la navegación entre tabs (Chats, Contactos, Perfil)
/// - Inicializar el controller compartido
/// - Mostrar BottomNavigationBar
class ChildMainShell extends StatefulWidget {
  const ChildMainShell({super.key});

  @override
  State<ChildMainShell> createState() => _ChildMainShellState();
}

class _ChildMainShellState extends State<ChildMainShell> {
  int _selectedIndex = 0;
  late final ChildMainShellController _mainController;

  // GlobalKeys para mantener el estado de navegación de cada tab
  final GlobalKey<NavigatorState> _chatsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ChildChats');
  final GlobalKey<NavigatorState> _contactsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ChildContacts');
  final GlobalKey<NavigatorState> _profileNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ChildProfile');

  @override
  void initState() {
    super.initState();
    final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId != null) {
      _mainController = ChildMainShellController(
        childId: currentUserId,
        context: context,
      );

      // Configurar callback para navegación desde notificaciones
      _mainController.onChatNotificationTap = _handleChatNotificationTap;

      _mainController.initialize();
    }
  }

  @override
  void dispose() {
    _mainController.dispose();
    super.dispose();
  }



  Future<void> _handleChatNotificationTap(Map<String, dynamic> data) async {
    // Delegar toda la lógica al controller
    await _mainController.handleChatNotificationTap(data);

    // ✅ FIX: Verificar si el chat ya está abierto para evitar navegación duplicada
    final currentOpenChatId = NotificationService().currentChatId;

    // Primero cambiar al tab de chats
    setState(() => _selectedIndex = 0);

    // El controller maneja toda la lógica de navegación
    final groupId = data['groupId'] as String?;
    final chatId = data['chatId'] as String?;
    final isGroup = data['isGroup'] == true || data['isGroup'] == 'true';

    if (groupId != null || (isGroup && chatId != null)) {
      // Notificación de mensaje grupal
      final effectiveGroupId = groupId ?? chatId!;
      final groupName = data['groupName'] as String? ?? 'Grupo';

      // ✅ FIX: Si el grupo ya está abierto, no navegar de nuevo
      if (currentOpenChatId == effectiveGroupId) {
        ReleaseLogger.log('⚠️ [ChildMainShell] Grupo $effectiveGroupId ya está abierto - SALTANDO navegación duplicada', tag: 'ChildMainShell');
        return;
      }

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatScreenV2(
              groupId: effectiveGroupId,
              groupName: groupName,
            ),
          ),
        );
      }
    } else if (chatId != null) {
      // Notificación de mensaje 1-on-1
      final senderId = data['senderId'] as String?;
      if (senderId != null) {
        // ✅ FIX: Si el chat ya está abierto, no navegar de nuevo
        if (currentOpenChatId == chatId) {
          ReleaseLogger.log('⚠️ [ChildMainShell] Chat $chatId ya está abierto - SALTANDO navegación duplicada', tag: 'ChildMainShell');
          return;
        }

        if (mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ChatDetailScreen(
                contactId: senderId,
                contactName: 'Usuario', // El controller tiene la lógica de obtener el nombre
                chatId: chatId,
              ),
            ),
          );
        }
      }
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
        currentKey = _chatsNavigatorKey;
        break;
      case 1:
        currentKey = _contactsNavigatorKey;
        break;
      case 2:
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
    final colorScheme = Theme.of(context).colorScheme;
    final currentUserId = _mainController.currentUserId;

    if (currentUserId == null) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    // Con 3 tabs necesitamos menos espacio que con 5, pero aún aumentamos el umbral
    final showLabels = screenWidth >= 380;

    return PopScope(
      canPop: false,
      onPopInvoked: (bool didPop) async {
        if (didPop) return;

        // Si hay navegación anidada, hacer pop en el navegador del tab actual
        if (_hasNestedRoute) {
          GlobalKey<NavigatorState> currentKey;
          switch (_selectedIndex) {
            case 0:
              currentKey = _chatsNavigatorKey;
              break;
            case 1:
              currentKey = _contactsNavigatorKey;
              break;
            case 2:
              currentKey = _profileNavigatorKey;
              break;
            default:
              currentKey = _chatsNavigatorKey;
          }

          if (currentKey.currentState?.canPop() ?? false) {
            currentKey.currentState!.pop();
            return;
          }
        }

        // Si estamos en otro tab que no sea Chats (0), volver al tab de Chats
        if (_selectedIndex != 0) {
          setState(() => _selectedIndex = 0);
          return;
        }

        // Si estamos en el tab de Chats y no hay navegación anidada, salir de la app
        // (El sistema Android manejará la salida)
      },
      child: Scaffold(
      body: Stack(
        children: [
          Offstage(
            offstage: _selectedIndex != 0,
            child: _mainController.childController != null
                ? _buildNavigator(_chatsNavigatorKey, ChildChatsScreen(childId: currentUserId, controller: _mainController.childController!))
                : Center(child: CircularProgressIndicator()),
          ),
          Offstage(
            offstage: _selectedIndex != 1,
            child: _mainController.childController != null
                ? _buildNavigator(_contactsNavigatorKey, ChildContactsScreen(childId: currentUserId, controller: _mainController.childController!))
                : Center(child: CircularProgressIndicator()),
          ),
          Offstage(
            offstage: _selectedIndex != 2,
            child: _buildNavigator(_profileNavigatorKey, ChildProfileScreen()),
          ),
        ],
      ),
      // Ocultar bottom nav bar cuando hay rutas anidadas (ej: chat abierto)
      bottomNavigationBar: _hasNestedRoute ? null : _buildBottomNavigationBar(colorScheme, showLabels),
      ),
    );
  }

  /// Construye el BottomNavigationBar con badges
  Widget _buildBottomNavigationBar(ColorScheme colorScheme, bool showLabels) {
    final currentUserId = _mainController.currentUserId;

    if (currentUserId == null) {
      return Container(); // Usuario no autenticado
    }

    return StreamBuilder<int>(
      stream: _mainController.getUnreadMessagesStream(),
      builder: (context, snapshot) {
        final totalUnreadMessages = snapshot.data ?? 0;

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
            selectedItemColor: colorScheme.primary,
            unselectedItemColor: colorScheme.onSurfaceVariant,
            showSelectedLabels: showLabels,
            showUnselectedLabels: showLabels,
            items: [
              BottomNavigationBarItem(
                icon: _buildIconWithBadge(
                  Icons.chat_bubble_outline,
                  totalUnreadMessages,
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
                icon: Icon(Icons.person_outline),
                activeIcon: Icon(Icons.person),
                label: 'Perfil',
              ),
            ],
          ),
        );
      },
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
