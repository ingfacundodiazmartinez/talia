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

  // Las 5 secciones principales de la app de padres
  static final List<Widget> _screens = [
    ParentDashboardScreen(),    // Tab 0: Dashboard
    ParentChatsScreen(),         // Tab 1: Chats
    ParentContactsScreen(),      // Tab 2: Contactos
    WhitelistScreen(),           // Tab 3: Lista Blanca (Control Parental)
    ParentProfileScreen(),       // Tab 4: Perfil
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

  @override
  Widget build(BuildContext context) {
    final currentUserId = _auth.currentUser?.uid;

    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: _buildBottomNavigationBar(),
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
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            activeIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
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
  }
}
