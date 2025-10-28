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
  StreamSubscription? _roleChangeSubscription;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // GlobalKeys para mantener el estado de navegación de cada tab
  final GlobalKey<NavigatorState> _dashboardNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentDashboard');
  final GlobalKey<NavigatorState> _chatsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentChats');
  final GlobalKey<NavigatorState> _contactsNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentContacts');
  final GlobalKey<NavigatorState> _whitelistNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentWhitelist');
  final GlobalKey<NavigatorState> _profileNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ParentProfile');

  @override
  void initState() {
    super.initState();
    _setupNotificationListeners();
    _setupRoleChangeListener();
  }

  @override
  void dispose() {
    _chatNotificationSubscription?.cancel();
    _roleChangeSubscription?.cancel();
    super.dispose();
  }

  void _setupRoleChangeListener() {
    // ⚠️ DESHABILITADO: No cerrar sesión automáticamente por cambios de rol
    // El AuthWrapper en main.dart manejará los cambios de shell si es necesario
    // Los usuarios NUNCA deben ser deslogueados automáticamente
    print('ℹ️ [ParentMainShell] Listener de cambio de rol deshabilitado - no se cerrará sesión automáticamente');
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
    final currentUserId = _auth.currentUser?.uid;

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
      ),
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

    // Obtener IDs de hijos vinculados desde el documento del usuario
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore
          .collection('users')
          .doc(currentUserId)
          .snapshots(),
      builder: (context, userSnapshot) {
        print('🔍 [ParentMainShell] user document snapshot:');
        print('   - hasData: ${userSnapshot.hasData}');
        print('   - hasError: ${userSnapshot.hasError}');
        print('   - connectionState: ${userSnapshot.connectionState}');
        if (userSnapshot.hasError) {
          print('   - error: ${userSnapshot.error}');
        }

        List<String> childrenIds = [];
        if (userSnapshot.hasData && userSnapshot.data != null) {
          final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
          if (userData != null) {
            childrenIds = List<String>.from(userData['linkedChildrenIds'] ?? []);
            print('   - linkedChildrenIds: $childrenIds');
          }
        }

        // Si no hay hijos, contar directamente como 0
        if (childrenIds.isEmpty) {
          // Sin hijos vinculados, ambos contadores son 0
          final dashboardBadgeCount = 0;

          // Contar solicitudes de contacto pendientes (whitelist badge)
          return StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('notifications')
                .where('userId', isEqualTo: currentUserId)
                .where('read', isEqualTo: false)
                .where('type', isEqualTo: 'contact_request')
                .snapshots(),
            builder: (context, contactRequestsSnapshot) {
              final whitelistBadgeCount = contactRequestsSnapshot.data?.docs.length ?? 0;

              // Contar chats no leídos
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

                  return _buildBottomNavBar(
                    colorScheme,
                    showLabels,
                    dashboardBadgeCount,
                    totalUnreadMessages,
                    whitelistBadgeCount,
                  );
                },
              );
            },
          );
        }

        // Contar historias pendientes de los hijos
        print('🔍 [ParentMainShell] Iniciando query de story_approval_requests');
        print('   - parentId: $currentUserId');
        print('   - childrenIds disponibles: $childrenIds');

        return StreamBuilder<QuerySnapshot>(
          stream: _firestore
              .collection('story_approval_requests')
              .where('parentId', isEqualTo: currentUserId)
              .where('status', isEqualTo: 'pending')
              .snapshots(),
          builder: (context, storiesSnapshot) {
            print('🔍 [ParentMainShell] Story snapshot recibido:');
            print('   - hasData: ${storiesSnapshot.hasData}');
            print('   - hasError: ${storiesSnapshot.hasError}');
            print('   - connectionState: ${storiesSnapshot.connectionState}');

            // Log para debug
            if (storiesSnapshot.hasError) {
              print('❌ [ParentMainShell] Error en story query: ${storiesSnapshot.error}');
            } else if (storiesSnapshot.hasData) {
              print('✅ [ParentMainShell] Story requests loaded: ${storiesSnapshot.data!.docs.length}');
              if (storiesSnapshot.data!.docs.isNotEmpty) {
                print('📋 [ParentMainShell] Story requests:');
                for (var doc in storiesSnapshot.data!.docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  print('   - storyId: ${data['storyId']}, childId: ${data['childId']}');
                }
              } else {
                print('⚠️ [ParentMainShell] No hay story requests pendientes');
              }
            } else {
              print('⏳ [ParentMainShell] Story requests loading...');
            }

            final pendingStoriesCount = storiesSnapshot.data?.docs.length ?? 0;

            // Contar emergencias no resueltas de los hijos
            // NOTA: No podemos usar whereIn + whereNotIn juntos, así que filtramos en cliente
            return StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('emergencies')
                  .where('childId', whereIn: childrenIds)
                  .snapshots(),
              builder: (context, emergenciesSnapshot) {
                // Filtrar emergencias no resueltas en el cliente
                int unresolvedEmergenciesCount = 0;
                if (emergenciesSnapshot.hasData) {
                  unresolvedEmergenciesCount = emergenciesSnapshot.data!.docs
                      .where((doc) => (doc.data() as Map<String, dynamic>)['status'] != 'resolved')
                      .length;
                }

                // ✅ DASHBOARD: Historias pendientes + emergencias no resueltas
                final dashboardBadgeCount = pendingStoriesCount + unresolvedEmergenciesCount;

                // Contar solicitudes de contacto pendientes (whitelist badge)
                return StreamBuilder<QuerySnapshot>(
                  stream: _firestore
                      .collection('notifications')
                      .where('userId', isEqualTo: currentUserId)
                      .where('read', isEqualTo: false)
                      .where('type', isEqualTo: 'contact_request')
                      .snapshots(),
                  builder: (context, contactRequestsSnapshot) {
                    final whitelistBadgeCount = contactRequestsSnapshot.data?.docs.length ?? 0;

                    // Contar chats no leídos
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

                        return _buildBottomNavBar(
                          colorScheme,
                          showLabels,
                          dashboardBadgeCount,
                          totalUnreadMessages,
                          whitelistBadgeCount,
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
