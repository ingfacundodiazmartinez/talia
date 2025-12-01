import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../controllers/create_group_controller.dart';
import 'group_chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  // Controller
  late CreateGroupController _controller;

  // UI Controllers
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Local UI state
  List<ContactInfo> _filteredContacts = [];
  final List<ContactInfo> _selectedContacts = [];
  File? _groupImageFile;
  final ImagePicker _imagePicker = ImagePicker();
  bool _isUploadingImage = false;

  // Para navegación después de crear grupo
  String? _createdGroupId;
  String? _createdGroupName;

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
    _searchController.dispose();
    _scrollController.dispose();
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

    // onGroupCreated se usa para capturar el groupId para la navegación
    // La navegación real se hace en _createGroup después de que todo termine
    _controller.onGroupCreated = (groupId, groupName) {
      // Guardar para navegar después
      _createdGroupId = groupId;
      _createdGroupName = groupName;
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

    // Limpiar variables de navegación
    _createdGroupId = null;
    _createdGroupName = null;

    final success = await _controller.createGroup(
      groupName: groupName,
      selectedContacts: _selectedContacts,
      groupImageFile: _groupImageFile,
    );

    // Navegar al grupo si se creó exitosamente
    if (success && mounted && _createdGroupId != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => GroupChatScreen(
            groupId: _createdGroupId!,
            groupName: _createdGroupName ?? groupName,
          ),
        ),
      );
    }
  }


  void _showSnackbar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        duration: Duration(seconds: 2),
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
          icon: Icon(Icons.close),
          onPressed: _controller.isCreating ? null : () => Navigator.pop(context),
        ),
        title: Text('Nuevo Grupo'),
        actions: [
          TextButton(
            onPressed: _canCreate ? _createGroup : null,
            child: _controller.isCreating
                ? SizedBox(
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
          SizedBox(width: 8),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          // Sección superior: Avatar y nombre (scrollable para evitar keyboard)
          Flexible(
            flex: 0,
            child: SingleChildScrollView(
              child: Container(
                color: colorScheme.surface,
                padding: EdgeInsets.all(16),
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
                                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
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
                                  SizedBox(height: 4),
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
                SizedBox(height: 16),

                // Campo nombre
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
                      borderSide: BorderSide(color: colorScheme.primary, width: 2),
                    ),
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  onChanged: (value) => setState(() {}),
                ),
              ],
                ),
              ),
            ),
          ),

          Divider(height: 1),

          // Sección inferior: Lista de contactos (scrollable)
          Expanded(
            child: _controller.isLoading
                ? Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      // Barra de búsqueda
                      Container(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Buscar contactos...',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),

                      // Contador de seleccionados
                      Container(
                        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        padding: EdgeInsets.all(12),
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
                            SizedBox(width: 8),
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

                      // Lista de contactos
                      Expanded(
                        child: _controller.allContacts.isEmpty
                            ? _buildEmptyState()
                            : _filteredContacts.isEmpty
                                ? _buildNoResultsState()
                                : ListView.builder(
                                    controller: _scrollController,
                                    padding: EdgeInsets.symmetric(horizontal: 16),
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
    );
  }

  Widget _buildContactItem(ContactInfo contact, bool isSelected) {
    final colorScheme = Theme.of(context).colorScheme;
    final reachedLimit = _selectedContacts.length >= CreateGroupController.maxMembers;
    final isDisabled = !isSelected && reachedLimit;

    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
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
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colorScheme.primaryContainer,
                backgroundImage: contact.avatar != null && contact.avatar!.isNotEmpty
                    ? NetworkImage(contact.avatar!)
                    : null,
                child: contact.avatar == null || contact.avatar!.isEmpty
                    ? Text(
                        contact.name.isNotEmpty
                            ? contact.name[0].toUpperCase()
                            : 'U',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      )
                    : null,
              ),
            ],
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
                    'Has alcanzado el límite de ${CreateGroupController.maxMembers} miembros',
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
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: colorScheme.outlineVariant,
            ),
            SizedBox(height: 16),
            Text(
              'No tienes contactos disponibles',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Para crear grupos necesitas contactos con aprobación bidireccional',
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
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: colorScheme.outlineVariant,
            ),
            SizedBox(height: 16),
            Text(
              'No se encontraron contactos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Intenta con otro término de búsqueda',
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
