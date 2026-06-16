import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:shared_preferences/shared_preferences.dart';
import '../../controllers/child_main_shell_controller.dart';
import '../../notification_service.dart';
import '../../utils/release_logger.dart';
import '../../groups/groups.dart'; // Groups V2
import 'chats/child_chats_screen.dart';
import 'contacts/child_contacts_screen.dart';
import 'profile/child_profile_screen.dart';
import '../chat_detail_screen.dart';
import '../trivia/trivia_results_screen.dart';
import '../contact_profile_screen.dart';
import '../../services/bottom_nav_visibility.dart';

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

  /// GlobalKey para preservar estado cuando el tema cambia
  // ignore: library_private_types_in_public_api
  static final GlobalKey<_ChildMainShellState> shellKey =
      GlobalKey<_ChildMainShellState>(debugLabel: 'ChildMainShell');

  @override
  State<ChildMainShell> createState() => _ChildMainShellState();
}

class _ChildMainShellState extends State<ChildMainShell> {
  int _selectedIndex = 0;
  late final ChildMainShellController _mainController;

  // GlobalKeys para mantener el estado de navegación de cada tab
  final GlobalKey<NavigatorState> _chatsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ChildChats');
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
      _mainController.onTriviaNotificationTap = _handleTriviaNotificationTap;
      _mainController.onFomoNotificationTap = _handleFomoNotificationTap;
      _mainController.onFriendRequestNotificationTap = _handleFriendRequestNotificationTap;

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

    // ✅ FIX: Verificar chat abierto en memoria Y SharedPreferences
    // El memory check puede fallar si la app fue reiniciada/terminada
    String? currentOpenChatId = NotificationService().currentChatId;

    // Si memoria está vacía, verificar SharedPreferences (para cuando app fue terminada)
    if (currentOpenChatId == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        currentOpenChatId = prefs.getString('current_chat_id');
        ReleaseLogger.log(
          '📱 [ChildMainShell] currentChatId desde SharedPreferences: $currentOpenChatId',
          tag: 'ChildMainShell',
        );
      } catch (e) {
        ReleaseLogger.error('Error leyendo current_chat_id: $e', tag: 'ChildMainShell');
      }
    }

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
        // ✅ FIX: Pop hasta la raíz antes de navegar para evitar duplicados
        // Esto maneja el caso de app reiniciada donde currentOpenChatId es null
        // pero hay un chat en el stack de navegación
        Navigator.of(context).popUntil((route) => route.isFirst);

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
          // ✅ FIX: Pop hasta la raíz antes de navegar para evitar duplicados
          Navigator.of(context).popUntil((route) => route.isFirst);

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

  /// Manejar tap en notificación de trivia
  Future<void> _handleTriviaNotificationTap(Map<String, dynamic> data) async {
    try {
      final triviaId = data['triviaId'] as String?;
      final type = data['type'] as String?;
      ReleaseLogger.log('Trivia notification tap: type=$type, triviaId=$triviaId', tag: 'ChildMainShell');

      if (triviaId != null && mounted) {
        // Determinar si es el creador basado en el tipo de notificación
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
      }
    } catch (e) {
      ReleaseLogger.error('Error handling trivia notification tap: $e', tag: 'ChildMainShell');
    }
  }

  /// Manejar tap en notificación FOMO (navegar al perfil del contacto)
  Future<void> _handleFomoNotificationTap(Map<String, dynamic> data) async {
    try {
      final storyOwnerId = data['storyOwnerId'] as String?;
      final storyOwnerName = (data['storyOwnerName'] ?? data['senderName'] ?? 'Usuario') as String;

      ReleaseLogger.log(
        'FOMO notification tap: storyOwnerId=$storyOwnerId, name=$storyOwnerName',
        tag: 'ChildMainShell',
      );

      if (storyOwnerId != null && mounted) {
        final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
        if (currentUserId == null) return;

        // Generar chatId (mismo formato que en otros lugares)
        final chatId = [currentUserId, storyOwnerId]..sort();
        final chatIdStr = chatId.join('_');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ContactProfileScreen(
              contactId: storyOwnerId,
              contactName: storyOwnerName,
              chatId: chatIdStr,
            ),
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error handling FOMO notification tap: $e', tag: 'ChildMainShell');
    }
  }

  /// Manejar tap en notificación de solicitud de amistad (navegar al perfil del contacto)
  Future<void> _handleFriendRequestNotificationTap(Map<String, dynamic> data) async {
    try {
      final senderId = data['senderId'] as String?;
      final senderName = (data['senderName'] ?? 'Usuario') as String;

      ReleaseLogger.log(
        'Friend request notification tap: senderId=$senderId, name=$senderName',
        tag: 'ChildMainShell',
      );

      if (senderId != null && mounted) {
        final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
        if (currentUserId == null) return;

        // Generar chatId (mismo formato que en otros lugares)
        final chatId = [currentUserId, senderId]..sort();
        final chatIdStr = chatId.join('_');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ContactProfileScreen(
              contactId: senderId,
              contactName: senderName,
              chatId: chatIdStr,
            ),
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error handling friend request notification tap: $e', tag: 'ChildMainShell');
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
        currentKey = _profileNavigatorKey;
        break;
      default:
        return false;
    }
    final navigator = currentKey.currentState;
    if (navigator == null) return false;
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
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;

        // Si hay navegación anidada, hacer pop en el navegador del tab actual
        if (_hasNestedRoute) {
          GlobalKey<NavigatorState> currentKey;
          switch (_selectedIndex) {
            case 0:
              currentKey = _chatsNavigatorKey;
              break;
            case 1:
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
            child: _buildNavigator(_profileNavigatorKey, ChildProfileScreen()),
          ),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<int>(
        valueListenable: BottomNavVisibility.instance.fullScreenCount,
        builder: (context, fullScreenCount, _) {
          // Mostrar FAB sólo en tab Chats y cuando no hay full-screen activo
          if (_selectedIndex != 0 || fullScreenCount > 0 || _hasNestedRoute) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton(
            heroTag: 'child_new_chat_fab',
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            tooltip: 'Nuevo chat',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChildContactsScreen(childId: currentUserId),
                ),
              );
            },
            child: const Icon(Icons.edit),
          );
        },
      ),
      // Bottom nav siempre visible salvo cuando hay una pantalla full-screen
      // registrada (chat detail, llamadas, story viewer, AR camera, media viewer).
      bottomNavigationBar: ValueListenableBuilder<int>(
        valueListenable: BottomNavVisibility.instance.fullScreenCount,
        builder: (context, fullScreenCount, _) {
          if (fullScreenCount > 0) return const SizedBox.shrink();
          return _buildBottomNavigationBar(colorScheme, showLabels);
        },
      ),
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
            // Eliminar espacio de labels cuando no se muestran
            selectedFontSize: showLabels ? 14 : 0,
            unselectedFontSize: showLabels ? 12 : 0,
            items: [
              BottomNavigationBarItem(
                icon: _buildIconWithBadge(Icons.chat_bubble_outline, totalUnreadMessages),
                activeIcon: _buildIconWithBadge(Icons.chat_bubble, totalUnreadMessages),
                label: 'Chats',
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
