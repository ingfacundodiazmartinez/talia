import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../../widgets/profile_photo_viewer.dart';
import '../../widgets/group_moderation_dialog.dart';
import '../../screens/child/profile/widgets/media_gallery_widget.dart';
import '../../screens/group_profile/widgets/add_members_dialog.dart'; // ✅ FIX #10
import '../../services/favorite_service.dart';
import '../../services/group_moderation_service.dart';
import '../../services/subscription_service.dart' show PremiumFeature;
import '../../widgets/premium_paywall_dialog.dart';
import '../../services/image_service.dart';

/// Profile screen for Groups V2
///
/// Shows group details, members, and admin controls.
class GroupProfileScreenV2 extends StatefulWidget {
  final String groupId;
  /// Callback to cancel subscriptions before leaving the group
  /// This prevents Firestore permission errors
  final VoidCallback? onBeforeLeave;

  const GroupProfileScreenV2({
    super.key,
    required this.groupId,
    this.onBeforeLeave,
  });

  @override
  State<GroupProfileScreenV2> createState() => _GroupProfileScreenV2State();
}

class _GroupProfileScreenV2State extends State<GroupProfileScreenV2>
    with TickerProviderStateMixin {
  final GroupService _groupService = GroupService();
  final FavoriteService _favoriteService = FavoriteService();
  final GroupModerationService _moderationService = GroupModerationService();

  /// True mientras se guarda el toggle "solo administradores"
  bool _updatingAdminOnly = false;

  Group? _group;
  bool _isLoading = true;
  bool _isUpdating = false;
  StreamSubscription? _groupSubscription;

  // Tab controller for media/favorites
  late TabController _tabController;

  // Batch selection state
  bool _isSelectionMode = false;
  final Set<String> _selectedMembers = {};

  // Favorites state
  List<Map<String, dynamic>> _favoriteMessages = [];
  bool _isLoadingFavorites = true;

  // Optimistic members (shown immediately while waiting for Firestore)
  final List<ContactInfo> _optimisticMembers = [];

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';
  bool get _isAdmin => _group?.isAdmin(_currentUserId) ?? false;

  @override
  void initState() {
    super.initState();
    // 4 tabs si es admin (incluye Moderación), 3 si no
    _tabController = TabController(length: 4, vsync: this);
    _loadGroup();
    _loadFavorites();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _groupSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    try {
      final favorites = await _favoriteService.getFavoriteMessagesForProfile(
        chatId: widget.groupId,
        isGroupChat: true,
      );

      if (mounted) {
        setState(() {
          _favoriteMessages = favorites;
          _isLoadingFavorites = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingFavorites = false);
      }
    }
  }

  Future<void> _loadGroup() async {
    _groupSubscription = _groupService.watchGroup(widget.groupId).listen(
      (group) {
        if (mounted) {
          setState(() {
            _group = group;
            _isLoading = false;
            // Limpiar miembros optimistas cuando llegan datos reales de Firestore
            _optimisticMembers.clear();
          });
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      },
    );
  }

  Future<void> _handleLeaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Salir del grupo'),
        content: const Text('Estas seguro que quieres salir de este grupo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Salir'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // ✅ FIX: Cancelar suscripciones ANTES de salir del grupo
      // Esto evita errores de permisos de Firestore
      widget.onBeforeLeave?.call();
      _groupSubscription?.cancel();

      final success = await _groupService.leaveGroup(widget.groupId);

      if (mounted) {
        if (success) {
          // Devolver 'left' al GroupChatScreen para que maneje la navegación
          Navigator.of(context).pop('left');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al salir del grupo'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleEditName() async {
    if (!_isAdmin || _group == null) return;

    final controller = TextEditingController(text: _group!.name);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar nombre'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nombre del grupo',
            border: OutlineInputBorder(),
          ),
          maxLength: 50,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, name);
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (newName != null && newName != _group!.name && mounted) {
      setState(() => _isUpdating = true);

      final success = await _groupService.updateGroupInfo(
        widget.groupId,
        name: newName,
      );

      if (mounted) {
        setState(() => _isUpdating = false);

        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al actualizar el nombre'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleEditDescription() async {
    if (!_isAdmin || _group == null) return;

    final controller = TextEditingController(text: _group!.description ?? '');

    final newDescription = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar descripcion'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Descripcion (opcional)',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          maxLength: 200,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (newDescription != null && newDescription != (_group!.description ?? '') && mounted) {
      setState(() => _isUpdating = true);

      final success = await _groupService.updateGroupInfo(
        widget.groupId,
        description: newDescription.isEmpty ? null : newDescription,
      );

      if (mounted) {
        setState(() => _isUpdating = false);

        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al actualizar la descripcion'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleChangeAvatar() async {
    if (!_isAdmin) return;

    setState(() => _isUpdating = true);

    try {
      // Usar ImageService para pick + crop circular
      final croppedFile = await ImageService().pickAndCropCircularImage(context);

      if (croppedFile == null || !mounted) {
        if (mounted) setState(() => _isUpdating = false);
        return;
      }

      // Upload image
      final avatarUrl = await _groupService.uploadGroupAvatar(
        widget.groupId,
        croppedFile,
      );

      if (avatarUrl != null && mounted) {
        final success = await _groupService.updateGroupInfo(
          widget.groupId,
          avatar: avatarUrl,
        );

        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al actualizar la foto'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _group == null
              ? _buildErrorState()
              : CustomScrollView(
                  slivers: [
                    _buildAppBar(colorScheme),
                    SliverToBoxAdapter(
                      child: _buildHeader(colorScheme),
                    ),
                    SliverToBoxAdapter(
                      child: _buildGroupInfo(colorScheme),
                    ),
                    SliverToBoxAdapter(
                      child: _buildTabs(colorScheme),
                    ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: 32),
                    ),
                  ],
                ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDarkMode
              ? [
                  colorScheme.primary.withValues(alpha: 0.3),
                  colorScheme.primary.withValues(alpha: 0.1),
                ]
              : [colorScheme.primary, colorScheme.primary.withValues(alpha: 0.8)],
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          // Avatar clickeable para ampliar
          GestureDetector(
            onTap: () {
              if (_group!.avatar != null && _group!.avatar!.isNotEmpty) {
                ProfilePhotoViewer.show(context, _group!.avatar!, _group!.name);
              }
            },
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 60,
                  backgroundColor: Colors.white.withValues(alpha: 0.3),
                  backgroundImage: _group!.avatar != null && _group!.avatar!.isNotEmpty
                      ? CachedNetworkImageProvider(_group!.avatar!)
                      : null,
                  child: _group!.avatar == null || _group!.avatar!.isEmpty
                      ? Icon(
                          Icons.group,
                          size: 48,
                          color: Colors.white,
                        )
                      : null,
                ),
                // Edit button for admin
                if (_isAdmin)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _handleChangeAvatar,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Group name
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _group!.name,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_isAdmin) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                  onPressed: _handleEditName,
                  tooltip: 'Editar nombre',
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          // Member count
          Text(
            '${_group!.memberCount} miembros',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          const Text('No se pudo cargar el grupo'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Volver'),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(ColorScheme colorScheme) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: colorScheme.primary,
      foregroundColor: Colors.white,
      title: const Text('Perfil del grupo'),
      actions: [
        if (_isUpdating)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          )
        else
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Opciones',
            onPressed: _showOptionsMenu,
          ),
      ],
    );
  }

  void _showOptionsMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            // Opciones de edición solo para admins
            if (_isAdmin) ...[
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Cambiar nombre'),
                onTap: () {
                  Navigator.pop(context);
                  _handleEditName();
                },
              ),
              ListTile(
                leading: const Icon(Icons.description),
                title: const Text('Cambiar descripcion'),
                onTap: () {
                  Navigator.pop(context);
                  _handleEditDescription();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Cambiar foto'),
                onTap: () {
                  Navigator.pop(context);
                  _handleChangeAvatar();
                },
              ),
              const Divider(),
            ],
            // Salir del grupo - disponible para todos
            ListTile(
              leading: const Icon(Icons.exit_to_app, color: Colors.red),
              title: const Text(
                'Salir del grupo',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(context);
                _handleLeaveGroup();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupInfo(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_group!.description != null && _group!.description!.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Descripcion',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _group!.description!,
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildInfoChip(
                colorScheme,
                Icons.group,
                '${_group!.memberCount} miembros',
              ),
              const SizedBox(width: 8),
              _buildInfoChip(
                colorScheme,
                Icons.calendar_today,
                'Creado ${_formatDate(_group!.createdAt)}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(ColorScheme colorScheme, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(ColorScheme colorScheme) {
    final membersCount = _group!.memberCount;

    // Calcular altura dinámica para miembros
    // ListTile estándar = 72px, con header adicional
    const double listTileHeight = 72.0;
    const double sectionHeaderHeight = 48.0;
    const double addButtonHeight = 56.0;
    const double selectionHeaderHeight = 48.0;

    final membersListHeight = _calculateMembersTabHeight(
      listTileHeight: listTileHeight,
      sectionHeaderHeight: sectionHeaderHeight,
      addButtonHeight: addButtonHeight,
      selectionHeaderHeight: selectionHeaderHeight,
    );

    // Altura mínima para multimedia, favoritos y moderación
    const double minTabHeight = 300.0;
    const double moderationTabHeight = 400.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Tab Bar
          Container(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: colorScheme.primary,
              labelColor: colorScheme.primary,
              unselectedLabelColor: colorScheme.onSurfaceVariant,
              indicatorWeight: 3,
              dividerColor: Colors.transparent,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              labelStyle: const TextStyle(fontSize: 11),
              unselectedLabelStyle: const TextStyle(fontSize: 11),
              tabs: [
                Tab(
                  icon: Badge(
                    label: Text('$membersCount'),
                    isLabelVisible: membersCount > 0,
                    child: const Icon(Icons.people_outline, size: 22),
                  ),
                  text: 'Miembros',
                ),
                const Tab(icon: Icon(Icons.photo_library_outlined, size: 22), text: 'Multimedia'),
                const Tab(icon: Icon(Icons.star_outline, size: 22), text: 'Favoritos'),
                const Tab(icon: Icon(Icons.psychology_outlined, size: 22), text: 'Moderacion'),
              ],
            ),
          ),
          // Tab View con altura dinámica basada en el tab seleccionado
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, child) {
              // Calcular altura según el tab activo
              double currentHeight;
              switch (_tabController.index) {
                case 0: // Miembros
                  currentHeight = membersListHeight;
                  break;
                case 1: // Multimedia
                case 2: // Favoritos
                  currentHeight = minTabHeight;
                  break;
                case 3: // Moderación
                  currentHeight = moderationTabHeight;
                  break;
                default:
                  currentHeight = minTabHeight;
              }

              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: currentHeight,
                child: TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(), // Deshabilitar swipe entre tabs
                  children: [
                    // Tab 1: Members - sin scroll interno
                    _buildMembersTab(colorScheme),
                    // Tab 2: Media gallery
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: MediaGalleryWidget(
                        chatId: widget.groupId,
                        isOwnProfile: false,
                      ),
                    ),
                    // Tab 3: Favorites
                    _buildFavoritesTab(colorScheme),
                    // Tab 4: Moderation
                    _buildModerationTab(colorScheme),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Calcula la altura necesaria para mostrar todos los miembros
  double _calculateMembersTabHeight({
    required double listTileHeight,
    required double sectionHeaderHeight,
    required double addButtonHeight,
    required double selectionHeaderHeight,
  }) {
    double height = 16; // Padding vertical

    // Barra de acciones unificada (Agregar + Seleccionar) - solo admin
    if (_isAdmin) {
      height += 56; // Altura de la fila de botones
    }

    // Miembros activos
    final members = _group!.memberDetails.values.toList();
    height += members.length * listTileHeight;

    // Miembros optimistas
    height += _optimisticMembers.length * listTileHeight;

    // Sección de miembros pendientes
    final pendingMembers = _group!.pendingMemberDetails.values.toList();
    if (pendingMembers.isNotEmpty) {
      height += sectionHeaderHeight; // Header "Pendientes"
      height += pendingMembers.length * listTileHeight;
    }

    // Mínimo y máximo
    return height.clamp(200.0, 800.0);
  }

  Widget _buildMembersTab(ColorScheme colorScheme) {
    final members = _group!.memberDetails.values.toList();
    final pendingMembers = _group!.pendingMemberDetails.values.toList();

    // Filter out members that can't be selected (current user, creator, admins if not admin)
    final selectableMembers = members.where((m) {
      final isCreator = _group!.createdBy == m.userId;
      final isCurrentUser = m.userId == _currentUserId;
      return !isCreator && !isCurrentUser;
    }).toList();

    // ✅ FIX: NeverScrollableScrollPhysics - el scroll lo maneja el CustomScrollView padre
    // La altura del contenedor se calcula dinámicamente para mostrar todos los miembros
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      children: [
        // ✅ Barra de acciones unificada (Agregar + Seleccionar)
        if (_isAdmin)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _isSelectionMode
                // Modo selección: Cancelar, Todos/Ninguno, Eliminar
                ? Row(
                    children: [
                      // Cancel button
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _isSelectionMode = false;
                            _selectedMembers.clear();
                          });
                        },
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Cancelar'),
                        style: TextButton.styleFrom(
                          foregroundColor: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      // Select all button
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (_selectedMembers.length == selectableMembers.length) {
                              _selectedMembers.clear();
                            } else {
                              _selectedMembers.clear();
                              for (final m in selectableMembers) {
                                _selectedMembers.add(m.userId);
                              }
                            }
                          });
                        },
                        child: Text(
                          _selectedMembers.length == selectableMembers.length
                              ? 'Ninguno'
                              : 'Todos',
                        ),
                      ),
                      // Delete selected button
                      if (_selectedMembers.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: ElevatedButton.icon(
                            onPressed: _handleBatchRemoveMembers,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            icon: const Icon(Icons.delete, size: 16),
                            label: Text('${_selectedMembers.length}'),
                          ),
                        ),
                    ],
                  )
                // Modo normal: Agregar + Seleccionar
                : Row(
                    children: [
                      // Agregar participantes
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showAddMembersDialog,
                          icon: const Icon(Icons.person_add_rounded, size: 18),
                          label: const Text('Agregar'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colorScheme.primary,
                            side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.5)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Seleccionar (solo si hay miembros seleccionables)
                      if (selectableMembers.isNotEmpty)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _isSelectionMode = true;
                              });
                            },
                            icon: const Icon(Icons.checklist_rounded, size: 18),
                            label: const Text('Seleccionar'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colorScheme.onSurfaceVariant,
                              side: BorderSide(color: colorScheme.outlineVariant),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),

        // Active members
        ...members.map((member) => _buildMemberTile(colorScheme, member)),

        // ✅ OPTIMISTIC: Mostrar miembros que se están agregando
        ..._optimisticMembers.map((contact) => _buildOptimisticMemberTile(colorScheme, contact)),

        // Pending members section
        if (pendingMembers.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.hourglass_empty, size: 18, color: Colors.orange),
                const SizedBox(width: 8),
                Text(
                  'Pendientes (${pendingMembers.length})',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange[700],
                  ),
                ),
              ],
            ),
          ),
          ...pendingMembers.map((member) => _buildPendingMemberTile(colorScheme, member)),
        ],
      ],
    );
  }

  Widget _buildFavoritesTab(ColorScheme colorScheme) {
    if (_isLoadingFavorites) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Cargando favoritos...',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    if (_favoriteMessages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.star_border_rounded,
                  color: colorScheme.primary,
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Sin mensajes favoritos',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Los mensajes que marques como favoritos apareceran aqui',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      physics: const ClampingScrollPhysics(),
      itemCount: _favoriteMessages.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final messageData = _favoriteMessages[index];

        final text = messageData['text'] ?? '';
        final formattedTime = messageData['formattedTime'] ?? '';
        final senderId = messageData['senderId'] ?? '';
        final senderName = messageData['senderName'] ?? 'Usuario';
        final isMe = senderId == _currentUserId;
        final mediaType = messageData['mediaType'] as String?;

        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.amber.withValues(alpha: 0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.amber.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with sender and time
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.star, color: Colors.amber[600], size: 16),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isMe ? 'Tu' : senderName,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formattedTime,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Message content
              if (mediaType != null) ...[
                Row(
                  children: [
                    Icon(
                      mediaType == 'image'
                          ? Icons.image
                          : mediaType == 'video'
                          ? Icons.videocam
                          : Icons.audiotrack,
                      color: colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        mediaType == 'image'
                            ? 'Imagen'
                            : mediaType == 'video'
                            ? 'Video'
                            : 'Audio',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurface,
                      height: 1.4,
                    ),
                  ),
                ],
              ] else if (text.isNotEmpty) ...[
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildMemberTile(ColorScheme colorScheme, GroupMember member) {
    final isMemberAdmin = _group!.isAdmin(member.userId);
    // ✅ FIX: Verificar que userId y createdBy no estén vacíos para evitar falsos positivos
    final isCreator = _group!.createdBy.isNotEmpty &&
                      member.userId.isNotEmpty &&
                      _group!.createdBy == member.userId;
    final isCurrentUser = _currentUserId.isNotEmpty &&
                          member.userId.isNotEmpty &&
                          member.userId == _currentUserId;
    final canSelect = !isCreator && !isCurrentUser;
    final isSelected = _selectedMembers.contains(member.userId);

    return ListTile(
      leading: _isSelectionMode && canSelect
          ? Checkbox(
              value: isSelected,
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _selectedMembers.add(member.userId);
                  } else {
                    _selectedMembers.remove(member.userId);
                  }
                });
              },
            )
          : CircleAvatar(
              backgroundColor: colorScheme.primaryContainer,
              child: member.photoURL != null && member.photoURL!.isNotEmpty
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: member.photoURL!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Icon(
                          Icons.person,
                          color: colorScheme.primary,
                        ),
                        errorWidget: (context, url, error) => Icon(
                          Icons.person,
                          color: colorScheme.primary,
                        ),
                      ),
                    )
                  : Text(
                      member.name.isNotEmpty ? member.name[0].toUpperCase() : 'U',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
            ),
      title: Row(
        children: [
          Text(
            member.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (isMemberAdmin) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                isCreator ? 'Creador' : 'Admin',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        member.role == UserRole.child ? 'Menor' :
        member.role == UserRole.parent ? 'Adulto' : '',
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      // In selection mode, tap toggles selection
      onTap: _isSelectionMode && canSelect
          ? () {
              setState(() {
                if (isSelected) {
                  _selectedMembers.remove(member.userId);
                } else {
                  _selectedMembers.add(member.userId);
                }
              });
            }
          : null,
      // Only show options if current user is admin and not viewing themselves (and not in selection mode)
      trailing: (!_isSelectionMode && _isAdmin && !isCurrentUser && !isCreator)
          ? IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showMemberOptions(member, isMemberAdmin),
            )
          : null,
      onLongPress: (!_isSelectionMode && _isAdmin && !isCurrentUser && !isCreator)
          ? () => _showMemberOptions(member, isMemberAdmin)
          : null,
    );
  }

  /// ✅ OPTIMISTIC: Tile para miembros que se están agregando
  Widget _buildOptimisticMemberTile(ColorScheme colorScheme, ContactInfo contact) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer.withValues(alpha: 0.5),
        child: contact.avatar != null && contact.avatar!.isNotEmpty
            ? ClipOval(
                child: CachedNetworkImage(
                  imageUrl: contact.avatar!,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Icon(
                    Icons.person,
                    color: colorScheme.primary.withValues(alpha: 0.5),
                  ),
                  errorWidget: (context, url, error) => Icon(
                    Icons.person,
                    color: colorScheme.primary.withValues(alpha: 0.5),
                  ),
                ),
              )
            : Text(
                contact.name.isNotEmpty ? contact.name[0].toUpperCase() : 'U',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary.withValues(alpha: 0.5),
                ),
              ),
      ),
      title: Text(
        contact.name,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
      trailing: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
        ),
      ),
    );
  }

  void _showMemberOptions(GroupMember member, bool isMemberAdmin) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            if (!isMemberAdmin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings, color: Colors.blue),
                title: const Text('Hacer administrador'),
                subtitle: const Text('Podra editar el grupo y gestionar miembros'),
                onTap: () {
                  Navigator.pop(context);
                  _handlePromoteToAdmin(member);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.remove_moderator, color: Colors.orange),
                title: const Text('Quitar administrador'),
                subtitle: const Text('Ya no podra editar el grupo'),
                onTap: () {
                  Navigator.pop(context);
                  _handleRemoveAdmin(member);
                },
              ),
            ListTile(
              leading: const Icon(Icons.person_remove, color: Colors.red),
              title: const Text('Eliminar del grupo'),
              subtitle: const Text('Ya no podra ver ni enviar mensajes'),
              onTap: () {
                Navigator.pop(context);
                _handleRemoveMember(member);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handlePromoteToAdmin(GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hacer administrador'),
        content: Text('Deseas hacer a ${member.name} administrador del grupo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isUpdating = true);

      final success = await _groupService.promoteToAdmin(
        groupId: widget.groupId,
        userId: member.userId,
      );

      if (mounted) {
        setState(() => _isUpdating = false);

        // Solo mostrar snackbar si hubo error
        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al promover administrador'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleRemoveAdmin(GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quitar administrador'),
        content: Text('Deseas quitar a ${member.name} como administrador?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isUpdating = true);

      final success = await _groupService.removeAdmin(
        groupId: widget.groupId,
        userId: member.userId,
      );

      if (mounted) {
        setState(() => _isUpdating = false);

        // Solo mostrar snackbar si hubo error
        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al quitar administrador'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleRemoveMember(GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar del grupo'),
        content: Text('Deseas eliminar a ${member.name} del grupo? Ya no podra ver ni enviar mensajes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final memberName = member.name;
      final memberId = member.userId;
      final groupId = widget.groupId;

      // ✅ OPTIMISTIC: Mostrar feedback inmediato sin bloquear UI
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Eliminando a $memberName...'),
          duration: Duration(seconds: 1),
        ),
      );

      // Ejecutar en background
      final success = await _groupService.removeMember(
        groupId: groupId,
        userId: memberId,
      );

      if (mounted && !success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al eliminar miembro'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Batch remove multiple selected members
  Future<void> _handleBatchRemoveMembers() async {
    if (_selectedMembers.isEmpty) return;

    final count = _selectedMembers.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar miembros'),
        content: Text(
          '¿Deseas eliminar $count miembro${count > 1 ? 's' : ''} del grupo?\n\n'
          'Ya no podrán ver ni enviar mensajes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Eliminar $count'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final selectedIds = _selectedMembers.toList();
      final groupId = widget.groupId;

      // ✅ OPTIMISTIC: Limpiar selección y mostrar feedback inmediato
      setState(() {
        _isSelectionMode = false;
        _selectedMembers.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Eliminando $count miembro${count > 1 ? 's' : ''}...'),
          duration: Duration(seconds: 2),
        ),
      );

      // Ejecutar en background
      int errorCount = 0;
      for (final userId in selectedIds) {
        final success = await _groupService.removeMember(
          groupId: groupId,
          userId: userId,
        );
        if (!success) errorCount++;
      }

      // Solo mostrar error si hubo problemas
      if (mounted && errorCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar $errorCount miembro${errorCount > 1 ? 's' : ''}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// ✅ FIX #10: Mostrar diálogo para agregar miembros al grupo
  Future<void> _showAddMembersDialog() async {
    if (_group == null) return;

    final memberIds = _group!.memberDetails.keys.toList();
    final result = await showDialog<List<ContactInfo>>(
      context: context,
      builder: (context) => AddMembersDialog(
        groupId: widget.groupId,
        currentMembers: memberIds,
      ),
    );

    // ✅ OPTIMISTIC: Agregar los contactos inmediatamente a la lista
    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        _optimisticMembers.addAll(result);
      });
    }
  }

  Widget _buildPendingMemberTile(ColorScheme colorScheme, PendingMember member) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.orange.shade100,
        child: member.photoURL != null && member.photoURL!.isNotEmpty
            ? ClipOval(
                child: CachedNetworkImage(
                  imageUrl: member.photoURL!,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Icon(
                    Icons.person,
                    color: Colors.orange.shade700,
                  ),
                  errorWidget: (context, url, error) => Icon(
                    Icons.person,
                    color: Colors.orange.shade700,
                  ),
                ),
              )
            : Text(
                member.name.isNotEmpty ? member.name[0].toUpperCase() : 'U',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade700,
                ),
              ),
      ),
      title: Text(
        member.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'Esperando aprobacion de padres',
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Pendiente',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.orange.shade800,
          ),
        ),
      ),
    );
  }

  /// Tab de moderación con IA
  Widget _buildModerationTab(ColorScheme colorScheme) {
    final moderationEnabled = _group?.moderationEnabled ?? false;
    final moderationLevel = _group?.moderationLevel ?? 'high';
    const Color aiColor = Color(0xFF5C6BC0);

    // Si no es admin, mostrar mensaje informativo
    if (!_isAdmin) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.psychology_outlined,
                  color: colorScheme.onSurfaceVariant,
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                moderationEnabled ? 'Moderacion activa' : 'Moderacion no configurada',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                moderationEnabled
                    ? 'Este grupo tiene moderacion con IA activada (Nivel ${_getLevelLabel(moderationLevel)})'
                    : 'Solo los administradores pueden configurar la moderacion',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              if (_group?.adminOnlyMessages == true) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Solo los administradores pueden enviar mensajes',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    // Vista para admins
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  aiColor.withValues(alpha: 0.1),
                  aiColor.withValues(alpha: 0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: aiColor.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: aiColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.psychology,
                    color: aiColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Moderacion con IA',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Protege las conversaciones del grupo',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Estado actual
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: moderationEnabled
                  ? Colors.green.withValues(alpha: 0.1)
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: moderationEnabled
                    ? Colors.green.withValues(alpha: 0.3)
                    : colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  moderationEnabled ? Icons.shield : Icons.shield_outlined,
                  color: moderationEnabled ? Colors.green : colorScheme.onSurfaceVariant,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        moderationEnabled ? 'Proteccion activa' : 'Proteccion desactivada',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: moderationEnabled ? Colors.green[700] : colorScheme.onSurface,
                        ),
                      ),
                      if (moderationEnabled)
                        Text(
                          'Nivel: ${_getLevelLabel(moderationLevel)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.green[600],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Descripción
          Text(
            'La moderacion con IA analiza los mensajes del grupo para detectar contenido inapropiado, acoso o lenguaje ofensivo.',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),

          // Botón de configuración
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _handleModerationTap,
              icon: Icon(moderationEnabled ? Icons.settings : Icons.add_moderator),
              label: Text(moderationEnabled ? 'Configurar moderacion' : 'Activar moderacion'),
              style: ElevatedButton.styleFrom(
                backgroundColor: aiColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),

          // Configuración de mensajes (solo admins ven esta vista)
          const Text(
            'Mensajes',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: SwitchListTile(
              secondary: Icon(
                Icons.lock_outline,
                color: colorScheme.onSurfaceVariant,
              ),
              title: const Text(
                'Solo administradores pueden enviar mensajes',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                'Los demás miembros podrán leer pero no escribir',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              value: _group?.adminOnlyMessages ?? false,
              onChanged: _updatingAdminOnly ? null : _onAdminOnlyMessagesChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// Cambiar el toggle "solo administradores pueden enviar mensajes".
  /// El valor del switch refleja el stream del grupo; mientras se guarda,
  /// el switch queda deshabilitado y al confirmar Firestore el stream lo
  /// actualiza solo.
  Future<void> _onAdminOnlyMessagesChanged(bool value) async {
    setState(() => _updatingAdminOnly = true);

    final success = await _groupService.setAdminOnlyMessages(
      groupId: widget.groupId,
      enabled: value,
    );

    if (!mounted) return;
    setState(() => _updatingAdminOnly = false);

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo actualizar la configuración'),
        ),
      );
    }
  }

  String _getLevelLabel(String level) {
    switch (level) {
      case 'high':
        return 'Alto';
      case 'medium':
        return 'Medio';
      case 'low':
        return 'Bajo';
      default:
        return 'Alto';
    }
  }

  /// Maneja el tap en la sección de moderación
  Future<void> _handleModerationTap() async {
    // Verificar permisos
    final permissionCheck = await _moderationService.canModifyModeration(widget.groupId);

    if (!permissionCheck.canModify) {
      // Mostrar paywall si no tiene premium
      if (permissionCheck.reason.contains('Premium') && mounted) {
        PremiumPaywallDialog.show(
          context,
          feature: PremiumFeature.groupModeration,
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(permissionCheck.reason),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Mostrar dialog de configuración
    if (mounted) {
      GroupModerationDialog.show(
        context,
        groupId: widget.groupId,
        initialEnabled: _group?.moderationEnabled ?? false,
        initialLevel: _group?.moderationLevel ?? 'high',
        onChanged: (enabled, level) {
          // El stream de Firestore actualizará automáticamente _group
        },
      );
    }
  }

  String _formatDate(DateTime date) {
    final months = [
      '', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
    ];
    return '${date.day} ${months[date.month]}, ${date.year}';
  }
}
