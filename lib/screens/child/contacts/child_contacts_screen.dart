import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../controllers/child_contacts_controller.dart';
import '../../../models/contact.dart' as contact_model;
import '../../../screens/add_contact_screen.dart';
import '../../../screens/chat_detail_screen.dart';
import '../../../widgets/contacts/contacts_permission_banner.dart';

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

class _ChildContactsScreenState extends State<ChildContactsScreen> {
  late final ChildContactsController _controller;
  late final ScrollController _scrollController;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _controller = ChildContactsController(childId: widget.childId);
    _controller.initialize();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: _buildAppBar(colorScheme, isDarkMode),
      body: Column(
        children: [
          _buildSearchBar(colorScheme, isDarkMode),
          ContactsPermissionBanner(
            onRequestPermission: _handleSync,
            onPermissionChanged: _handleSync,
          ),
          Expanded(
            child: _buildContactsList(colorScheme),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => AddContactScreen()),
        ),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        child: Icon(Icons.person_add),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ColorScheme colorScheme, bool isDarkMode) {
    return AppBar(
      title: Text('Mis Contactos'),
      backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
      foregroundColor: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      actions: [
        IconButton(
          onPressed: _isSyncing ? null : _handleSync,
          icon: _isSyncing
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
                  ),
                )
              : Icon(Icons.refresh),
          tooltip: 'Sincronizar contactos',
        ),
      ],
    );
  }

  Widget _buildSearchBar(ColorScheme colorScheme, bool isDarkMode) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
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

  Widget _buildContactsList(ColorScheme colorScheme) {
    return StreamBuilder<List<contact_model.Contact>>(
      stream: _controller.getContactsStream(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildErrorState(colorScheme);
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoadingState(colorScheme);
        }

        final contacts = snapshot.data ?? [];
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

  Widget _buildContactItem(contact_model.Contact contact, ColorScheme colorScheme) {
    final currentUserId = _controller.currentUserId;
    if (currentUserId == null) return SizedBox.shrink();

    final otherUserId = contact.getOtherUserId(currentUserId);
    final userData = _controller.getUserData(otherUserId);
    var displayName = _controller.getDisplayName(otherUserId);

    // Obtener teléfono: del perfil o del campo phones del contacto
    final phone = userData?['phone'] as String? ?? contact.phones[otherUserId] ?? '';
    final photoURL = userData?['photoURL'] as String?;
    final status = contact.getStatusForUser(currentUserId);

    // Si el nombre es "Usuario", intentar resolver desde la agenda
    if (displayName == 'Usuario' && phone.isNotEmpty) {
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
      displayName: displayName,
      phone: phone,
      photoURL: photoURL,
      status: status,
      isSelfCancelled: isSelfCancelled,
      colorScheme: colorScheme,
      onTap: () => _handleCardTap(contact, status, displayName, isSelfCancelled),
      onCancelTap: status == 'pending'
          ? () => _handleCancelPending(contact, displayName)
          : null,
      onDeleteTap: status == 'rejected'
          ? () => _handleDeleteRejected(contact, displayName)
          : null,
      onResendTap: status == 'rejected'
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

    await _controller.syncContacts();
    if (mounted) {
      setState(() => _isSyncing = false);
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
}

// ═══════════════════════════════════════════════════════════════
// CONTACT ITEM CARD
// ═══════════════════════════════════════════════════════════════

class _ContactItemCard extends StatelessWidget {
  final contact_model.Contact contact;
  final String otherUserId;
  final String displayName;
  final String phone;
  final String? photoURL;
  final String status;
  final bool isSelfCancelled;
  final ColorScheme colorScheme;
  final VoidCallback onTap;
  final VoidCallback? onCancelTap;
  final VoidCallback? onDeleteTap;
  final VoidCallback? onResendTap;

  const _ContactItemCard({
    required this.contact,
    required this.otherUserId,
    required this.displayName,
    required this.phone,
    required this.photoURL,
    required this.status,
    required this.isSelfCancelled,
    required this.colorScheme,
    required this.onTap,
    this.onCancelTap,
    this.onDeleteTap,
    this.onResendTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: _getBorder(),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            _buildAvatar(),
            SizedBox(width: 16),
            Expanded(child: _buildInfo()),
            _buildTrailing(),
          ],
        ),
      ),
    );
  }

  Border? _getBorder() {
    switch (status) {
      case 'pending':
        return Border.all(color: Colors.amber.shade600, width: 2);
      case 'rejected':
        return Border.all(
          color: isSelfCancelled ? Colors.orange.shade400 : Colors.red.shade300,
          width: 2,
        );
      case 'potential':
        return Border.all(color: Colors.teal.shade400, width: 2);
      case 'revoked':
        return Border.all(color: Colors.grey.shade400, width: 1);
      default:
        return null;
    }
  }

  Widget _buildAvatar() {
    Color bgColor;
    Color textColor;

    switch (status) {
      case 'pending':
        bgColor = Colors.amber.shade100;
        textColor = Colors.amber.shade800;
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

    return CircleAvatar(
      radius: 28,
      backgroundColor: bgColor,
      backgroundImage: status == 'approved' && photoURL != null
          ? NetworkImage(photoURL!)
          : null,
      child: (status != 'approved' || photoURL == null)
          ? Text(
              displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
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
        Text(
          displayName,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: status == 'revoked'
                ? colorScheme.onSurface.withValues(alpha: 0.6)
                : colorScheme.onSurface,
            decoration: status == 'revoked' ? TextDecoration.lineThrough : null,
          ),
        ),
        if (phone.isNotEmpty) ...[
          SizedBox(height: 2),
          Text(
            phone,
            style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
          ),
        ],
        SizedBox(height: 2),
        _buildStatusText(),
      ],
    );
  }

  Widget _buildStatusText() {
    switch (status) {
      case 'pending':
        return Text(
          'Pendiente de aprobación',
          style: TextStyle(fontSize: 12, color: Colors.amber.shade700),
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
