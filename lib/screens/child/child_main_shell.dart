import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../controllers/child_home_controller.dart';
import 'chats/child_chats_screen.dart';
import 'contacts/child_contacts_screen.dart';
import 'profile/child_profile_screen.dart';

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
  final FirebaseAuth _auth = FirebaseAuth.instance;

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
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
