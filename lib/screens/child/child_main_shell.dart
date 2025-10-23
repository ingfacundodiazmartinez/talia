import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../controllers/child_home_controller.dart';
import 'chats/child_chats_screen.dart';
import 'contacts/child_contacts_screen.dart';
import 'profile/child_profile_screen.dart';
import '../../notification_service.dart';
import '../../utils/chat_utils.dart';
import '../chat_detail_screen.dart';
import '../group_chat_screen.dart';

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
  late ChildHomeController _controller;
  StreamSubscription? _chatNotificationSubscription;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // GlobalKeys para mantener el estado de navegación de cada tab
  final List<GlobalKey<NavigatorState>> _navigatorKeys = [
    GlobalKey<NavigatorState>(), // Chats
    GlobalKey<NavigatorState>(), // Contactos
    GlobalKey<NavigatorState>(), // Perfil
  ];

  @override
  void initState() {
    super.initState();
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId != null) {
      _controller = ChildHomeController(
        childId: currentUserId,
        context: context,
      );
      _controller.initialize();
    }
    _setupNotificationListeners();
  }

  @override
  void dispose() {
    _controller.dispose();
    _chatNotificationSubscription?.cancel();
    super.dispose();
  }

  void _setupNotificationListeners() {
    // Escuchar taps en notificaciones de chat
    _chatNotificationSubscription = NotificationService().chatNotificationTapStream.listen((data) {
      print('📲 [ChildMainShell] Chat notification tapped: $data');
      _handleChatNotificationTap(data);
    });
  }

  Future<void> _handleChatNotificationTap(Map<String, dynamic> data) async {
    try {
      final groupId = data['groupId'] as String?;
      final chatId = data['chatId'] as String?;

      // Primero cambiar al tab de chats
      setState(() => _selectedIndex = 0);

      // Determinar si es un chat grupal o 1-on-1
      if (groupId != null) {
        // Notificación de mensaje grupal
        final groupName = data['groupName'] as String? ?? 'Grupo';
        print('✅ [ChildMainShell] Navigating to group chat: $groupName (groupId: $groupId)');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatScreen(
              groupId: groupId,
              groupName: groupName,
            ),
          ),
        );
      } else if (chatId != null) {
        // Notificación de mensaje 1-on-1
        final senderId = data['senderId'] as String?;

        if (senderId == null) {
          print('⚠️ [ChildMainShell] Missing senderId in notification data');
          return;
        }

        print('📂 [ChildMainShell] Fetching contact info for senderId: $senderId');

        // Obtener información del contacto
        final currentUserId = _auth.currentUser?.uid;
        if (currentUserId == null) {
          print('❌ [ChildMainShell] User not authenticated');
          return;
        }

        // Generar el chatId correcto usando la utilidad
        final correctChatId = ChatUtils.getChatId(currentUserId, senderId);

        // Buscar el contacto en la colección de usuarios
        final contactDoc = await _firestore.collection('users').doc(senderId).get();
        final contactName = contactDoc.data()?['name'] as String? ?? 'Usuario';

        print('✅ [ChildMainShell] Navigating to 1-on-1 chat with $contactName');
        print('   Notification chatId: $chatId');
        print('   Correct chatId: $correctChatId');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              contactId: senderId,
              contactName: contactName,
              chatId: correctChatId,
            ),
          ),
        );
      } else {
        print('⚠️ [ChildMainShell] Missing both groupId and chatId in notification data');
      }
    } catch (e) {
      print('❌ [ChildMainShell] Error handling chat notification tap: $e');
    }
  }

  /// Construye un Navigator para cada tab, permitiendo mantener
  /// el estado de navegación independiente en cada uno
  Widget _buildNavigator(int index, Widget child) {
    return Navigator(
      key: _navigatorKeys[index],
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
    setState(() {
      // Rebuild para actualizar visibilidad del bottom nav bar
    });
  }

  /// Verifica si el tab actual tiene rutas push (para ocultar bottom nav bar)
  bool get _hasNestedRoute {
    final navigator = _navigatorKeys[_selectedIndex].currentState;
    if (navigator == null) return false;
    // Si el navigator puede hacer pop, significa que hay rutas anidadas
    return navigator.canPop();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Scaffold(
        body: Center(
          child: Text('Error: Usuario no autenticado'),
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    // Con 3 tabs necesitamos menos espacio que con 5, pero aún aumentamos el umbral
    final showLabels = screenWidth >= 380;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildNavigator(0, ChildChatsScreen(childId: currentUserId, controller: _controller)),
          _buildNavigator(1, ChildContactsScreen(childId: currentUserId, controller: _controller)),
          _buildNavigator(2, ChildProfileScreen()),
        ],
      ),
      // Ocultar bottom nav bar cuando hay rutas anidadas (ej: chat abierto)
      bottomNavigationBar: _hasNestedRoute ? null : _buildBottomNavigationBar(colorScheme, showLabels),
    );
  }

  /// Construye el BottomNavigationBar con badges
  Widget _buildBottomNavigationBar(ColorScheme colorScheme, bool showLabels) {
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Container(); // Usuario no autenticado
    }

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('chats')
          .where('participants', arrayContains: currentUserId)
          .snapshots(),
      builder: (context, chatSnapshot) {
        int totalUnreadMessages = 0;

        if (chatSnapshot.hasData) {
          for (var doc in chatSnapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>?;
            if (data != null) {
              final unreadCount = data['unreadCount_$currentUserId'] as int? ?? 0;
              totalUnreadMessages += unreadCount;
            }
          }
        }

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
