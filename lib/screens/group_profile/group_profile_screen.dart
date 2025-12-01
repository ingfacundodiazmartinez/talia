import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../controllers/group_profile_controller.dart';
import '../../calls_v2/screens/agora_call_screen.dart';
import '../child/profile/widgets/media_gallery_widget.dart';
import 'widgets/add_members_dialog.dart';

/// Pantalla de perfil de grupo refactorizada siguiendo CODING_RULES.md
///
/// Responsabilidades:
/// - Solo UI y gestión de eventos de usuario
/// - Delegación total a GroupProfileController para toda la lógica
/// - ZERO Firebase calls (todas están en GroupProfileController)
/// - Estado UI mínimo, todo coordinado por controller
class GroupProfileScreen extends StatefulWidget {
  final String groupId;

  const GroupProfileScreen({
    super.key,
    required this.groupId,
  });

  @override
  State<GroupProfileScreen> createState() => _GroupProfileScreenState();
}

class _GroupProfileScreenState extends State<GroupProfileScreen>
    with TickerProviderStateMixin {
  // ✅ CORRECTO: Solo controller y estado UI local
  late GroupProfileController _controller;
  final ImagePicker _picker = ImagePicker();

  // Tab controller para Participantes, Multimedia y Favoritos
  late TabController _tabController;

  // Estado UI únicamente
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  bool _isEditing = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    // ✅ 3 tabs: Participantes, Multimedia, Favoritos
    _tabController = TabController(length: 3, vsync: this);

    // Listener para cargar favoritos cuando se cambia al tab
    _tabController.addListener(_onTabChanged);

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    _controller = GroupProfileController(groupId: widget.groupId);

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // ✅ CORRECTO: Delegar inicialización al controller
    _controller.initialize();
  }

  void _onTabChanged() {
    // Cargar favoritos cuando se cambia al tab de Favoritos (índice 2)
    if (_tabController.index == 2 && _controller.favoriteMessages.isEmpty && !_controller.isLoadingFavorites) {
      _controller.loadFavorites();
    }
  }

  /// Configurar callbacks del controller para actualizar UI
  void _setupControllerCallbacks() {
    _controller.onGroupDataChanged = (groupData) {
      if (mounted && groupData != null) {
        setState(() {
          _nameController.text = groupData['name'] ?? '';
          _descriptionController.text = groupData['description'] ?? '';
        });
      }
    };

    _controller.onMembersChanged = (members) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para mostrar nuevos miembros
        });
      }
    };

    _controller.onPendingMembersChanged = (pendingMembers) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para mostrar miembros pendientes
        });
      }
    };

    _controller.onPendingRequestsChanged = (requests) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para mostrar solicitudes
        });
      }
    };

    _controller.onAdminStatusChanged = (isAdmin) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para permisos de admin
        });
      }
    };

    _controller.onLoadingChanged = (isLoading) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para indicador de carga
        });
      }
    };

    _controller.onFavoritesChanged = (favorites) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para mostrar favoritos
        });
      }
    };

    _controller.onError = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    };

    _controller.onSuccess = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    };
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    // ✅ CORRECTO: Delegar limpieza al controller
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Perfil del Grupo')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_controller.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Perfil del Grupo')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_controller.errorMessage ?? 'Error desconocido'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => _controller.initialize(),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    final groupData = _controller.groupData;
    if (groupData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Perfil del Grupo')),
        body: const Center(child: Text('Grupo no encontrado')),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // Header del grupo (fijo arriba)
          _buildGroupHeader(groupData),

          // TabBar
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: colorScheme.primary,
              labelColor: colorScheme.primary,
              unselectedLabelColor: colorScheme.onSurfaceVariant,
              indicatorWeight: 3,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(
                  icon: const Icon(Icons.people),
                  text: 'Participantes (${_controller.members.length})',
                ),
                const Tab(icon: Icon(Icons.photo_library), text: 'Multimedia'),
                const Tab(icon: Icon(Icons.star_outline), text: 'Favoritos'),
              ],
            ),
          ),

          // TabBarView con scroll independiente en cada tab
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Tab 1: Participantes
                _buildParticipantsTab(),
                // Tab 2: Multimedia
                _buildMultimediaTab(),
                // Tab 3: Favoritos
                _buildFavoritesTab(colorScheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: Text(_isEditing ? 'Editar Grupo' : 'Perfil del Grupo'),
      actions: [
        if (_controller.isAdmin)
          IconButton(
            icon: Icon(_isEditing ? Icons.save : Icons.edit),
            onPressed: _isEditing ? _saveChanges : _startEditing,
          ),
      ],
    );
  }

  Widget _buildGroupHeader(Map<String, dynamic> groupData) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Avatar del grupo
          Stack(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundImage: groupData['avatar'] != null
                    ? NetworkImage(groupData['avatar'])
                    : null,
                child: groupData['avatar'] == null
                    ? const Icon(Icons.group, size: 40)
                    : null,
              ),
              if (_controller.isAdmin && _isEditing)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: Theme.of(context).primaryColor,
                    child: IconButton(
                      icon: const Icon(Icons.camera_alt, size: 12, color: Colors.white),
                      onPressed: _isUploading ? null : _changeGroupAvatar,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
              if (_isUploading)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(40),
                    ),
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(width: 16),

          // Nombre y descripción
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isEditing)
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Nombre del grupo',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLength: 50,
                  )
                else
                  Text(
                    groupData['name'] ?? 'Sin nombre',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                if (_isEditing)
                  TextField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Descripción',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 2,
                    maxLength: 200,
                  )
                else if (groupData['description'] != null && groupData['description'].isNotEmpty)
                  Text(
                    groupData['description'],
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tab 1: Lista de participantes con scroll
  Widget _buildParticipantsTab() {
    return ListView(
      children: [
        // Botón agregar miembros (solo admin)
        if (_controller.isAdmin)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
              child: Icon(Icons.person_add, color: Theme.of(context).primaryColor),
            ),
            title: const Text('Agregar participantes'),
            onTap: _showAddMembersDialog,
          ),

        // Miembros pendientes de aprobación de permisos
        if (_controller.pendingMembers.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Pendientes de aprobación (${_controller.pendingMembers.length})',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.orange,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Estos usuarios serán agregados cuando sus padres aprueben los contactos necesarios.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ...(_controller.pendingMembers.map((member) => _buildPendingMemberTile(member))),
          const Divider(),
        ],

        // Solicitudes pendientes de ingreso (solo admin)
        if (_controller.isAdmin && _controller.pendingRequests.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Solicitudes de ingreso (${_controller.pendingRequests.length})',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
          ),
          ...(_controller.pendingRequests.map((request) => _buildRequestTile(request))),
          const Divider(),
        ],

        // Lista de miembros
        ...(_controller.members.map((member) => _buildMemberTile(member))),

        const SizedBox(height: 20),

        // Botón abandonar grupo
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.exit_to_app),
            label: const Text('Abandonar Grupo'),
            onPressed: _leaveGroup,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ),

        const SizedBox(height: 40),
      ],
    );
  }

  /// Tab 2: Galería multimedia con scroll
  Widget _buildMultimediaTab() {
    return MediaGalleryWidget(
      chatId: widget.groupId,
      isOwnProfile: false,
    );
  }

  /// Tab 3: Favoritos
  Widget _buildFavoritesTab(ColorScheme colorScheme) {
    // Mostrar loading mientras carga
    if (_controller.isLoadingFavorites) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Mostrar estado vacío si no hay favoritos
    if (_controller.favoriteMessages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.star_border_rounded,
              size: 80,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 24),
            Text(
              'No hay mensajes favoritos',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Text(
                'Mantén presionado cualquier mensaje y marca como favorito para verlo aquí',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey.shade600,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Mostrar lista de favoritos
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final groupName = _controller.groupData?['name'] ?? 'Grupo';

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      itemCount: _controller.favoriteMessages.length,
      itemBuilder: (context, index) {
        final message = _controller.favoriteMessages[index];
        final isMe = message.senderId == currentUserId;
        final timeString = message.timestamp != null
            ? '${message.timestamp!.toDate().day}/${message.timestamp!.toDate().month} ${message.timestamp!.toDate().hour}:${message.timestamp!.toDate().minute.toString().padLeft(2, '0')}'
            : '';

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildFavoriteMessageCard(
            message: message,
            isMe: isMe,
            timeString: timeString,
            groupName: groupName,
            colorScheme: colorScheme,
          ),
        );
      },
    );
  }

  /// Construye una tarjeta para mostrar un mensaje favorito
  Widget _buildFavoriteMessageCard({
    required dynamic message,
    required bool isMe,
    required String timeString,
    required String groupName,
    required ColorScheme colorScheme,
  }) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header con icono de estrella y tiempo
            Row(
              children: [
                Icon(
                  Icons.star,
                  size: 16,
                  color: Colors.amber.shade600,
                ),
                const SizedBox(width: 4),
                Text(
                  isMe ? 'Tú' : (message.senderName ?? 'Usuario'),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: colorScheme.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  timeString,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Contenido del mensaje
            if (message.text != null && message.text!.isNotEmpty)
              Text(
                message.text!,
                style: const TextStyle(fontSize: 15),
              ),
            // Indicador de media si hay imagen/video/audio
            if (message.imageUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    message.imageUrl!,
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 60,
                      color: Colors.grey.shade200,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.image, color: Colors.grey.shade400),
                          const SizedBox(width: 8),
                          Text('Imagen', style: TextStyle(color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (message.videoUrl != null && message.imageUrl == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam, color: Colors.grey.shade600),
                      const SizedBox(width: 8),
                      Text('Video', style: TextStyle(color: Colors.grey.shade700)),
                    ],
                  ),
                ),
              ),
            if (message.audioUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic, color: Colors.grey.shade600),
                      const SizedBox(width: 8),
                      Text('Audio', style: TextStyle(color: Colors.grey.shade700)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingMemberTile(Map<String, dynamic> member) {
    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundImage: member['photoURL'] != null
                ? NetworkImage(member['photoURL'])
                : null,
            child: member['photoURL'] == null
                ? Text((member['name'] as String? ?? 'U')[0].toUpperCase())
                : null,
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: Colors.orange,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.hourglass_empty, size: 8, color: Colors.white),
            ),
          ),
        ],
      ),
      title: Text(
        member['displayName'] ?? member['name'] ?? 'Usuario',
        style: TextStyle(color: Colors.grey[700]),
      ),
      subtitle: Text(
        'Esperando aprobación de permisos',
        style: TextStyle(
          color: Colors.orange[700],
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildMemberTile(Map<String, dynamic> member) {
    final isCurrentUser = member['id'] == _controller.currentUserId;

    return ListTile(
      leading: CircleAvatar(
        backgroundImage: member['photoURL'] != null
            ? NetworkImage(member['photoURL'])
            : null,
        child: member['photoURL'] == null
            ? Text(member['name'][0].toUpperCase())
            : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              member['displayName'] ?? member['name'],
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isCurrentUser)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '(Tú)',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(member['role'] == 'child' ? 'Niño' : 'Adulto'),
      trailing: !isCurrentUser
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón videollamada
                IconButton(
                  icon: const Icon(Icons.video_call),
                  onPressed: () => _startVideoCall(member['id'], member['name']),
                  tooltip: 'Videollamada',
                ),
                // Menú admin
                if (_controller.isAdmin)
                  PopupMenuButton(
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'remove',
                        child: const Row(
                          children: [
                            Icon(Icons.remove_circle_outline, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Remover del grupo'),
                          ],
                        ),
                        onTap: () => _removeMember(member['id']),
                      ),
                    ],
                  ),
              ],
            )
          : null,
    );
  }

  Widget _buildRequestTile(Map<String, dynamic> request) {
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: request['photoURL'] != null
            ? NetworkImage(request['photoURL'])
            : null,
        child: request['photoURL'] == null
            ? Text(request['name'][0].toUpperCase())
            : null,
      ),
      title: Text(request['name']),
      subtitle: Text(request['message'] ?? 'Quiere unirse al grupo'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check, color: Colors.green),
            onPressed: () => _approveRequest(request['requestId'], request['userId']),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            onPressed: () => _rejectRequest(request['requestId']),
          ),
        ],
      ),
    );
  }

  // Métodos de UI que delegan al controller
  void _startEditing() {
    setState(() {
      _isEditing = true;
    });
  }

  Future<void> _saveChanges() async {
    final success = await _controller.updateGroupInfo(
      name: _nameController.text,
      description: _descriptionController.text,
    );

    if (success) {
      setState(() {
        _isEditing = false;
      });
    }
  }

  Future<void> _changeGroupAvatar() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );

    if (image != null) {
      setState(() {
        _isUploading = true;
      });

      final success = await _controller.updateGroupInfo(
        avatarFile: File(image.path),
      );

      setState(() {
        _isUploading = false;
      });

      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error subiendo imagen')),
        );
      }
    }
  }

  void _showAddMembersDialog() {
    final memberIds = _controller.members.map((m) => m['id'] as String).toList();
    showDialog(
      context: context,
      builder: (context) => AddMembersDialog(
        groupId: widget.groupId,
        currentMembers: memberIds,
      ),
    );
  }

  Future<void> _removeMember(String userId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover Miembro'),
        content: const Text('¿Estás seguro de que quieres remover este miembro del grupo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _controller.removeMember(userId);
    }
  }

  Future<void> _approveRequest(String requestId, String userId) async {
    await _controller.approveRequest(requestId, userId);
  }

  Future<void> _rejectRequest(String requestId) async {
    await _controller.rejectRequest(requestId);
  }

  void _startVideoCall(String userId, String userName) {
    if (!mounted) return;

    // ✅ Navegación inmediata - la llamada se crea en background
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (context) => AgoraCallScreen.create(
          participantIds: [userId],
          isVideo: true,
          isGroup: false,
        ),
      ),
    );
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandonar Grupo'),
        content: const Text('¿Estás seguro de que quieres abandonar este grupo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abandonar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _controller.leaveGroup();
      if (success && mounted) {
        Navigator.pop(context); // Regresar a la pantalla anterior
      }
    }
  }
}
