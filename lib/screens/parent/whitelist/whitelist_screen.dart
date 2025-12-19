import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/whitelist_controller.dart';
import '../../../models/grouped_contact.dart';
import '../../../utils/release_logger.dart';
import '../../../theme_service.dart';
import 'widgets/grouped_contact_card.dart';
import 'widgets/contact_detail_sheet.dart';
import '../../../services/unread_messages_service.dart';

/// Screen principal de Control Parental (Lista Blanca)
///
/// Arquitectura CODING_RULES:
/// - UI solo renderiza y maneja interacciones
/// - Delega toda la lógica al WhitelistController
/// - Usa cache del controller para búsqueda sin recrear streams
class WhitelistScreen extends StatefulWidget {
  /// Filtro inicial por hijo (opcional)
  final String? initialChildFilter;

  /// Filtro pendiente para aplicar (usado cuando se navega desde el dashboard)
  static String? pendingChildFilter;

  /// Establecer filtro pendiente para cuando se navegue al tab de whitelist
  static void setChildFilter(String childId) {
    pendingChildFilter = childId;
  }

  const WhitelistScreen({
    super.key,
    this.initialChildFilter,
  });

  @override
  State<WhitelistScreen> createState() => _WhitelistScreenState();
}

class _WhitelistScreenState extends State<WhitelistScreen>
    with AutomaticKeepAliveClientMixin {
  late WhitelistController _controller;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Filtros
  String _statusFilter = 'all'; // all, pending, approved, rejected, revoked
  late String _childFilter;

  // Estado
  List<GroupedContact> _groupedContacts = [];
  List<Map<String, String>> _linkedChildren = [];
  bool _isLoading = true;

  // Contadores para badges
  int _pendingCount = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _childFilter = widget.initialChildFilter ?? 'all';

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      _controller = WhitelistController(parentId: currentUser.uid);
      _initializeController();
    }
  }

  Future<void> _initializeController() async {
    if (!mounted) return;

    try {
      // Configurar callback para actualizar UI cuando cambian los datos
      _controller.onDataChanged = _onControllerDataChanged;

      // Inicializar controller (carga hijos y arranca streams)
      await _controller.initialize();

      // Marcar notificaciones de whitelist como leídas al entrar
      _controller.markNotificationsAsRead();

      // Cargar hijos vinculados para filtro
      final children = await _controller.getLinkedChildrenWithNames();
      if (!mounted) return;
      setState(() => _linkedChildren = children);

      // Procesar datos iniciales del cache
      await _processDataFromCache();
    } catch (e) {
      ReleaseLogger.error('Error inicializando controller: $e', tag: 'WhitelistScreen');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Callback del controller cuando cambian los datos en cache
  void _onControllerDataChanged() {
    if (!mounted) return;
    _processDataFromCache();
  }

  /// Procesar datos desde el cache del controller
  Future<void> _processDataFromCache() async {
    if (!mounted) return;

    try {
      final contacts = _controller.contactsCache;
      final pendingGroups = _controller.groupRequestsCache;
      final approvedGroups = _controller.groupMembershipsCache
          .map((m) => m.toMap())
          .toList();

      final grouped = await _controller.groupContactsByPerson(
        contacts,
        pendingGroups,
        approvedGroups,
      );

      if (!mounted) return;
      setState(() {
        _groupedContacts = grouped;
        _pendingCount = grouped.fold(0, (total, c) => total + c.pendingCount);
        _isLoading = false;
      });
    } catch (e) {
      ReleaseLogger.error('Error procesando datos: $e', tag: 'WhitelistScreen');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Compatibilidad: método legacy para refresh
  Future<void> _loadData() async {
    await _processDataFromCache();
  }

  Future<void> _refresh() async {
    await _loadData();
  }

  @override
  void dispose() {
    _controller.onDataChanged = null; // Limpiar callback
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // Aplicar filtro pendiente si existe (navegación desde dashboard)
    if (WhitelistScreen.pendingChildFilter != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && WhitelistScreen.pendingChildFilter != null) {
          setState(() {
            _childFilter = WhitelistScreen.pendingChildFilter!;
            WhitelistScreen.pendingChildFilter = null;
          });
        }
      });
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.customColors.gradientStart,
              context.customColors.gradientEnd,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(context),
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
                      _buildSearchAndFilters(context),
                      Expanded(child: _buildBody(context)),
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

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Control Parental',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Gestiona los contactos de tus hijos',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          // Botón de ayuda sobre Moderación IA
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
              onPressed: () => _showAIModerationHelp(context),
              icon: Icon(Icons.psychology, color: Colors.white, size: 26),
              tooltip: 'Sobre Moderación con IA',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          // Barra de búsqueda
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            style: TextStyle(color: colorScheme.onSurface),
            decoration: InputDecoration(
              hintText: 'Buscar contacto o hijo...',
              hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
              prefixIcon: Icon(Icons.search, color: colorScheme.primary),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: context.customColors.searchBarBackground,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          SizedBox(height: 12),
          // Filtros
          Row(
            children: [
              // Filtro por estado
              Expanded(
                child: _buildFilterDropdown(
                  value: _statusFilter,
                  items: [
                    DropdownMenuItem(value: 'all', child: Text('Todos')),
                    DropdownMenuItem(
                      value: 'pending',
                      child: Row(
                        children: [
                          Text('Pendientes'),
                          if (_pendingCount > 0) ...[
                            SizedBox(width: 6),
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '$_pendingCount',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    DropdownMenuItem(value: 'approved', child: Text('Aprobados')),
                    DropdownMenuItem(value: 'rejected', child: Text('Rechazados')),
                    DropdownMenuItem(value: 'revoked', child: Text('Revocados')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _statusFilter = value);
                  },
                  icon: Icons.filter_list,
                ),
              ),
              SizedBox(width: 12),
              // Filtro por hijo
              Expanded(
                child: _buildFilterDropdown(
                  value: _childFilter,
                  items: [
                    DropdownMenuItem(value: 'all', child: Text('Todos los hijos')),
                    ..._linkedChildren.map((child) => DropdownMenuItem(
                          value: child['id'],
                          child: Text(child['name'] ?? 'Hijo'),
                        )),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _childFilter = value);
                  },
                  icon: Icons.child_care,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterDropdown({
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    required IconData icon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.customColors.searchBarBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          items: items,
          onChanged: onChanged,
          isExpanded: true,
          icon: Icon(Icons.expand_more, color: colorScheme.onSurfaceVariant),
          style: TextStyle(
            fontSize: 14,
            color: colorScheme.onSurface,
          ),
          dropdownColor: colorScheme.surface,
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }

    if (_linkedChildren.isEmpty) {
      return _buildNoChildren(context);
    }

    // Aplicar filtros
    final filteredContacts = _controller.filterGroupedContacts(
      _groupedContacts,
      statusFilter: _statusFilter,
      childIdFilter: _childFilter,
    );

    if (filteredContacts.isEmpty) {
      return _buildEmptyState(context);
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: filteredContacts.length,
        itemBuilder: (context, index) {
          final contact = filteredContacts[index];
          return GroupedContactCard(
            contact: contact,
            controller: _controller,
            searchQuery: _searchQuery,
            onTap: () => _showContactDetail(contact),
            onApprove: _handleApprove,
            onReject: _handleReject,
          );
        },
      ),
    );
  }

  Widget _buildNoChildren(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.family_restroom,
            size: 80,
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.5),
          ),
          SizedBox(height: 16),
          Text(
            'No tienes hijos vinculados',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Vincula a tu hijo para gestionar sus contactos',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    String title;
    String subtitle;
    IconData icon;

    switch (_statusFilter) {
      case 'pending':
        icon = Icons.check_circle_outline;
        title = '¡Todo al día!';
        subtitle = 'No hay solicitudes pendientes';
        break;
      case 'approved':
        icon = Icons.shield_outlined;
        title = 'Sin contactos aprobados';
        subtitle = 'Los contactos aprobados aparecerán aquí';
        break;
      case 'rejected':
        icon = Icons.block_outlined;
        title = 'Sin solicitudes rechazadas';
        subtitle = 'Las solicitudes rechazadas aparecerán aquí';
        break;
      case 'revoked':
        icon = Icons.remove_circle_outline;
        title = 'Sin contactos revocados';
        subtitle = 'Los contactos revocados aparecerán aquí';
        break;
      default:
        icon = Icons.people_outline;
        title = 'Sin contactos';
        subtitle = 'Los contactos de tus hijos aparecerán aquí';
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 80,
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.5),
          ),
          SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENT HANDLERS - Usan nuevos métodos del controller
  // ═══════════════════════════════════════════════════════════════

  Future<void> _handleApprove(ChildRelation relation) async {
    ReleaseLogger.log('🔄 [HandleApprove] Iniciando - type: ${relation.type}, contactDocId: ${relation.contactDocId}, childId: ${relation.childId}', tag: 'WhitelistScreen');

    // Feedback visual inmediato
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text('Aprobando...'),
            ],
          ),
          duration: Duration(seconds: 1),
          backgroundColor: Colors.blue,
        ),
      );
    }

    Map<String, dynamic> result;

    if (relation.type == 'group_v2') {
      ReleaseLogger.log('📤 [HandleApprove] Llamando approveGroupV2Request', tag: 'WhitelistScreen');
      result = await _controller.approveGroupV2Request(
        requestId: relation.contactDocId,
        groupId: relation.data['groupId'] ?? '',
        childId: relation.childId,
      );
    } else {
      // Contacto - usar escritura directa a Firestore
      ReleaseLogger.log('📤 [HandleApprove] Llamando approveContact', tag: 'WhitelistScreen');
      result = await _controller.approveContact(
        contactDocId: relation.contactDocId,
        childId: relation.childId,
      );
    }

    ReleaseLogger.log('📥 [HandleApprove] Resultado: $result', tag: 'WhitelistScreen');

    await UnreadMessagesService().updateBadgeCount();

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (!result['success']) {
        ReleaseLogger.error('❌ [HandleApprove] Error: ${result['error']}', tag: 'WhitelistScreen');
        _showErrorSnackBar(result['error']);
      } else {
        ReleaseLogger.log('✅ [HandleApprove] Aprobación exitosa', tag: 'WhitelistScreen');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contacto aprobado'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        // Forzar recarga de datos para actualizar UI
        await _loadData();
      }
    }
  }

  Future<void> _handleReject(ChildRelation relation) async {
    // Feedback visual inmediato
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text('Rechazando...'),
            ],
          ),
          duration: Duration(seconds: 1),
          backgroundColor: Colors.orange,
        ),
      );
    }

    Map<String, dynamic> result;

    if (relation.type == 'group_v2') {
      result = await _controller.rejectGroupV2Request(
        requestId: relation.contactDocId,
      );
    } else {
      // Contacto - usar escritura directa a Firestore
      result = await _controller.rejectContact(
        contactDocId: relation.contactDocId,
        childId: relation.childId,
      );
    }

    await UnreadMessagesService().updateBadgeCount();

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (!result['success']) {
        _showErrorSnackBar(result['error']);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contacto rechazado'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        // Forzar recarga de datos para actualizar UI
        await _loadData();
      }
    }
  }

  Future<void> _handleRevoke(ChildRelation relation) async {
    ReleaseLogger.log('🔄 [WhitelistScreen] _handleRevoke llamado: type=${relation.type}, contactDocId=${relation.contactDocId}', tag: 'WhitelistScreen');

    // Si es un grupo aprobado, sacar al hijo del grupo
    if (relation.type == 'group_v2' && relation.status == 'approved') {
      await _handleRevokeGroupMembership(relation);
      return;
    }

    List<String>? groupsToRemove;

    // Verificar grupos compartidos (solo para contactos individuales)
    final contactId = relation.data['contactId'] as String?;
    if (contactId != null) {
      try {
        final sharedGroups = await _controller.getSharedGroups(
          childId: relation.childId,
          contactId: contactId,
        );

        if (sharedGroups.isNotEmpty) {
          final shouldRemove = await _showSharedGroupsDialog(
            childName: relation.childName,
            sharedGroups: sharedGroups,
          );

          if (shouldRemove == null) {
            ReleaseLogger.log('⏹️ [WhitelistScreen] Usuario canceló diálogo de grupos', tag: 'WhitelistScreen');
            return; // Canceló
          }

          if (shouldRemove) {
            groupsToRemove =
                sharedGroups.map((g) => g['id'] as String).toList();
          }
        }
      } catch (e) {
        ReleaseLogger.error('Error verificando grupos: $e',
            tag: 'WhitelistScreen');
      }
    }

    // Feedback visual inmediato
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text('Revocando contacto...'),
            ],
          ),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.orange,
        ),
      );
    }

    ReleaseLogger.log('📤 [WhitelistScreen] Llamando revokeContact...', tag: 'WhitelistScreen');
    final result = await _controller.revokeContact(
      contactDocId: relation.contactDocId,
      childId: relation.childId,
      groupsToRemove: groupsToRemove,
    );
    ReleaseLogger.log('📥 [WhitelistScreen] revokeContact resultado: $result', tag: 'WhitelistScreen');

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contacto revocado exitosamente'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        // Forzar recarga de datos para actualizar UI
        await _loadData();
      } else {
        _showErrorSnackBar(result['error']);
      }
    }
  }

  /// Manejar revocación de membresía de grupo (sacar hijo del grupo)
  Future<void> _handleRevokeGroupMembership(ChildRelation relation) async {
    final groupId = relation.data['groupId'] as String?;
    final groupName = relation.data['groupName'] as String? ?? 'el grupo';

    if (groupId == null) {
      ReleaseLogger.error('❌ [RevokeGroup] groupId no encontrado', tag: 'WhitelistScreen');
      return;
    }

    // Mostrar diálogo de confirmación
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.group_remove,
          size: 48,
          color: Colors.orange,
        ),
        title: Text('Sacar del grupo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '¿Estás seguro de que quieres sacar a ${relation.childName} del grupo "$groupName"?',
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12),
            Text(
              'Ya no podrá ver los mensajes ni participar en el grupo.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: Text('Sacar del grupo'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Feedback visual inmediato
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text('Sacando del grupo...'),
            ],
          ),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.orange,
        ),
      );
    }

    ReleaseLogger.log('📤 [RevokeGroup] Llamando revokeGroupMembership: groupId=$groupId, childId=${relation.childId}', tag: 'WhitelistScreen');
    final result = await _controller.revokeGroupMembership(
      groupId: groupId,
      childId: relation.childId,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${relation.childName} fue removido del grupo'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        // Forzar recarga de datos para actualizar UI
        await _loadData();
      } else {
        _showErrorSnackBar(result['error'] ?? 'Error al sacar del grupo');
      }
    }
  }

  Future<void> _handleReApprove(ChildRelation relation) async {
    // Feedback visual inmediato
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text('Habilitando contacto...'),
            ],
          ),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.blue,
        ),
      );
    }

    final result = await _controller.reApproveContact(
      contactDocId: relation.contactDocId,
      childId: relation.childId,
    );

    await UnreadMessagesService().updateBadgeCount();

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contacto habilitado exitosamente'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        await _loadData();
      } else {
        _showErrorSnackBar(result['error']);
      }
    }
  }

  /// Abrir bottom sheet con detalle del contacto y moderación
  void _showContactDetail(GroupedContact contact) {
    ContactDetailSheet.show(
      context: context,
      contact: contact,
      controller: _controller,
      onApprove: (relation) async {
        await _handleApprove(relation);
      },
      onReject: (relation) async {
        await _handleReject(relation);
      },
      onRevoke: (relation) async {
        await _handleRevoke(relation);
      },
      onReApprove: (relation) async {
        await _handleReApprove(relation);
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // DIALOGS
  // ═══════════════════════════════════════════════════════════════

  Future<bool?> _showSharedGroupsDialog({
    required String childName,
    required List<Map<String, dynamic>> sharedGroups,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon:
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
        title: Text(
          'Grupos Compartidos',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$childName comparte ${sharedGroups.length} ${sharedGroups.length == 1 ? 'grupo' : 'grupos'} con este contacto:',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 12),
              ...sharedGroups.map((group) => Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.group, size: 16, color: colorScheme.primary),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${group['name']}',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  )),
              SizedBox(height: 12),
              Text(
                '¿Deseas sacar a $childName de estos grupos también?',
                style:
                    TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Mantener en grupos'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Sacar de grupos'),
          ),
        ],
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  /// Mostrar diálogo de ayuda sobre Moderación con IA
  void _showAIModerationHelp(BuildContext context) {
    const aiColor = Color(0xFF5C6BC0);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.psychology, color: aiColor, size: 48),
        title: Text('Moderación con IA'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '¿Qué es?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 4),
              Text(
                'La IA analiza los mensajes que recibe tu hijo y te alerta si detecta contenido potencialmente peligroso o inapropiado.',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 16),
              Text(
                '¿Cómo activarla?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 4),
              Text(
                'Toca sobre un contacto aprobado y selecciona el nivel de moderación deseado en la sección "Mod. IA".',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 16),
              Text(
                'Niveles disponibles:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 8),
              _buildHelpLevelItem('Alto', 'Detecta grooming, acoso, contenido sexual y violento', Colors.red),
              _buildHelpLevelItem('Medio', 'Detecta contenido inapropiado y lenguaje ofensivo', Colors.orange),
              _buildHelpLevelItem('Bajo', 'Solo detecta contenido explícitamente peligroso', Colors.blue),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber, color: Colors.amber[700], size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'La IA puede cometer errores. Úsala como herramienta de apoyo, no como reemplazo de la supervisión parental.',
                        style: TextStyle(fontSize: 13, color: Colors.amber[900]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpLevelItem(String level, String description, Color color) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 55,
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              level,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              description,
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
