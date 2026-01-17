import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../../../widgets/contacts/contacts_permission_banner.dart';
import '../../../theme_service.dart';
import '../../../link_parent_child.dart';
import '../../add_contact_screen.dart';
import '../../../controllers/parent_contacts_controller.dart';
import 'widgets/contact_card_widget.dart';
import 'widgets/approval_requests_badge.dart';

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
    with AutomaticKeepAliveClientMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  late ParentContactsController _controller;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Estado de sincronización
  bool _isSyncing = false;

  // Tracking de visibilidad para batch update
  final Set<String> _visibleUserIds = {};
  Timer? _visibilityTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId != null) {
      _controller = ParentContactsController(parentId: currentUserId);
      _controller.initialize();
    }
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _visibilityTimer?.cancel();
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
      await _controller.syncContacts();
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
              IconButton(
                icon: _isSyncing
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(Icons.sync, color: Colors.white, size: 26),
                onPressed: _isSyncing ? null : _syncContacts,
                padding: EdgeInsets.all(8),
                tooltip: 'Sincronizar contactos',
              ),
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
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return Center(
            child: CircularProgressIndicator(color: colorScheme.primary),
          );
        }

        final children = snapshot.data?.children ?? [];
        final others = snapshot.data?.others ?? [];

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
      photoURL: contact.photoURL,
      onUnlink: contact.isChild
          ? () => _showUnlinkChildDialog(contact.oderId, contact.dbName)
          : null,
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
}
