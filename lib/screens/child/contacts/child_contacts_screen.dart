import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../controllers/child_contacts_controller.dart';
import '../../../models/contact.dart' as contact_model;
import '../../../screens/add_contact_screen.dart';
import '../../../screens/chat_detail_screen.dart';
import '../../../widgets/contacts/contacts_permission_banner.dart';
import '../../../widgets/contacts_sync_consent_dialog.dart';
import '../../../services/friend_service.dart';
import '../../../theme_service.dart';
import '../../../widgets/contacts/friends_explanation_widgets.dart';

/// Pantalla de contactos para niños
///
/// Arquitectura: Screen → Controller → Service → Model
/// El Screen SOLO renderiza UI y delega TODO al Controller
class ChildContactsScreen extends StatefulWidget {
  final String childId;

  const ChildContactsScreen({
    super.key,
    required this.childId,
  });

  @override
  State<ChildContactsScreen> createState() => _ChildContactsScreenState();
}

class _ChildContactsScreenState extends State<ChildContactsScreen>
    with SingleTickerProviderStateMixin {
  late final ChildContactsController _controller;
  late final ScrollController _scrollController;
  late final TabController _tabController;
  bool _isSyncing = false;

  // Tracking de visibilidad para batch update de fotos
  final Set<String> _visibleUserIds = {};
  Timer? _visibilityTimer;

  @override
  void initState() {
    super.initState();
    _controller = ChildContactsController(childId: widget.childId);
    _controller.initialize();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _visibilityTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _tabController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Detectar scroll cerca del final para lazy loading
  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      // Cerca del final, cargar más
      if (_controller.hasMoreContacts && !_controller.isLoadingMore) {
        _loadMoreContacts();
      }
    }

    // Resetear timer de visibilidad en cada scroll
    _resetVisibilityTimer();
  }

  /// Trackear un contacto como visible y resetear timer
  void _trackVisibleContact(String userId) {
    _visibleUserIds.add(userId);
    _resetVisibilityTimer();
  }

  /// Resetear timer - después de 2s sin actividad, batch update
  void _resetVisibilityTimer() {
    _visibilityTimer?.cancel();
    _visibilityTimer = Timer(const Duration(seconds: 2), () {
      if (_visibleUserIds.isNotEmpty && mounted) {
        _controller.batchUpdateVisibleUsers(Set.from(_visibleUserIds));
        _visibleUserIds.clear();
      }
    });
  }

  /// Cargar más contactos con actualización de UI
  Future<void> _loadMoreContacts() async {
    if (!mounted) return;
    setState(() {}); // Mostrar indicador de carga
    await _controller.loadMoreContacts();
    if (mounted) {
      setState(() {}); // Actualizar estado final
    }
  }

  @override
  Widget build(BuildContext context) {
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
              // Header con título (igual que parent)
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
                          'Tus amigos y familiares',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        // Botón de sincronizar contactos
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
                          onPressed: _isSyncing ? null : _handleSync,
                          padding: EdgeInsets.all(8),
                          tooltip: 'Sincronizar contactos',
                        ),
                        // Botón de agregar contacto
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
              ),
              // Contenido con esquinas redondeadas
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                    child: Column(
                      children: [
                        _buildSearchBar(colorScheme),
                        ContactsPermissionBanner(
                          onRequestPermission: _handleSync,
                          onPermissionChanged: _handleSync,
                        ),
                        // TabBar
                        _buildTabBar(colorScheme),
                        // TabBarView con el contenido de cada tab
                        Expanded(
                          child: TabBarView(
                            controller: _tabController,
                            children: [
                              _buildContactsList(colorScheme),
                              _buildFriendsList(colorScheme),
                              _buildFriendRequestsList(colorScheme),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(ColorScheme colorScheme) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.all(16),
      child: TextField(
        onChanged: (value) => _controller.setSearchQuery(value),
        decoration: InputDecoration(
          hintText: 'Buscar contactos...',
          hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
          prefixIcon: Icon(Icons.search, color: colorScheme.primary),
          filled: true,
          fillColor: isDarkMode
              ? colorScheme.surfaceContainerHighest
              : colorScheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        style: TextStyle(color: colorScheme.onSurface),
      ),
    );
  }

  Widget _buildTabBar(ColorScheme colorScheme) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: colorScheme.primary,
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: Colors.white,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        labelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.normal, fontSize: 13),
        dividerColor: Colors.transparent,
        padding: EdgeInsets.all(4),
        tabs: [
          Tab(text: 'Contactos'),
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_stories, size: 14),
                SizedBox(width: 4),
                Text('Historias'),
              ],
            ),
          ),
          _buildFriendRequestsTab(),
        ],
      ),
    );
  }

  Widget _buildFriendRequestsTab() {
    return StreamBuilder<List<contact_model.Contact>>(
      stream: _controller.getFriendRequestsStream(),
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        if (count > 0) {
          return Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Solicitudes'),
                SizedBox(width: 4),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count > 99 ? '99+' : count.toString(),
                    style: TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ],
            ),
          );
        }
        return Tab(text: 'Solicitudes');
      },
    );
  }

  Widget _buildContactsList(ColorScheme colorScheme) {
    return StreamBuilder<List<contact_model.Contact>>(
      stream: _controller.getContactsStream(),
      initialData: _controller.cachedFilteredContacts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildErrorState(colorScheme);
        }

        // Solo mostrar spinner si no hay datos cacheados
        final cached = _controller.cachedFilteredContacts;
        if (!snapshot.hasData && cached.isEmpty) {
          return _buildLoadingState(colorScheme);
        }

        final contacts = snapshot.data ?? cached;
        if (contacts.isEmpty) {
          return _buildEmptyState(colorScheme);
        }

        // +1 para el indicador de loading/fin de lista
        final itemCount = contacts.length + 1;

        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.all(16),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // Último item: indicador de estado
            if (index == contacts.length) {
              return _buildLoadMoreIndicator(colorScheme);
            }
            final contact = contacts[index];
            return _buildContactItem(contact, colorScheme);
          },
        );
      },
    );
  }

  Widget _buildFriendsList(ColorScheme colorScheme) {
    return StreamBuilder<List<contact_model.Contact>>(
      stream: _controller.getFriendsStream(),
      initialData: _controller.cachedFriends,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildErrorState(colorScheme);
        }

        final friends = snapshot.data ?? _controller.cachedFriends;
        if (friends.isEmpty) {
          return FriendsEmptyState();
        }

        return ListView.builder(
          padding: EdgeInsets.all(16),
          itemCount: friends.length + 1, // +1 para header
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: FriendsExplanationHeader(),
              );
            }
            final contact = friends[index - 1];
            return _buildFriendItem(contact, colorScheme);
          },
        );
      },
    );
  }

  Widget _buildFriendRequestsList(ColorScheme colorScheme) {
    return StreamBuilder<List<contact_model.Contact>>(
      stream: _controller.getFriendRequestsStream(),
      initialData: _controller.cachedFriendRequests,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildErrorState(colorScheme);
        }

        final requests = snapshot.data ?? _controller.cachedFriendRequests;
        if (requests.isEmpty) {
          return _buildEmptyRequestsState(colorScheme);
        }

        return ListView.builder(
          padding: EdgeInsets.all(16),
          itemCount: requests.length,
          itemBuilder: (context, index) {
            final contact = requests[index];
            return _buildFriendRequestItem(contact, colorScheme);
          },
        );
      },
    );
  }

  Widget _buildLoadMoreIndicator(ColorScheme colorScheme) {
    if (_controller.isLoadingMore) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
          ),
        ),
      );
    }

    if (!_controller.hasMoreContacts) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'No hay más contactos',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }

    // Si hay más pero no está cargando, mostrar espacio vacío
    return SizedBox(height: 16);
  }

  Widget _buildContactItem(
    contact_model.Contact contact,
    ColorScheme colorScheme, {
    bool isFriendView = false,
    bool isFriendRequest = false,
  }) {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return SizedBox.shrink();

    final otherUserId = contact.getOtherUserId(currentUserId);
    final userData = _controller.getUserData(otherUserId);

    // Trackear este contacto como visible para batch update
    _trackVisibleContact(otherUserId);

    // Obtener teléfono: del perfil o del campo phones del contacto
    final phone = userData?['phone'] as String? ?? contact.phones[otherUserId] ?? '';

    // Obtener nombre denormalizado del contacto como fallback
    final contactName = contact.getOtherUserName(currentUserId);

    // Obtener dbName y alias por separado para mostrar correctamente
    final nameParts = _controller.getNameParts(
      otherUserId,
      phoneHint: phone,
      contactNameHint: contactName,
    );
    final dbName = nameParts.dbName;
    final alias = nameParts.alias;
    // displayName para compatibilidad (usado en diálogos, navegación, etc.)
    final displayName = alias ?? dbName;

    // Foto: primero del contacto (denormalizado), fallback a userData
    final photoURL = contact.getOtherUserPhotoURL(currentUserId) ??
        userData?['photoURL'] as String?;
    final status = contact.getStatusForUser(currentUserId);

    // Calcular edad desde birthDate
    int? age;
    final birthDate = userData?['birthDate'];
    if (birthDate != null) {
      DateTime? birthDateTime;
      if (birthDate is DateTime) {
        birthDateTime = birthDate;
      } else if (birthDate is String) {
        birthDateTime = DateTime.tryParse(birthDate);
      }
      if (birthDateTime != null) {
        final now = DateTime.now();
        age = now.year - birthDateTime.year;
        if (now.month < birthDateTime.month ||
            (now.month == birthDateTime.month && now.day < birthDateTime.day)) {
          age--;
        }
      }
    }

    // Si el nombre es "Usuario", intentar resolver desde la agenda
    if (dbName == 'Usuario' && phone.isNotEmpty) {
      // Intentar resolver de forma asíncrona
      _controller.resolveAndCacheLocalName(otherUserId, phone).then((localName) {
        if (localName != null && mounted) {
          setState(() {}); // Refrescar para mostrar el nuevo nombre
        }
      });
    }

    // Determinar si fue cancelada por el usuario vs rechazada por padre
    final myApproval = contact.getApprovalForChild(currentUserId);
    final isSelfCancelled = status == 'rejected' &&
        myApproval != null &&
        myApproval.rejectedBy == currentUserId;

    return _ContactItemCard(
      contact: contact,
      otherUserId: otherUserId,
      dbName: dbName,
      alias: alias,
      phone: phone,
      age: age,
      photoURL: photoURL,
      status: status,
      isSelfCancelled: isSelfCancelled,
      isFriendView: isFriendView,
      isFriendRequest: isFriendRequest,
      colorScheme: colorScheme,
      onTap: isFriendRequest
          ? null  // No tap action para solicitudes (tienen botones)
          : () => _handleCardTap(contact, status, displayName, isSelfCancelled),
      onCancelTap: status == 'pending' && !isFriendView && !isFriendRequest
          ? () => _handleCancelPending(contact, displayName)
          : null,
      onDeleteTap: status == 'rejected' && !isFriendView && !isFriendRequest
          ? () => _handleDeleteRejected(contact, displayName)
          : null,
      onResendTap: status == 'rejected' && !isFriendView && !isFriendRequest
          ? () => _handleResendRequest(contact, displayName)
          : null,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // ACTIONS
  // ═══════════════════════════════════════════════════════════════

  Future<void> _handleSync() async {
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
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  void _handleCardTap(
    contact_model.Contact contact,
    String status,
    String displayName,
    bool isSelfCancelled,
  ) {
    switch (status) {
      case 'potential':
        _handleRequestApproval(contact, displayName);
        break;
      case 'pending':
        _showPendingInfo(contact, displayName);
        break;
      case 'pending_other':
        _showPendingOtherInfo(contact, displayName);
        break;
      case 'rejected':
        _showRejectedInfo(contact, displayName, isSelfCancelled);
        break;
      case 'approved':
        _navigateToChat(contact, displayName);
        break;
      case 'revoked':
        _showRevokedInfo(displayName);
        break;
    }
  }

  Future<void> _handleRequestApproval(
    contact_model.Contact contact,
    String displayName,
  ) async {
    final confirmed = await _showConfirmDialog(
      'Solicitar contacto',
      '¿Enviar solicitud de contacto a $displayName?',
      confirmText: 'Enviar',
      isDestructive: false,
    );

    if (confirmed != true) return;

    await _controller.requestApproval(contact.id);
  }

  Future<void> _handleCancelPending(
    contact_model.Contact contact,
    String displayName,
  ) async {
    final confirmed = await _showConfirmDialog(
      'Cancelar solicitud',
      '¿Cancelar la solicitud con $displayName?',
    );

    if (confirmed != true) return;

    await _controller.cancelPending(contact.id);
  }

  Future<void> _handleResendRequest(
    contact_model.Contact contact,
    String displayName,
  ) async {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return;

    final confirmed = await _showConfirmDialog(
      'Reenviar solicitud',
      '¿Reenviar solicitud de contacto a $displayName?',
      confirmText: 'Reenviar',
      isDestructive: false,
    );

    if (confirmed != true) return;

    final otherUserId = contact.getOtherUserId(currentUserId);
    await _controller.resendRequest(otherUserId);
  }

  Future<void> _handleDeleteRejected(
    contact_model.Contact contact,
    String displayName,
  ) async {
    final confirmed = await _showConfirmDialog(
      'Eliminar',
      '¿Eliminar la solicitud con $displayName?',
    );

    if (confirmed != true) return;

    await _controller.deleteRejected(contact.id);
  }

  void _showPendingInfo(contact_model.Contact contact, String displayName) {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return;

    final dateText = DateFormat('dd/MM/yyyy HH:mm').format(contact.createdAt);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.schedule, color: Colors.amber.shade600),
            SizedBox(width: 8),
            Expanded(child: Text(displayName, style: TextStyle(fontSize: 18))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Estado: Pendiente de aprobación'),
            SizedBox(height: 8),
            Text('Solicitado: $dateText', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 12),
            Text(
              'Tu padre o madre debe aprobar esta solicitud para que puedan chatear.',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _showPendingOtherInfo(contact_model.Contact contact, String displayName) {
    final dateText = DateFormat('dd/MM/yyyy HH:mm').format(contact.createdAt);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.hourglass_empty, color: Colors.blue.shade600),
            SizedBox(width: 8),
            Expanded(child: Text(displayName, style: TextStyle(fontSize: 18))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Estado: Esperando aprobación'),
            SizedBox(height: 8),
            Text('Solicitado: $dateText', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 12),
            Text(
              'Tu padre ya aprobó esta solicitud, pero el padre de $displayName aún no la ha aprobado.',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
            ),
            SizedBox(height: 8),
            Text(
              'Podrán chatear cuando ambos padres aprueben el contacto.',
              style: TextStyle(fontSize: 14, color: Colors.blue.shade700, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }

  void _showRejectedInfo(
    contact_model.Contact contact,
    String displayName,
    bool isSelfCancelled,
  ) {
    final icon = isSelfCancelled ? Icons.cancel_outlined : Icons.cancel;
    final color = isSelfCancelled ? Colors.orange.shade600 : Colors.red.shade600;
    final message = isSelfCancelled
        ? 'Cancelaste esta solicitud de contacto.'
        : 'Tu padre o madre rechazó esta solicitud de contacto.';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: color),
            SizedBox(width: 8),
            Expanded(child: Text(displayName, style: TextStyle(fontSize: 18))),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _showRevokedInfo(String displayName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.block, color: Colors.grey.shade600),
            SizedBox(width: 8),
            Expanded(child: Text(displayName, style: TextStyle(fontSize: 18))),
          ],
        ),
        content: Text(
          'Este contacto ha sido revocado y no puedes comunicarte con esta persona.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _navigateToChat(contact_model.Contact contact, String displayName) {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return;

    final otherUserId = contact.getOtherUserId(currentUserId);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          contactId: otherUserId,
          contactName: displayName,
          chatId: contact.id, // contactId == chatId (mismo formato)
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // UI HELPERS
  // ═══════════════════════════════════════════════════════════════

  Future<bool?> _showConfirmDialog(
    String title,
    String content, {
    String confirmText = 'Sí',
    bool isDestructive = true,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: isDestructive
                ? TextButton.styleFrom(foregroundColor: Colors.red)
                : null,
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ColorScheme colorScheme) {
    return Center(
      child: Text(
        'Error cargando contactos',
        style: TextStyle(color: colorScheme.error),
      ),
    );
  }

  Widget _buildLoadingState(ColorScheme colorScheme) {
    return Center(
      child: CircularProgressIndicator(color: colorScheme.primary),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 64, color: colorScheme.outlineVariant),
          SizedBox(height: 16),
          Text(
            'No tienes contactos aún',
            style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
          ),
          SizedBox(height: 8),
          Text(
            'Agrega contactos usando el botón +',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildEmptyRequestsState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mail_outline, size: 64, color: colorScheme.outlineVariant),
          SizedBox(height: 16),
          Text(
            'No tienes solicitudes pendientes',
            style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
          ),
          SizedBox(height: 8),
          Text(
            'Aquí aparecerán las solicitudes de amistad',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// Reutiliza _buildContactItem para amigos (status='approved' + isFriend=true)
  Widget _buildFriendItem(contact_model.Contact contact, ColorScheme colorScheme) {
    return _buildContactItem(contact, colorScheme, isFriendView: true);
  }

  /// Widget para solicitudes de amistad con botones de aceptar/rechazar
  Widget _buildFriendRequestItem(contact_model.Contact contact, ColorScheme colorScheme) {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return SizedBox.shrink();

    final otherUserId = contact.getOtherUserId(currentUserId);
    final contactName = contact.getOtherUserName(currentUserId);
    final nameParts = _controller.getNameParts(otherUserId, contactNameHint: contactName);
    final displayName = nameParts.alias ?? nameParts.dbName;

    // Reusar el contactItem base y agregar los botones
    return Column(
      children: [
        _buildContactItem(contact, colorScheme, isFriendRequest: true),
        Padding(
          padding: EdgeInsets.only(left: 16, right: 16, bottom: 10),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _handleRejectFriendRequest(contact, displayName),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(color: Colors.red.withValues(alpha: 0.5)),
                  ),
                  child: Text('Rechazar'),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _handleAcceptFriendRequest(contact, displayName),
                  child: Text('Aceptar'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleAcceptFriendRequest(
    contact_model.Contact contact,
    String displayName,
  ) async {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return;

    try {
      final otherUserId = contact.getOtherUserId(currentUserId);
      await FriendService().acceptFriendRequest(otherUserId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('¡Ahora sos amigo de $displayName!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleRejectFriendRequest(
    contact_model.Contact contact,
    String displayName,
  ) async {
    final confirmed = await _showConfirmDialog(
      'Rechazar solicitud',
      '¿Rechazar la solicitud de amistad de $displayName?',
    );

    if (confirmed != true) return;

    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return;

    try {
      final otherUserId = contact.getOtherUserId(currentUserId);
      await FriendService().rejectFriendRequest(otherUserId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Solicitud rechazada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// CONTACT ITEM CARD
// ═══════════════════════════════════════════════════════════════

class _ContactItemCard extends StatelessWidget {
  final contact_model.Contact contact;
  final String otherUserId;
  /// Nombre de la base de datos (usado para ordenar) - se muestra como título principal
  final String dbName;
  /// Alias personalizado (puede ser null si no hay alias)
  final String? alias;
  final String phone;
  final int? age;
  final String? photoURL;
  final String status;
  final bool isSelfCancelled;
  final bool isFriendView;
  final bool isFriendRequest;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;
  final VoidCallback? onCancelTap;
  final VoidCallback? onDeleteTap;
  final VoidCallback? onResendTap;

  const _ContactItemCard({
    required this.contact,
    required this.otherUserId,
    required this.dbName,
    this.alias,
    required this.phone,
    this.age,
    required this.photoURL,
    required this.status,
    required this.isSelfCancelled,
    this.isFriendView = false,
    this.isFriendRequest = false,
    required this.colorScheme,
    this.onTap,
    this.onCancelTap,
    this.onDeleteTap,
    this.onResendTap,
  });

  /// Nombre para mostrar (alias si existe, sino dbName)
  String get displayName => alias ?? dbName;

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final indicatorColor = _getIndicatorColor();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isDarkMode ? colorScheme.surfaceContainerHighest : colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDarkMode ? 0.2 : 0.06),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Row(
            children: [
              // Indicador lateral de color (solo si tiene estado especial)
              if (indicatorColor != null)
                Container(
                  width: 4,
                  height: 80,
                  color: indicatorColor,
                ),
              // Contenido principal
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      _buildAvatar(),
                      SizedBox(width: 14),
                      Expanded(child: _buildInfo()),
                      _buildTrailing(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color? _getIndicatorColor() {
    // Amigos tienen indicador rosa
    if (isFriendView) return Colors.pink.shade400;
    // Solicitudes de amistad tienen indicador púrpura
    if (isFriendRequest) return Colors.purple.shade400;

    switch (status) {
      case 'pending':
        return Colors.amber.shade600;
      case 'pending_other':
        return Colors.blue.shade400;
      case 'rejected':
        return isSelfCancelled ? Colors.orange.shade400 : Colors.red.shade400;
      case 'potential':
        return Colors.teal.shade400;
      case 'revoked':
        return Colors.grey.shade400;
      default:
        return null;
    }
  }

  Widget _buildAvatar() {
    Color bgColor;
    Color textColor;

    // Vista de amigos: colores rosa
    if (isFriendView) {
      bgColor = Colors.pink.shade50;
      textColor = Colors.pink.shade700;
    }
    // Vista de solicitudes: colores púrpura
    else if (isFriendRequest) {
      bgColor = Colors.purple.shade50;
      textColor = Colors.purple.shade700;
    }
    else {
      switch (status) {
        case 'pending':
          bgColor = Colors.amber.shade100;
          textColor = Colors.amber.shade800;
          break;
        case 'pending_other':
          bgColor = Colors.blue.shade50;
          textColor = Colors.blue.shade700;
          break;
        case 'rejected':
          bgColor = isSelfCancelled ? Colors.orange.shade50 : Colors.red.shade50;
          textColor = isSelfCancelled ? Colors.orange.shade700 : Colors.red.shade700;
          break;
        case 'potential':
          bgColor = Colors.teal.shade50;
          textColor = Colors.teal.shade700;
          break;
        case 'revoked':
          bgColor = Colors.grey.shade200;
          textColor = Colors.grey.shade600;
          break;
        default:
          bgColor = colorScheme.primaryContainer;
          textColor = colorScheme.primary;
      }
    }

    return CircleAvatar(
      radius: 28,
      backgroundColor: bgColor,
      backgroundImage: status == 'approved' && photoURL != null
          ? CachedNetworkImageProvider(photoURL!)
          : null,
      child: (status != 'approved' || photoURL == null)
          ? Text(
              dbName.isNotEmpty ? dbName[0].toUpperCase() : 'U',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            )
          : null,
    );
  }

  Widget _buildInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Nombre principal (de la DB - usado para ordenar)
        Text(
          dbName,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: status == 'revoked'
                ? colorScheme.onSurface.withValues(alpha: 0.6)
                : colorScheme.onSurface,
            decoration: status == 'revoked' ? TextDecoration.lineThrough : null,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SizedBox(height: 2),
        // Subtítulo: Alias + edad
        Row(
          children: [
            if (alias != null) ...[
              Flexible(
                child: Text(
                  alias!,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.primary,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                ' • ',
                style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
              ),
            ],
            if (age != null && age! > 0)
              Text(
                '$age años',
                style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        // Teléfono en línea separada
        if (phone.isNotEmpty) ...[
          SizedBox(height: 2),
          Text(
            phone,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        SizedBox(height: 2),
        _buildStatusText(),
      ],
    );
  }

  Widget _buildStatusText() {
    // Vista de amigos
    if (isFriendView) {
      return Row(
        children: [
          Icon(Icons.favorite, size: 14, color: Colors.pink),
          SizedBox(width: 4),
          Text('Amigo', style: TextStyle(fontSize: 12, color: Colors.pink)),
        ],
      );
    }

    // Vista de solicitudes de amistad
    if (isFriendRequest) {
      return Text(
        'Quiere ser tu amigo',
        style: TextStyle(fontSize: 12, color: Colors.purple.shade600),
      );
    }

    switch (status) {
      case 'pending':
        return Text(
          'Pendiente de aprobación',
          style: TextStyle(fontSize: 12, color: Colors.amber.shade700),
        );
      case 'pending_other':
        return Text(
          'Esperando aprobación del otro padre',
          style: TextStyle(fontSize: 12, color: Colors.blue.shade600),
        );
      case 'rejected':
        return Text(
          isSelfCancelled ? 'Cancelada' : 'Rechazado',
          style: TextStyle(
            fontSize: 12,
            color: isSelfCancelled ? Colors.orange.shade600 : Colors.red.shade600,
          ),
        );
      case 'potential':
        return Text(
          'Toca para solicitar',
          style: TextStyle(fontSize: 12, color: Colors.teal.shade600),
        );
      case 'revoked':
        return Text(
          'Contacto revocado',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        );
      default:
        return SizedBox.shrink(); // No mostrar texto extra para aprobados
    }
  }

  Widget _buildTrailing() {
    // Vista de amigos: mostrar ícono de chat
    if (isFriendView) {
      return Icon(Icons.chat_bubble_outline, color: Colors.pink.shade400);
    }

    // Vista de solicitudes de amistad: no mostrar trailing (botones están abajo)
    if (isFriendRequest) {
      return SizedBox.shrink();
    }

    switch (status) {
      case 'pending':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, color: Colors.amber.shade600, size: 20),
            if (onCancelTap != null)
              IconButton(
                onPressed: onCancelTap,
                icon: Icon(Icons.close, color: colorScheme.error),
                tooltip: 'Cancelar solicitud',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 40, minHeight: 40),
              ),
          ],
        );
      case 'pending_other':
        return Icon(Icons.hourglass_empty, color: Colors.blue.shade500, size: 20);
      case 'rejected':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onResendTap != null)
              IconButton(
                onPressed: onResendTap,
                icon: Icon(Icons.refresh, color: colorScheme.primary),
                tooltip: 'Reenviar solicitud',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 40, minHeight: 40),
              ),
            if (onDeleteTap != null)
              IconButton(
                onPressed: onDeleteTap,
                icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                tooltip: 'Eliminar',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 40, minHeight: 40),
              ),
          ],
        );
      case 'potential':
        return Icon(Icons.person_add_alt_1, color: Colors.teal.shade600);
      case 'revoked':
        return Icon(Icons.block, color: Colors.grey.shade500);
      default:
        return Icon(Icons.chat_bubble_outline, color: colorScheme.primary);
    }
  }
}
