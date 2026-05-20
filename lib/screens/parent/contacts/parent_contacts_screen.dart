import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../../../models/contact.dart';
import '../../../widgets/contacts/contacts_permission_banner.dart';
import '../../../widgets/contacts_sync_consent_dialog.dart';
import '../../../theme_service.dart';
import '../../../link_parent_child.dart';
import '../../add_contact_screen.dart';
import '../../../controllers/parent_contacts_controller.dart';
import 'widgets/contact_card_widget.dart';
import 'widgets/approval_requests_badge.dart';
import 'widgets/friend_request_card_widget.dart';
import '../../../widgets/contacts/friends_explanation_widgets.dart';

/// Pantalla de gestión de contactos del padre
///
/// Muestra:
/// - Lista de hijos vinculados (ordenados alfabéticamente)
/// - Lista de otros contactos (ordenados alfabéticamente)
/// - Buscador de contactos
/// - Botón para agregar contactos
/// - Botón para vincular hijos
class ParentContactsScreen extends StatefulWidget {
  const ParentContactsScreen({super.key});

  @override
  State<ParentContactsScreen> createState() => _ParentContactsScreenState();
}

class _ParentContactsScreenState extends State<ParentContactsScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  late ParentContactsController _controller;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Tab controller para Contactos/Solicitudes
  late TabController _tabController;

  // Estado de sincronización
  bool _isSyncing = false;

  // Contador de solicitudes pendientes
  int _pendingRequestsCount = 0;
  StreamSubscription? _pendingRequestsSubscription;

  // Tracking de visibilidad para batch update
  final Set<String> _visibleUserIds = {};
  Timer? _visibilityTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId != null) {
      _controller = ParentContactsController(parentId: currentUserId);
      _controller.initialize();
      _startPendingRequestsStream();
    }
    _scrollController.addListener(_onScroll);
  }

  void _startPendingRequestsStream() {
    _pendingRequestsSubscription?.cancel();
    _pendingRequestsSubscription = _controller.pendingFriendRequestsStream.listen(
      (requests) {
        if (mounted) {
          setState(() {
            _pendingRequestsCount = requests.length;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _visibilityTimer?.cancel();
    _pendingRequestsSubscription?.cancel();
    _tabController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    _resetVisibilityTimer();
  }

  /// Trackear un contacto como visible
  void _trackVisibleContact(String userId) {
    _visibleUserIds.add(userId);
    _resetVisibilityTimer();
  }

  /// Resetear timer - después de 1s sin actividad, batch update
  void _resetVisibilityTimer() {
    _visibilityTimer?.cancel();
    _visibilityTimer = Timer(const Duration(seconds: 1), () {
      if (_visibleUserIds.isNotEmpty && mounted) {
        _controller.batchUpdateVisibleUsers(Set.from(_visibleUserIds));
        _visibleUserIds.clear();
      }
    });
  }

  Future<void> _syncContacts() async {
    if (_isSyncing) return;

    setState(() => _isSyncing = true);

    try {
      // Verificar si el usuario ha dado consentimiento para sincronizar contactos
      final hasConsent = await _controller.hasConsent();

      if (!hasConsent) {
        // Mostrar diálogo de consentimiento
        if (!mounted) return;
        final consentGranted = await ContactsSyncConsentDialog.show(context);

        if (!mounted) return;

        if (!consentGranted) {
          // Usuario rechazó el consentimiento
          setState(() => _isSyncing = false);
          return;
        }

        // Guardar consentimiento y sincronizar
        await _controller.setConsent(true);
        await _controller.syncContacts(skipConsentCheck: true);
      } else {
        // Ya tiene consentimiento, sincronizar normalmente
        await _controller.syncContacts();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sincronizando contactos'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentUserId = _auth.currentUser?.uid;
    final colorScheme = Theme.of(context).colorScheme;

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
              // Header
              _buildHeader(currentUserId),
              SizedBox(height: 16),
              // Contenido
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Tabs: Contactos | Solicitudes
                      _buildTabs(colorScheme),
                      // Content based on selected tab
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // Tab 1: Contactos
                            Column(
                              children: [
                                _buildSearchBar(colorScheme),
                                ContactsPermissionBanner(
                                  onRequestPermission: _syncContacts,
                                  onPermissionChanged: _syncContacts,
                                ),
                                Expanded(
                                  child: _buildContactsList(colorScheme, currentUserId),
                                ),
                              ],
                            ),
                            // Tab 2: Amigos
                            _buildFriendsList(colorScheme, currentUserId),
                            // Tab 3: Solicitudes de amistad
                            _buildFriendRequestsList(colorScheme, currentUserId),
                          ],
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
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => GenerateLinkCodeScreen()),
          );
        },
        icon: Icon(Icons.link),
        label: Text('Vincular Hijo'),
      ),
    );
  }

  Widget _buildHeader(String? currentUserId) {
    return Padding(
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
          Row(
            children: [
              ApprovalRequestsBadge(
                parentId: currentUserId ?? '',
                iconColor: Colors.white,
                iconSize: 26,
              ),
              IconButton(
                icon: Icon(Icons.person_add, color: Colors.white, size: 26),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => AddContactScreen()),
                  );
                },
                padding: EdgeInsets.all(8),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: context.customColors.searchBarBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: TabBar(
          controller: _tabController,
          indicator: BoxDecoration(
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(10),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: EdgeInsets.all(4),
          labelColor: Colors.white,
          unselectedLabelColor: colorScheme.onSurfaceVariant,
          labelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
          dividerColor: Colors.transparent,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people, size: 16),
                  SizedBox(width: 4),
                  Text('Contactos'),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_stories, size: 16),
                  SizedBox(width: 4),
                  Text('Historias'),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_add, size: 16),
                  SizedBox(width: 4),
                  Text('Solicitudes'),
                  if (_pendingRequestsCount > 0) ...[
                    SizedBox(width: 4),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _pendingRequestsCount > 99 ? '99+' : '$_pendingRequestsCount',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.all(16),
      child: TextField(
        controller: _searchController,
        onChanged: (value) {
          _controller.setSearchQuery(value);
        },
        style: TextStyle(color: colorScheme.onSurface),
        decoration: InputDecoration(
          hintText: 'Buscar contactos...',
          hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
          prefixIcon: Icon(Icons.search, color: colorScheme.primary),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: Colors.grey),
                  onPressed: () {
                    _searchController.clear();
                    _controller.setSearchQuery('');
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
    );
  }

  Widget _buildContactsList(ColorScheme colorScheme, String? currentUserId) {
    if (currentUserId == null) {
      return Center(child: Text('Usuario no autenticado'));
    }

    return StreamBuilder<({List<ProcessedContact> children, List<ProcessedContact> others})>(
      stream: _controller.separatedContactsStream,
      initialData: _controller.cachedSeparatedContacts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final cached = _controller.cachedSeparatedContacts;
        // Solo mostrar spinner si no hay datos cacheados
        if (!snapshot.hasData && cached.children.isEmpty && cached.others.isEmpty) {
          return Center(
            child: CircularProgressIndicator(color: colorScheme.primary),
          );
        }

        final children = snapshot.data?.children ?? cached.children;
        final others = snapshot.data?.others ?? cached.others;

        if (children.isEmpty && others.isEmpty) {
          return _buildEmptyState(colorScheme);
        }

        return ListView(
          controller: _scrollController,
          padding: EdgeInsets.all(16),
          children: [
            if (children.isNotEmpty) ...[
              _buildSectionHeader(
                'Hijos',
                Icons.family_restroom,
                Colors.green,
                colorScheme,
              ),
              ...children.map((c) => _buildContactCard(c, currentUserId, colorScheme)),
              if (others.isNotEmpty) SizedBox(height: 24),
            ],
            if (others.isNotEmpty) ...[
              _buildSectionHeader(
                'Otros Contactos',
                Icons.people,
                Colors.blue,
                colorScheme,
              ),
              ...others.map((c) => _buildContactCard(c, currentUserId, colorScheme)),
            ],
          ],
        );
      },
    );
  }

  Widget _buildSectionHeader(
    String title,
    IconData icon,
    Color color,
    ColorScheme colorScheme,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactCard(
    ProcessedContact contact,
    String currentUserId,
    ColorScheme colorScheme,
  ) {
    // Trackear como visible para batch update
    _trackVisibleContact(contact.oderId);

    return ContactCardWidget(
      key: ValueKey('contact_${contact.oderId}'),
      currentUserId: currentUserId,
      contactId: contact.oderId,
      dbName: contact.dbName,
      alias: contact.alias,
      age: contact.age ?? 0,
      phone: contact.phone,
      status: contact.isOnline ? 'En línea' : 'Desconectado',
      statusColor: contact.isOnline ? Colors.green : Colors.grey,
      isChild: contact.isChild,
      isFriend: contact.isFriend,
      photoURL: contact.photoURL,
      onUnlink: contact.isChild
          ? () => _showUnlinkChildDialog(contact.oderId, contact.dbName)
          : null,
    );
  }

  Widget _buildFriendsList(ColorScheme colorScheme, String? currentUserId) {
    if (currentUserId == null) {
      return Center(child: Text('Usuario no autenticado'));
    }

    return StreamBuilder<List<ProcessedContact>>(
      stream: _controller.friendsStream,
      initialData: _controller.cachedFriends,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        // Solo mostrar spinner si no hay datos cacheados
        if (!snapshot.hasData && _controller.cachedFriends.isEmpty) {
          return Center(
            child: CircularProgressIndicator(color: colorScheme.primary),
          );
        }

        final friends = snapshot.data ?? _controller.cachedFriends;

        if (friends.isEmpty) {
          return FriendsEmptyState();
        }

        return ListView.builder(
          padding: EdgeInsets.all(16),
          itemCount: friends.length + 1, // +1 para el header
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: FriendsExplanationHeader(),
              );
            }
            return _buildContactCard(friends[index - 1], currentUserId, colorScheme);
          },
        );
      },
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          SizedBox(height: 16),
          Text(
            'No tienes contactos aún',
            style: TextStyle(
              fontSize: 16,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Agrega contactos o vincula un hijo',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);

              try {
                await _controller.unlinkChild(childId);
              } catch (e) {
                if (mounted) {
                  scaffoldMessenger.showSnackBar(
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

  Widget _buildFriendRequestsList(ColorScheme colorScheme, String? currentUserId) {
    if (currentUserId == null) {
      return Center(child: Text('Usuario no autenticado'));
    }

    return StreamBuilder<List<Contact>>(
      stream: _controller.pendingFriendRequestsStream,
      initialData: _controller.cachedPendingRequests,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        // Solo mostrar spinner si no hay datos cacheados
        if (!snapshot.hasData && _controller.cachedPendingRequests.isEmpty) {
          return Center(
            child: CircularProgressIndicator(color: colorScheme.primary),
          );
        }

        final requests = snapshot.data ?? _controller.cachedPendingRequests;

        if (requests.isEmpty) {
          return _buildEmptyFriendRequestsState(colorScheme);
        }

        return ListView.builder(
          padding: EdgeInsets.all(16),
          itemCount: requests.length,
          itemBuilder: (context, index) {
            final contact = requests[index];
            return FriendRequestCardWidget(
              key: ValueKey('friend_request_${contact.id}'),
              contact: contact,
              currentUserId: currentUserId,
              onAccept: () => _handleAcceptFriendRequest(contact),
              onReject: () => _handleRejectFriendRequest(contact),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyFriendRequestsState(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.person_add_disabled,
                size: 48,
                color: colorScheme.primary,
              ),
            ),
            SizedBox(height: 24),
            Text(
              'Sin solicitudes pendientes',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Cuando alguien quiera ver tus historias,\nsu solicitud aparecerá aquí',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAcceptFriendRequest(Contact contact) async {
    try {
      final otherUserId = contact.getOtherUserId(_auth.currentUser?.uid ?? '');
      await _controller.acceptFriendRequest(otherUserId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ahora son amigos'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al aceptar: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleRejectFriendRequest(Contact contact) async {
    try {
      final otherUserId = contact.getOtherUserId(_auth.currentUser?.uid ?? '');
      await _controller.rejectFriendRequest(otherUserId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solicitud rechazada'),
            backgroundColor: Colors.grey,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al rechazar: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }
}
