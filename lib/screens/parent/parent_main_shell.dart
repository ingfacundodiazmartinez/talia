import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dashboard/parent_dashboard_screen.dart';
import 'chats/parent_chats_screen.dart';
import 'contacts/parent_contacts_screen.dart';
import 'whitelist/whitelist_screen.dart';
import 'profile/parent_profile_screen.dart';
import 'group_invitations_screen.dart';
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
  int _selectedIndex = 0;
  StreamSubscription? _chatNotificationSubscription;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // GlobalKeys para mantener el estado de navegación de cada tab
  final List<GlobalKey<NavigatorState>> _navigatorKeys = [
    GlobalKey<NavigatorState>(), // Dashboard
    GlobalKey<NavigatorState>(), // Chats
    GlobalKey<NavigatorState>(), // Contactos
    GlobalKey<NavigatorState>(), // Lista Blanca
    GlobalKey<NavigatorState>(), // Perfil
  ];

  @override
  void initState() {
    super.initState();
    _setupNotificationListeners();
  }

  @override
  void dispose() {
    _chatNotificationSubscription?.cancel();
    super.dispose();
  }

  void _setupNotificationListeners() {
    // Escuchar taps en notificaciones de chat
    _chatNotificationSubscription = NotificationService().chatNotificationTapStream.listen((data) {
      print('📲 [ParentMainShell] Chat notification tapped: $data');
      _handleChatNotificationTap(data);
    });
  }

  Future<void> _handleChatNotificationTap(Map<String, dynamic> data) async {
    try {
      final groupId = data['groupId'] as String?;
      final chatId = data['chatId'] as String?;

      // Primero cambiar al tab de chats
      setState(() => _selectedIndex = 1);

      // Determinar si es un chat grupal o 1-on-1
      if (groupId != null) {
        // Notificación de mensaje grupal
        final groupName = data['groupName'] as String? ?? 'Grupo';
        print('✅ [ParentMainShell] Navigating to group chat: $groupName (groupId: $groupId)');

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
          print('⚠️ [ParentMainShell] Missing senderId in notification data');
          return;
        }

        print('📂 [ParentMainShell] Fetching contact info for senderId: $senderId');

        // Obtener información del contacto
        final currentUserId = _auth.currentUser?.uid;
        if (currentUserId == null) {
          print('❌ [ParentMainShell] User not authenticated');
          return;
        }

        // Generar el chatId correcto usando la utilidad
        final correctChatId = ChatUtils.getChatId(currentUserId, senderId);

        // Buscar el contacto en la colección de usuarios
        final contactDoc = await _firestore.collection('users').doc(senderId).get();
        final contactName = contactDoc.data()?['name'] as String? ?? 'Usuario';

        print('✅ [ParentMainShell] Navigating to 1-on-1 chat with $contactName');
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
        print('⚠️ [ParentMainShell] Missing both groupId and chatId in notification data');
      }
    } catch (e) {
      print('❌ [ParentMainShell] Error handling chat notification tap: $e');
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
    final currentUserId = _auth.currentUser?.uid;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildNavigator(0, ParentDashboardScreen()),
          _buildNavigator(1, ParentChatsScreen()),
          _buildNavigator(2, ParentContactsScreen()),
          _buildNavigator(3, WhitelistScreen()),
          _buildNavigator(4, ParentProfileScreen()),
        ],
      ),
      // Ocultar bottom nav bar cuando hay rutas anidadas (ej: chat abierto)
      bottomNavigationBar: _hasNestedRoute ? null : _buildBottomNavigationBar(),
      floatingActionButton: currentUserId != null
          ? StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('groupInvitations')
                  .where('status', isEqualTo: 'pending_approvals')
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();

                // Filtrar invitaciones relevantes para este padre
                final relevantInvitations = snapshot.data!.docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final invitedParentApproval =
                      data['invitedParentApproval'] as Map<String, dynamic>?;
                  final requiredApprovals =
                      data['requiredApprovals'] as Map<String, dynamic>?;

                  // Es invitación para este padre si:
                  // 1. Es padre del invitado
                  if (invitedParentApproval?['parentId'] == currentUserId) {
                    return true;
                  }

                  // 2. Es padre de algún miembro que necesita aprobar
                  if (requiredApprovals != null) {
                    for (final approval in requiredApprovals.values) {
                      if ((approval as Map<String, dynamic>)['parentId'] ==
                          currentUserId) {
                        return true;
                      }
                    }
                  }

                  return false;
                }).toList();

                final count = relevantInvitations.length;

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
    );
  }

  /// Construye el BottomNavigationBar con las 5 secciones principales
  Widget _buildBottomNavigationBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    // Con 5 tabs necesitamos más espacio - aumentar umbral para dispositivos pequeños
    final showLabels = screenWidth >= 430;
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Container(); // Usuario no autenticado
    }

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('notifications')
          .where('userId', isEqualTo: currentUserId)
          .where('read', isEqualTo: false)
          .snapshots(),
      builder: (context, notificationSnapshot) {
        final unreadNotifications = notificationSnapshot.hasData
            ? notificationSnapshot.data!.docs.length
            : 0;

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
                type: BottomNavigationBarType.fixed,
                selectedItemColor: colorScheme.primary,
                unselectedItemColor: colorScheme.onSurfaceVariant,
                showSelectedLabels: showLabels,
                showUnselectedLabels: showLabels,
                items: [
                  BottomNavigationBarItem(
                    icon: _buildIconWithBadge(
                      Icons.dashboard_outlined,
                      unreadNotifications,
                    ),
                    activeIcon: _buildIconWithBadge(
                      Icons.dashboard,
                      unreadNotifications,
                    ),
                    label: 'Dashboard',
                  ),
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
                    icon: Icon(Icons.shield_outlined),
                    activeIcon: Icon(Icons.shield),
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
          },
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
