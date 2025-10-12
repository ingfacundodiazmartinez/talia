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

    final screens = [
      ChildChatsScreen(childId: currentUserId, controller: _controller),
      ChildContactsScreen(childId: currentUserId, controller: _controller),
      ChildProfileScreen(),
    ];

    return Scaffold(
      body: screens[_selectedIndex],
      bottomNavigationBar: Container(
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
          items: [
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
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Perfil',
            ),
          ],
        ),
      ),
    );
  }
}
