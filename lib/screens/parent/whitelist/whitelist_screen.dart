import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../controllers/whitelist_controller.dart';
import '../../../models/contact_request.dart';
import '../../../models/permission_request.dart';
import '../../../theme_service.dart';
import 'widgets/pending_request_card.dart';
import 'widgets/approved_request_card.dart';
import 'widgets/rejected_request_card.dart';

/// Screen principal de Control Parental (Lista Blanca)
///
/// Responsabilidades (SOLO UI):
/// - Mostrar tabs de solicitudes (Pendientes/Aprobadas/Rechazadas)
/// - Delegar lógica de negocio al WhitelistController
/// - Renderizar widgets extraídos
class WhitelistScreen extends StatefulWidget {
  const WhitelistScreen({super.key});

  @override
  State<WhitelistScreen> createState() => _WhitelistScreenState();
}

class _WhitelistScreenState extends State<WhitelistScreen>
    with SingleTickerProviderStateMixin {
  late WhitelistController _controller;
  late TabController _tabController;

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');

  List<Map<String, dynamic>> _currentPendingRequests = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    // Inicializar controller
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      _controller = WhitelistController(parentId: currentUser.uid);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _searchQuery.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Control Parental 🛡️',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Gestiona las solicitudes de tus hijos',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_controller.selectedRequests.isNotEmpty)
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${_controller.selectedRequests.length} seleccionada(s)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: 16),
                    // OPCIÓN C: Card Completa con Diseño Híbrido
                    _buildModerationCard(context),
                  ],
                ),
              ),
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
                      _buildTabBar(),
                      Expanded(child: _buildBody()),
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

  Widget _buildTabBar() {
    return Material(
      color: Colors.transparent,
      child: TabBar(
        controller: _tabController,
        labelColor: Theme.of(context).colorScheme.primary,
        unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
        indicatorColor: Theme.of(context).colorScheme.primary,
        tabs: [
          Tab(text: 'Pendientes'),
          Tab(text: 'Aprobadas'),
          Tab(text: 'Rechazadas'),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return StreamBuilder<List<String>>(
      stream: _controller.getLinkedChildrenIdsStream(),
      builder: (context, childrenSnapshot) {
        if (childrenSnapshot.hasError) {
          return Center(child: Text('Error: ${childrenSnapshot.error}'));
        }

        if (childrenSnapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        }

        if (!childrenSnapshot.hasData || childrenSnapshot.data!.isEmpty) {
          return _buildNoChildren();
        }

        final childrenIds = childrenSnapshot.data!;

        return Column(
          children: [
            _buildSearchBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildPendingTab(childrenIds),
                  _buildApprovedTab(),
                  _buildRejectedTab(childrenIds),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNoChildren() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.family_restroom,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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

  Widget _buildSearchBar() {
    return Container(
      padding: EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surface,
      child: TextField(
        controller: _searchController,
        onChanged: (value) => _searchQuery.value = value,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
        ),
        decoration: InputDecoration(
          hintText: 'Buscar contacto o hijo...',
          hintStyle: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          prefixIcon: Icon(
            Icons.search,
            color: Theme.of(context).colorScheme.primary,
          ),
          filled: true,
          fillColor: context.customColors.searchBarBackground,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  /// Tab de solicitudes pendientes
  Widget _buildPendingTab(List<String> childrenIds) {
    return StreamBuilder<List<ContactRequest>>(
      stream: _controller.getPendingContactRequests(),
      builder: (context, contactSnapshot) {
        return StreamBuilder<List<PermissionRequest>>(
          stream: _controller.getPendingPermissionRequests(),
          builder: (context, groupSnapshot) {
            if (contactSnapshot.hasError || groupSnapshot.hasError) {
              return Center(
                child: Text('Error al cargar solicitudes'),
              );
            }

            if (contactSnapshot.connectionState == ConnectionState.waiting ||
                groupSnapshot.connectionState == ConnectionState.waiting) {
              return Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            }

            // Combinar ambos tipos de solicitudes
            final contactRequests = contactSnapshot.data ?? [];
            final permissionRequests = groupSnapshot.data ?? [];

            final allRequests = _controller.combinePendingRequests(
              contactRequests: contactRequests,
              permissionRequests: permissionRequests,
            );

            if (allRequests.isEmpty) {
              return _buildEmptyState(
                icon: Icons.check_circle_outline,
                title: '¡Todo al día!',
                subtitle: 'No hay solicitudes pendientes',
              );
            }

            return _buildRequestsList(
              requests: allRequests,
              showBulkActions: true,
            );
          },
        );
      },
    );
  }

  /// Tab de solicitudes aprobadas
  Widget _buildApprovedTab() {
    return StreamBuilder<List<ContactRequest>>(
      stream: _controller.getApprovedContactRequests(),
      builder: (context, contactSnapshot) {
        return StreamBuilder<List<PermissionRequest>>(
          stream: _controller.getApprovedPermissionRequests(),
          builder: (context, groupSnapshot) {
            if (contactSnapshot.hasError || groupSnapshot.hasError) {
              return Center(child: Text('Error al cargar solicitudes aprobadas'));
            }

            if (contactSnapshot.connectionState == ConnectionState.waiting ||
                groupSnapshot.connectionState == ConnectionState.waiting) {
              return Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            }

            // Combinar ambos tipos
            final contactRequests = contactSnapshot.data ?? [];
            final permissionRequests = groupSnapshot.data ?? [];

            final allRequests = _controller.combineApprovedRequests(
              contactRequests: contactRequests,
              permissionRequests: permissionRequests,
            );

            if (allRequests.isEmpty) {
              return _buildEmptyState(
                icon: Icons.shield_outlined,
                title: 'Sin solicitudes aprobadas',
                subtitle: 'Las solicitudes aprobadas aparecerán aquí',
              );
            }

            return _buildApprovedRequestsList(requests: allRequests);
          },
        );
      },
    );
  }

  /// Tab de solicitudes rechazadas
  Widget _buildRejectedTab(List<String> childrenIds) {
    return StreamBuilder<List<ContactRequest>>(
      stream: _controller.getRejectedContactRequests(),
      builder: (context, contactSnapshot) {
        return StreamBuilder<List<PermissionRequest>>(
          stream: _controller.getRejectedPermissionRequests(),
          builder: (context, groupSnapshot) {
            if (contactSnapshot.hasError || groupSnapshot.hasError) {
              return Center(child: Text('Error al cargar solicitudes rechazadas'));
            }

            if (contactSnapshot.connectionState == ConnectionState.waiting ||
                groupSnapshot.connectionState == ConnectionState.waiting) {
              return Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            }

            final contactRequests = contactSnapshot.data ?? [];
            final permissionRequests = groupSnapshot.data ?? [];

            final allRequests = _controller.combineRejectedRequests(
              contactRequests: contactRequests,
              permissionRequests: permissionRequests,
            );

            if (allRequests.isEmpty) {
              return _buildEmptyState(
                icon: Icons.block_outlined,
                title: 'Sin solicitudes rechazadas',
                subtitle: 'Las solicitudes rechazadas aparecerán aquí',
              );
            }

            return _buildRejectedRequestsList(requests: allRequests);
          },
        );
      },
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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

  Widget _buildRequestsList({
    required List<Map<String, dynamic>> requests,
    required bool showBulkActions,
  }) {
    return Column(
      children: [
        if (showBulkActions && _controller.selectedRequests.isNotEmpty)
          _buildBulkActionsBar(),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              return PendingRequestCard(
                request: request,
                controller: _controller,
                searchQuery: _searchQuery,
                onSelectionChanged: () => setState(() {}),
                onApprove: _handleApproveSingleRequest,
                onReject: _handleRejectSingleRequest,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildApprovedRequestsList({
    required List<Map<String, dynamic>> requests,
  }) {
    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: requests.length,
      itemBuilder: (context, index) {
        final request = requests[index];
        return ApprovedRequestCard(
          request: request,
          controller: _controller,
          searchQuery: _searchQuery,
          onRevoke: _handleRevokeApproval,
        );
      },
    );
  }

  Widget _buildRejectedRequestsList({
    required List<Map<String, dynamic>> requests,
  }) {
    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: requests.length,
      itemBuilder: (context, index) {
        final request = requests[index];
        return RejectedRequestCard(
          request: request,
          controller: _controller,
          searchQuery: _searchQuery,
          onReApprove: _handleReApproveRequest,
        );
      },
    );
  }

  Widget _buildBulkActionsBar() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _handleApproveSelected,
              icon: Icon(Icons.check_circle, size: 18),
              label: Text('Aprobar Seleccionadas'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          SizedBox(width: 12),
          IconButton(
            onPressed: () => setState(() => _controller.selectedRequests.clear()),
            icon: Icon(Icons.close),
            color: Colors.red,
            tooltip: 'Cancelar selección',
          ),
        ],
      ),
    );
  }

  // Event handlers (llaman al controller)

  Future<void> _handleApproveSingleRequest(
    String requestId,
    String childId,
    Map<String, dynamic> data,
    String type,
  ) async {
    setState(() {}); // Actualizar UI para mostrar loader

    final result = await _controller.approveSingleRequest(
      requestId: requestId,
      childId: childId,
      data: data,
      type: type,
    );

    setState(() {}); // Actualizar UI después de completar

    if (!result['success'] && mounted) {
      _showErrorSnackBar(result['error']);
    }
  }

  Future<void> _handleRejectSingleRequest(String requestId, String type) async {
    final result = await _controller.rejectSingleRequest(
      requestId: requestId,
      type: type,
    );

    setState(() {});

    if (result['success'] && mounted) {
      _showSuccessSnackBar('Solicitud rechazada');
    } else if (!result['success'] && mounted) {
      _showErrorSnackBar(result['error']);
    }
  }

  Future<void> _handleRevokeApproval(
    String requestId,
    String childId,
    String contactName,
    String type,
    Map<String, dynamic> data,
  ) async {
    List<String>? groupsToRemove;

    // Solo verificar grupos compartidos si es un contacto
    if (type == 'contact') {
      // Obtener el contactId del teléfono
      final contactPhone = data['contactPhone'] as String?;
      if (contactPhone != null) {
        try {
          // Buscar el userId por teléfono
          final userQuery = await FirebaseFirestore.instance
              .collection('users')
              .where('phoneNumber', isEqualTo: contactPhone)
              .limit(1)
              .get();

          if (userQuery.docs.isNotEmpty) {
            final contactId = userQuery.docs.first.id;

            // Verificar si comparten grupos
            final sharedGroups = await _controller.getSharedGroups(
              childId: childId,
              contactId: contactId,
            );

            if (sharedGroups.isNotEmpty) {
              // Mostrar alerta de grupos compartidos
              final shouldRemoveFromGroups = await _showSharedGroupsDialog(
                childId: childId,
                contactName: contactName,
                sharedGroups: sharedGroups,
              );

              if (shouldRemoveFromGroups == null) {
                return; // Usuario canceló
              }

              if (shouldRemoveFromGroups) {
                groupsToRemove = sharedGroups.map((g) => g['id'] as String).toList();
              }
            }
          }
        } catch (e) {
          print('❌ Error verificando grupos compartidos: $e');
        }
      }
    }

    final confirmed = await _showConfirmDialog(
      title: 'Revocar Aprobación',
      message: '¿Deseas revocar la aprobación de "$contactName"?\n\nEsto bloqueará el chat entre ellos.',
    );

    if (confirmed != true) return;

    setState(() {});

    final result = await _controller.revokeApproval(
      requestId: requestId,
      childId: childId,
      type: type,
      data: data,
      groupsToRemove: groupsToRemove,
    );

    setState(() {});

    if (result['success'] && mounted) {
      _showSuccessSnackBar('Aprobación revocada');
    } else if (!result['success'] && mounted) {
      _showErrorSnackBar(result['error']);
    }
  }

  Future<void> _handleReApproveRequest(
    String requestId,
    String childId,
    Map<String, dynamic> data,
    String type,
  ) async {
    setState(() {});

    final result = await _controller.reApproveRequest(
      requestId: requestId,
      childId: childId,
      data: data,
      type: type,
    );

    setState(() {});

    if (result['success'] && mounted) {
      _showSuccessSnackBar('Solicitud re-aprobada');
    } else if (!result['success'] && mounted) {
      _showErrorSnackBar(result['error']);
    }
  }

  Future<void> _handleApproveSelected() async {
    if (_controller.selectedRequests.isEmpty) return;

    final confirmed = await _showConfirmDialog(
      title: 'Aprobar solicitudes',
      message: '¿Deseas aprobar ${_controller.selectedRequests.length} solicitud${_controller.selectedRequests.length > 1 ? 'es' : ''}?',
    );

    if (confirmed != true) return;

    // TODO: Implement bulk approval
    _showInfoSnackBar('Funcionalidad en desarrollo');
  }

  // Helper methods

  Future<bool?> _showSharedGroupsDialog({
    required String childId,
    required String contactName,
    required List<Map<String, dynamic>> sharedGroups,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
        title: Text(
          '⚠️ Grupos Compartidos Detectados',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tu hijo comparte ${sharedGroups.length} ${sharedGroups.length == 1 ? 'grupo' : 'grupos'} con $contactName:',
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
                        '${group['name']} (${group['memberCount']} miembros)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: Colors.orange),
                        SizedBox(width: 8),
                        Text(
                          '¿Qué deseas hacer?',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.orange.shade800,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Aunque revoques el contacto, tu hijo podrá seguir comunicándose con $contactName a través de estos grupos.',
                      style: TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
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
            child: Text(
              'Mantener en grupos',
              style: TextStyle(color: Colors.orange),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
            ),
            child: Text('Sacar de grupos (Recomendado)'),
          ),
        ],
        actionsPadding: EdgeInsets.all(16),
      ),
    );
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: Text('Confirmar'),
          ),
        ],
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    // Success feedback removed - user sees visual confirmation in the UI
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('❌ $message'),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showInfoSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildModerationCard(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(context, '/chat_moderation_management');
      },
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: isDarkMode
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF667eea), // Soft indigo
                    Color(0xFF764ba2), // Deep purple
                  ],
                )
              : null,
          color: isDarkMode ? null : Colors.white,
          border: isDarkMode
              ? null
              : Border.all(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                  width: 2,
                ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: isDarkMode
                  ? Color(0xFF667eea).withValues(alpha: 0.3)
                  : Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              blurRadius: 12,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDarkMode
                    ? Colors.white.withValues(alpha: 0.2)
                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.psychology,
                color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.primary,
                size: 28,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Moderación con IA',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Gestiona la protección automática',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDarkMode
                          ? Colors.white.withValues(alpha: 0.9)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: isDarkMode ? Colors.white : Theme.of(context).colorScheme.primary,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
