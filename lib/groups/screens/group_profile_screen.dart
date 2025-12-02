import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../../widgets/profile_photo_viewer.dart';
import '../../screens/child/profile/widgets/media_gallery_widget.dart';
import '../../services/favorite_service.dart';

/// Profile screen for Groups V2
///
/// Shows group details, members, and admin controls.
class GroupProfileScreenV2 extends StatefulWidget {
  final String groupId;

  const GroupProfileScreenV2({
    super.key,
    required this.groupId,
  });

  @override
  State<GroupProfileScreenV2> createState() => _GroupProfileScreenV2State();
}

class _GroupProfileScreenV2State extends State<GroupProfileScreenV2>
    with TickerProviderStateMixin {
  final GroupService _groupService = GroupService();
  final FavoriteService _favoriteService = FavoriteService();
  final ImagePicker _imagePicker = ImagePicker();

  Group? _group;
  bool _isLoading = true;
  bool _isUpdating = false;
  StreamSubscription? _groupSubscription;

  // Tab controller for media/favorites
  late TabController _tabController;

  // Favorites state
  List<Map<String, dynamic>> _favoriteMessages = [];
  bool _isLoadingFavorites = true;

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';
  bool get _isAdmin => _group?.isAdmin(_currentUserId) ?? false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
      final success = await _groupService.leaveGroup(widget.groupId);

      if (mounted) {
        if (success) {
          Navigator.of(context).popUntil((route) => route.isFirst);
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

    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );

    if (image == null || !mounted) return;

    setState(() => _isUpdating = true);

    try {
      // Upload image first
      final avatarUrl = await _groupService.uploadGroupAvatar(
        widget.groupId,
        File(image.path),
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
                    SliverToBoxAdapter(
                      child: _buildActions(colorScheme),
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
      actions: _isAdmin
          ? [
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
                  icon: const Icon(Icons.edit),
                  tooltip: 'Editar grupo',
                  onPressed: _showEditOptions,
                ),
            ]
          : null,
    );
  }

  void _showEditOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
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
              labelPadding: const EdgeInsets.symmetric(horizontal: 8),
              tabs: [
                Tab(
                  icon: Badge(
                    label: Text('$membersCount'),
                    isLabelVisible: membersCount > 0,
                    child: const Icon(Icons.people_outline),
                  ),
                  text: 'Miembros',
                ),
                const Tab(icon: Icon(Icons.photo_library_outlined), text: 'Multimedia'),
                const Tab(icon: Icon(Icons.star_outline), text: 'Favoritos'),
              ],
            ),
          ),
          // Tab View
          SizedBox(
            height: 400,
            child: TabBarView(
              controller: _tabController,
              children: [
                // Tab 1: Members
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersTab(ColorScheme colorScheme) {
    final members = _group!.memberDetails.values.toList();
    final pendingMembers = _group!.pendingMemberDetails.values.toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // Active members
        ...members.map((member) => _buildMemberTile(colorScheme, member)),

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
    final isCreator = _group!.createdBy == member.userId;
    final isCurrentUser = member.userId == _currentUserId;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        backgroundImage: member.photoURL != null
            ? NetworkImage(member.photoURL!)
            : null,
        child: member.photoURL == null
            ? Text(
                member.name.isNotEmpty ? member.name[0].toUpperCase() : 'U',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              )
            : null,
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
      // Only show options if current user is admin and not viewing themselves
      trailing: (_isAdmin && !isCurrentUser && !isCreator)
          ? IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showMemberOptions(member, isMemberAdmin),
            )
          : null,
      onLongPress: (_isAdmin && !isCurrentUser && !isCreator)
          ? () => _showMemberOptions(member, isMemberAdmin)
          : null,
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '${member.name} ahora es administrador'
                  : 'Error al promover administrador',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '${member.name} ya no es administrador'
                  : 'Error al quitar administrador',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
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
      setState(() => _isUpdating = true);

      final success = await _groupService.removeMember(
        groupId: widget.groupId,
        userId: member.userId,
      );

      if (mounted) {
        setState(() => _isUpdating = false);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '${member.name} ha sido eliminado del grupo'
                  : 'Error al eliminar miembro',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildPendingMemberTile(ColorScheme colorScheme, PendingMember member) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.orange.shade100,
        backgroundImage: member.photoURL != null
            ? NetworkImage(member.photoURL!)
            : null,
        child: member.photoURL == null
            ? Text(
                member.name.isNotEmpty ? member.name[0].toUpperCase() : 'U',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade700,
                ),
              )
            : null,
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

  Widget _buildActions(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Divider(),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: Colors.red),
            title: const Text(
              'Salir del grupo',
              style: TextStyle(color: Colors.red),
            ),
            onTap: _handleLeaveGroup,
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      '', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
    ];
    return '${date.day} ${months[date.month]}, ${date.year}';
  }
}
