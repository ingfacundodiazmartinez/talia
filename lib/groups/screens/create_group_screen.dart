import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import '../controllers/controllers.dart';
import 'group_chat_screen.dart';

/// Screen for creating a new group (Groups V2)
///
/// This screen allows users to:
/// - Set a group name and optional description
/// - Select an avatar image
/// - Select members from bidirectionally approved contacts
///
/// After creation, navigates to the group chat.
class CreateGroupScreenV2 extends StatefulWidget {
  const CreateGroupScreenV2({super.key});

  @override
  State<CreateGroupScreenV2> createState() => _CreateGroupScreenV2State();
}

class _CreateGroupScreenV2State extends State<CreateGroupScreenV2> {
  // Controller
  late CreateGroupController _controller;

  // UI Controllers
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Local UI state
  List<GroupContactInfo> _filteredContacts = [];
  final List<GroupContactInfo> _selectedContacts = [];
  File? _groupImageFile;
  final ImagePicker _imagePicker = ImagePicker();
  bool _isUploadingImage = false;

  // For navigation after group creation
  String? _createdGroupId;
  String? _createdGroupName;
  bool _creatorPending = false;

  @override
  void initState() {
    super.initState();
    _controller = CreateGroupController();
    _setupControllerCallbacks();
    _controller.loadAvailableContacts();
    _searchController.addListener(_filterContacts);
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _descriptionController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setupControllerCallbacks() {
    _controller.onContactsLoaded = (contacts) {
      if (mounted) {
        setState(() {
          _filteredContacts = List.from(contacts);
        });
      }
    };

    _controller.onLoadingChanged = (isLoading) {
      if (mounted) {
        setState(() {});
      }
    };

    _controller.onCreatingChanged = (isCreating) {
      if (mounted) {
        setState(() {});
      }
    };

    _controller.onError = (message) {
      if (mounted) {
        _showSnackbar(message, isError: true);
      }
    };

    _controller.onSuccess = (message) {
      if (mounted) {
        _showSnackbar(message, isError: false);
      }
    };

    _controller.onGroupCreated = (groupId, groupName, creatorPending) {
      _createdGroupId = groupId;
      _createdGroupName = groupName;
      _creatorPending = creatorPending;
    };
  }

  void _filterContacts() {
    final query = _searchController.text;
    setState(() {
      _filteredContacts = _controller.filterContacts(query);
    });
  }

  Future<void> _pickGroupImage() async {
    if (_isUploadingImage) return;

    try {
      setState(() {
        _isUploadingImage = true;
      });

      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );

      if (image != null) {
        setState(() {
          _groupImageFile = File(image.path);
        });
      }
    } catch (e) {
      _showSnackbar('Error al seleccionar la imagen', isError: true);
    } finally {
      setState(() {
        _isUploadingImage = false;
      });
    }
  }

