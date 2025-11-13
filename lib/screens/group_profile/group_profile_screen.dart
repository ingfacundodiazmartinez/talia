import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../controllers/group_profile_controller.dart';
import '../../services/calls/calls_orchestrator.dart';
import 'widgets/add_members_dialog.dart';
import '../video_call_screen.dart';

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

class _GroupProfileScreenState extends State<GroupProfileScreen> {
  // ✅ CORRECTO: Solo controller y estado UI local
  late GroupProfileController _controller;
  final ImagePicker _picker = ImagePicker();
  final CallsOrchestrator _callsOrchestrator = CallsOrchestrator();

  // Estado UI únicamente
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  bool _isEditing = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    _controller = GroupProfileController(groupId: widget.groupId);

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // ✅ CORRECTO: Delegar inicialización al controller
    _controller.initialize();
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

    return Scaffold(
      appBar: _buildAppBar(),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Header del grupo
            _buildGroupHeader(groupData),

            const SizedBox(height: 20),

            // Información del grupo
            _buildGroupInfo(groupData),

            const SizedBox(height: 20),

            // Lista de miembros
            _buildMembersSection(),

            const SizedBox(height: 20),

            // Solicitudes pendientes (solo para admins)
            if (_controller.isAdmin && _controller.pendingRequests.isNotEmpty)
              _buildPendingRequestsSection(),

            const SizedBox(height: 20),

            // Acciones del grupo
            _buildGroupActions(),

            const SizedBox(height: 40),
          ],
        ),
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
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Avatar del grupo
          Stack(
            children: [
              CircleAvatar(
                radius: 60,
                backgroundImage: groupData['photoURL'] != null
                    ? NetworkImage(groupData['photoURL'])
                    : null,
                child: groupData['photoURL'] == null
                    ? const Icon(Icons.group, size: 60)
                    : null,
              ),
              if (_controller.isAdmin && _isEditing)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Theme.of(context).primaryColor,
                    child: IconButton(
                      icon: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                      onPressed: _isUploading ? null : _changeGroupAvatar,
                    ),
                  ),
                ),
              if (_isUploading)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(60),
                    ),
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 16),

          // Nombre del grupo
          if (_isEditing)
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Nombre del grupo',
                border: OutlineInputBorder(),
              ),
              maxLength: 50,
            )
          else
            Text(
              groupData['name'] ?? 'Sin nombre',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),

          const SizedBox(height: 8),

          // Descripción del grupo
          if (_isEditing)
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Descripción',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              maxLength: 200,
            )
          else if (groupData['description'] != null && groupData['description'].isNotEmpty)
            Text(
              groupData['description'],
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),

          const SizedBox(height: 8),

          // Información adicional
          Text(
            '${_controller.members.length} miembros',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupInfo(Map<String, dynamic> groupData) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Información del Grupo',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Creado', _formatDate(groupData['createdAt'])),
            _buildInfoRow('ID del Grupo', widget.groupId),
            if (_controller.isAdmin)
              _buildInfoRow('Rol', 'Administrador'),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(value ?? 'No disponible'),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersSection() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Miembros (${_controller.members.length})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_controller.isAdmin)
                  IconButton(
                    icon: const Icon(Icons.person_add),
                    onPressed: _showAddMembersDialog,
                  ),
              ],
            ),
          ),
          ...(_controller.members.map((member) => _buildMemberTile(member))),
        ],
      ),
    );
  }

  Widget _buildMemberTile(Map<String, dynamic> member) {
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: member['photoURL'] != null
            ? NetworkImage(member['photoURL'])
            : null,
        child: member['photoURL'] == null
            ? Text(member['name'][0].toUpperCase())
            : null,
      ),
      title: Text(member['displayName'] ?? member['name']),
      subtitle: Text(member['role'] == 'child' ? 'Niño' : 'Adulto'),
      trailing: _controller.isAdmin && member['id'] != _controller.currentUserId
          ? PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'remove',
                  child: const Text('Remover del grupo'),
                  onTap: () => _removeMember(member['id']),
                ),
                PopupMenuItem(
                  value: 'call',
                  child: const Text('Videollamada'),
                  onTap: () => _startVideoCall(member['id'], member['name']),
                ),
              ],
            )
          : member['id'] != _controller.currentUserId
              ? IconButton(
                  icon: const Icon(Icons.video_call),
                  onPressed: () => _startVideoCall(member['id'], member['name']),
                )
              : null,
    );
  }

  Widget _buildPendingRequestsSection() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Solicitudes Pendientes (${_controller.pendingRequests.length})',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...(_controller.pendingRequests.map((request) => _buildRequestTile(request))),
        ],
      ),
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

  Widget _buildGroupActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          if (_controller.isAdmin) ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.person_add),
              label: const Text('Agregar Miembros'),
              onPressed: _showAddMembersDialog,
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.exit_to_app),
            label: const Text('Abandonar Grupo'),
            onPressed: _leaveGroup,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
            ),
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

  Future<void> _startVideoCall(String userId, String userName) async {
    try {
      // ✅ MIGRADO: Usar CallsOrchestrator para crear llamadas con nueva arquitectura
      final result = await _callsOrchestrator.createCall(
        participantIds: [userId],
        type: 'video',
      );

      if (result['success']) {
        final callId = result['callId'];
        final channelName = result['channelName'];
        final token = result['token'];

        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => VideoCallScreen(
                callId: callId,
                channelName: channelName,
                token: token,
                uid: 0, // Se generará dinámicamente
                isCaller: true,
                remoteName: userName,
                receiverId: userId,
                isVideo: true,
              ),
            ),
          );
        }
      } else {
        // Manejar error de inicio de llamada
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Error al iniciar videollamada: ${result['error']}',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error iniciando videollamada: $e')),
        );
      }
    }
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

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return 'No disponible';

    try {
      DateTime date;
      if (timestamp is int) {
        date = DateTime.fromMillisecondsSinceEpoch(timestamp);
      } else {
        // Assume Firestore Timestamp, but we shouldn't access it directly
        return 'Fecha no disponible';
      }

      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return 'Fecha no disponible';
    }
  }
}