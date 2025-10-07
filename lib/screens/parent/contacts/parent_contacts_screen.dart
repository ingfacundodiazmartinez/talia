import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/parent.dart';
import '../../../models/child.dart';
import '../../../models/user.dart';
import '../../../services/user_role_service.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/auto_approval_service.dart';
import '../../../services/video_call_service.dart';
import '../../../notification_service.dart';
import '../../../theme_service.dart';
import '../../../link_parent_child.dart';
import '../../add_contact_screen.dart';
import '../../../controllers/parent_dashboard_controller.dart';
import 'widgets/contact_card_widget.dart';
import 'widgets/filterable_contact_item.dart';

/// Pantalla de gestión de contactos del padre
///
/// Muestra:
/// - Lista de hijos vinculados
/// - Lista de otros contactos
/// - Buscador de contactos
/// - Botón para agregar contactos
/// - Botón para vincular hijos
class ParentContactsScreen extends StatefulWidget {
  const ParentContactsScreen({super.key});

  @override
  State<ParentContactsScreen> createState() => _ParentContactsScreenState();
}

class _ParentContactsScreenState extends State<ParentContactsScreen> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  late ParentDashboardController _controller;
  final ContactAliasService _aliasService = ContactAliasService();
  final ValueNotifier<String> _contactsSearchQuery = ValueNotifier('');
  final TextEditingController _contactsSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = ParentDashboardController(
      parentId: _auth.currentUser!.uid,
      context: context,
      notificationService: NotificationService(),
      videoCallService: VideoCallService(),
      autoApprovalService: AutoApprovalService(),
    );
  }

  @override
  void dispose() {
    _contactsSearchController.dispose();
    _contactsSearchQuery.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userRoleService = UserRoleService();
    final currentUserId = _auth.currentUser?.uid;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              context.customColors.gradientStart,
              context.customColors.gradientEnd,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header con título
              Padding(
                padding: EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mis Contactos',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Gestiona tus contactos',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: Icon(Icons.person_add, color: Colors.white, size: 26),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => AddContactScreen()),
                        );
                      },
                      padding: EdgeInsets.all(8),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              // Contenido
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Buscador (estático, no se rebuildea)
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: TextField(
                          key: ValueKey('contacts_search_field'),
                          controller: _contactsSearchController,
                          onChanged: (value) {
                            _contactsSearchQuery.value = value.toLowerCase();
                          },
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Buscar contactos...',
                            hintStyle: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            suffixIcon: _contactsSearchController.text.isNotEmpty
                                ? IconButton(
                                    icon: Icon(Icons.clear, color: Colors.grey),
                                    onPressed: () {
                                      _contactsSearchController.clear();
                                      _contactsSearchQuery.value = '';
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: context.customColors.searchBarBackground,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),
                      // Lista de contactos (filtrable)
                      Expanded(
                        child: FutureBuilder<List<String>>(
                          future: userRoleService.getLinkedChildren(currentUserId!),
                          builder: (context, childrenSnapshot) {
                            if (childrenSnapshot.connectionState == ConnectionState.waiting) {
                              return Center(
                                child: CircularProgressIndicator(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              );
                            }

                            final linkedChildren = childrenSnapshot.data ?? [];

                            // Load contacts with users array format
                            return FutureBuilder<List<DocumentSnapshot>>(
                              future: Parent(id: currentUserId, name: '').loadAllContacts(),
                              builder: (context, contactsSnapshot) {
                              if (contactsSnapshot.hasError) {
                                return Center(
                                  child: Text('Error: ${contactsSnapshot.error}'),
                                );
                              }

                              if (contactsSnapshot.connectionState == ConnectionState.waiting) {
                                return Center(
                                  child: CircularProgressIndicator(
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                );
                              }

                              final allContactDocs = contactsSnapshot.data ?? [];

                              // Separar hijos y otros contactos
                              final childrenContacts = <Widget>[];
                              final otherContacts = <Widget>[];
                              final processedUserIds = <String>{};

                              for (var doc in allContactDocs) {
                                final data = doc.data() as Map<String, dynamic>;

                                // Extraer el otro usuario del array users
                                final users = List<String>.from(data['users'] ?? []);
                                final otherUserId = users.firstWhere(
                                  (id) => id != currentUserId,
                                  orElse: () => '',
                                );

                                if (otherUserId.isEmpty || processedUserIds.contains(otherUserId)) {
                                  continue;
                                }

                                processedUserIds.add(otherUserId);
                                final isChild = linkedChildren.contains(otherUserId);

                                final widget = FutureBuilder<DocumentSnapshot?>(
                                  future: User.getByIdSnapshot(otherUserId),
                                  builder: (context, userSnapshot) {
                                    if (!userSnapshot.hasData) return SizedBox();

                                    final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                                    final realName = userData?['name'] ?? 'Usuario';

                                    return FutureBuilder<String>(
                                      future: _aliasService.getDisplayName(otherUserId, realName),
                                      builder: (context, aliasSnapshot) {
                                        final displayName = aliasSnapshot.data ?? realName;
                                        final child = userData != null ? Child.fromMap(otherUserId, userData) : null;

                                        return FilterableContactItem(
                                          searchQuery: _contactsSearchQuery,
                                          realName: realName,
                                          displayName: displayName,
                                          child: ContactCardWidget(
                                            currentUserId: currentUserId,
                                            contactId: otherUserId,
                                            displayName: displayName,
                                            realName: realName,
                                            age: child?.age ?? 0,
                                            status: child?.isOnline == true ? 'En línea' : 'Desconectado',
                                            statusColor: child?.isOnline == true ? Colors.green : Colors.grey,
                                            isChild: isChild,
                                            photoURL: child?.photoURL,
                                            onUnlink: isChild ? () => _showUnlinkChildDialog(otherUserId, displayName) : null,
                                          ),
                                        );
                                      },
                                    );
                                  },
                                );

                                if (isChild) {
                                  childrenContacts.add(widget);
                                } else {
                                  otherContacts.add(widget);
                                }
                              }

                              // Also add any linked children that don't have contact documents yet
                              for (var childId in linkedChildren) {
                                if (!processedUserIds.contains(childId)) {
                                  processedUserIds.add(childId);

                                  final widget = FutureBuilder<DocumentSnapshot?>(
                                    future: User.getByIdSnapshot(childId),
                                    builder: (context, userSnapshot) {
                                      if (!userSnapshot.hasData) return SizedBox();

                                      final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                                      final realName = userData?['name'] ?? 'Usuario';

                                      return FutureBuilder<String>(
                                        future: _aliasService.getDisplayName(childId, realName),
                                        builder: (context, aliasSnapshot) {
                                          final displayName = aliasSnapshot.data ?? realName;
                                          final child = userData != null ? Child.fromMap(childId, userData) : null;

                                          return FilterableContactItem(
                                            searchQuery: _contactsSearchQuery,
                                            realName: realName,
                                            displayName: displayName,
                                            child: ContactCardWidget(
                                              currentUserId: currentUserId,
                                              contactId: childId,
                                              displayName: displayName,
                                              realName: realName,
                                              age: child?.age ?? 0,
                                              status: child?.isOnline == true ? 'En línea' : 'Desconectado',
                                              statusColor: child?.isOnline == true ? Colors.green : Colors.grey,
                                              isChild: true,
                                              photoURL: child?.photoURL,
                                              onUnlink: () => _showUnlinkChildDialog(childId, displayName),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );

                                  childrenContacts.add(widget);
                                }
                              }

                              if (childrenContacts.isEmpty && otherContacts.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.people_outline,
                                        size: 64,
                                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                      ),
                                      SizedBox(height: 16),
                                      Text(
                                        'No tienes contactos aún',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        'Agrega contactos o vincula un hijo',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              return ListView(
                                padding: EdgeInsets.all(16),
                                children: [
                                  if (childrenContacts.isNotEmpty) ...[
                                    Padding(
                                      padding: EdgeInsets.only(bottom: 12, left: 4),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: Colors.green.withValues(alpha: 0.1),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Icon(Icons.family_restroom, size: 16, color: Colors.green),
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Hijos',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(context).colorScheme.onSurface,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    ...childrenContacts,
                                    if (otherContacts.isNotEmpty) SizedBox(height: 24),
                                  ],
                                  if (otherContacts.isNotEmpty) ...[
                                    Padding(
                                      padding: EdgeInsets.only(bottom: 12, left: 4),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: Colors.blue.withValues(alpha: 0.1),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Icon(Icons.people, size: 16, color: Colors.blue),
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Otros Contactos',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(context).colorScheme.onSurface,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    ...otherContacts,
                                  ],
                                ],
                              );
                            },
                          );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => GenerateLinkCodeScreen()),
          );
        },
        icon: Icon(Icons.link),
        label: Text('Vincular Hijo'),
      ),
    );
  }

  void _showUnlinkChildDialog(String childId, String childName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Desvincular Hijo'),
          ],
        ),
        content: Text(
          '¿Estás seguro de que deseas desvincular a $childName? Esta acción no se puede deshacer.',
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);

              try {
                // Desvincular usando el controller
                final success = await _controller.unlinkChild(childId);

                if (success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('$childName ha sido desvinculado'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error al desvincular: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text('Desvincular', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