  Future<void> _createGroup() async {
    final groupName = _groupNameController.text.trim();
    final description = _descriptionController.text.trim();

    // Clear navigation variables
    _createdGroupId = null;
    _createdGroupName = null;
    _creatorPending = false;

    final success = await _controller.createGroup(
      name: groupName,
      description: description.isNotEmpty ? description : null,
      memberIds: _selectedContacts.map((c) => c.id).toList(),
      avatarFile: _groupImageFile,
    );

    // Navigate after group creation
    if (success && mounted && _createdGroupId != null) {
      if (_creatorPending) {
        // El creador (child) está pendiente de aprobación del padre
        // Volver a la lista de chats con un warning
        Navigator.of(context).pop(); // Cerrar pantalla de creación

        // Mostrar snackbar con advertencia
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Grupo "$groupName" creado. Tu padre debe aprobar tu participación para poder acceder.',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        // El creador tiene acceso inmediato - navegar al grupo
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => GroupChatScreenV2(
              groupId: _createdGroupId!,
              groupName: _createdGroupName ?? groupName,
            ),
          ),
        );
      }
    }
  }

  void _showSnackbar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  bool get _canCreate =>
      _groupNameController.text.trim().isNotEmpty &&
      _selectedContacts.isNotEmpty &&
      !_controller.isCreating;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.primary,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _controller.isCreating ? null : () => Navigator.pop(context),
        ),
        title: const Text('Nuevo Grupo'),
        actions: [
          TextButton(
            onPressed: _canCreate ? _createGroup : null,
            child: _controller.isCreating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Text(
                    'Crear',
                    style: TextStyle(
                      color: _canCreate ? Colors.white : Colors.white54,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: Column(
        children: [
          // Top section: Avatar and name
          Flexible(
            flex: 0,
            child: SingleChildScrollView(
              child: Container(
                color: colorScheme.surface,
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Avatar
                    GestureDetector(
                      onTap: _isUploadingImage ? null : _pickGroupImage,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.primary.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: _isUploadingImage
                            ? Center(
                                child: SizedBox(
                                  width: 30,
                                  height: 30,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      colorScheme.primary,
                                    ),
                                  ),
                                ),
                              )
                            : _groupImageFile != null
                                ? ClipOval(
                                    child: Image.file(
                                      _groupImageFile!,
                                      fit: BoxFit.cover,
                                      width: 80,
                                      height: 80,
                                    ),
                                  )
                                : Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.add_a_photo,
                                        size: 28,
                                        color: colorScheme.primary,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Agregar foto',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Name field
                    TextField(
                      controller: _groupNameController,
                      textCapitalization: TextCapitalization.words,
                      style: TextStyle(color: colorScheme.onSurface),
                      decoration: InputDecoration(
                        hintText: 'Nombre del grupo',
                        prefixIcon: Icon(Icons.group, color: colorScheme.primary),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      onChanged: (value) => setState(() {}),
                    ),
                    const SizedBox(height: 12),

                    // Description field (optional)
                    TextField(
                      controller: _descriptionController,
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(color: colorScheme.onSurface),
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: 'Descripcion (opcional)',
                        prefixIcon: Icon(
                          Icons.description_outlined,
                          color: colorScheme.primary,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const Divider(height: 1),

          // Bottom section: Contact list
          Expanded(
            child: _controller.isLoading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      // Search bar
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Buscar contactos...',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),

                      // Selected count indicator
                      Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _selectedContacts.isEmpty
                              ? colorScheme.surfaceContainerHighest
                              : colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.people,
                              color: _selectedContacts.isEmpty
                                  ? colorScheme.onSurfaceVariant
                                  : colorScheme.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _selectedContacts.isEmpty
                                    ? 'Selecciona contactos para el grupo'
                                    : '${_selectedContacts.length} de ${CreateGroupController.maxMembers} miembros seleccionados',
                                style: TextStyle(
                                  color: _selectedContacts.isEmpty
                                      ? colorScheme.onSurfaceVariant
                                      : colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Contact list
                      Expanded(
                        child: _controller.allContacts.isEmpty
                            ? _buildEmptyState()
                            : _filteredContacts.isEmpty
                                ? _buildNoResultsState()
                                : ListView.builder(
                                    controller: _scrollController,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    itemCount: _filteredContacts.length,
                                    itemBuilder: (context, index) {
                                      final contact = _filteredContacts[index];
                                      final isSelected =
                                          _selectedContacts.contains(contact);
                                      return _buildContactItem(
                                        contact,
                                        isSelected,
                                      );
                                    },
                                  ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildContactItem(GroupContactInfo contact, bool isSelected) {
    final colorScheme = Theme.of(context).colorScheme;
    final reachedLimit =
        _selectedContacts.length >= CreateGroupController.maxMembers;
    final isDisabled = !isSelected && reachedLimit;

    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? colorScheme.primaryContainer.withValues(alpha: 0.5)
              : colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: CircleAvatar(
            radius: 24,
            backgroundColor: colorScheme.primaryContainer,
            child: contact.avatar != null && contact.avatar!.isNotEmpty
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: contact.avatar!,
                      width: 48,
                      height: 48,
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
                    contact.name.isNotEmpty
                        ? contact.name[0].toUpperCase()
                        : 'U',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
          ),
          title: Text(
            contact.name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          trailing: Checkbox(
            value: isSelected,
            onChanged: isDisabled
                ? null
                : (value) {
                    setState(() {
                      if (isSelected) {
                        _selectedContacts.remove(contact);
                      } else {
                        _selectedContacts.add(contact);
                      }
                    });
                  },
            activeColor: colorScheme.primary,
          ),
          onTap: isDisabled
              ? () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  _showSnackbar(
                    'Has alcanzado el limite de ${CreateGroupController.maxMembers} miembros',
                    isError: true,
                  );
                }
              : () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() {
                    if (isSelected) {
                      _selectedContacts.remove(contact);
                    } else {
                      _selectedContacts.add(contact);
                    }
                  });
                },
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No tienes contactos disponibles',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Para crear grupos necesitas contactos con aprobacion bidireccional',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResultsState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No se encontraron contactos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Intenta con otro termino de busqueda',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
