import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import '../services/group_chat_service.dart';
import '../services/chat_permission_service.dart';
import '../services/contact_alias_service.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  static const int maxMembers = 50;

  final GroupChatService _groupService = GroupChatService();
  final ChatPermissionService _permissionService = ChatPermissionService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ContactAliasService _aliasService = ContactAliasService();

  // Controllers
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Estado
  bool _isLoading = false;
  bool _isCreating = false;

  // Datos del grupo
  List<ContactInfo> _allContacts = [];
  List<ContactInfo> _filteredContacts = [];
  final List<ContactInfo> _selectedContacts = [];
  File? _groupImageFile;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadAvailableContacts();
    _searchController.addListener(_filterContacts);
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _filterContacts() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredContacts = List.from(_allContacts);
      } else {
        _filteredContacts = _allContacts.where((contact) {
          return contact.name.toLowerCase().contains(query) ||
              contact.email.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  Future<void> _loadAvailableContacts() async {
    setState(() => _isLoading = true);

    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      print('🔍 Cargando contactos con aprobación bidireccional...');

      final bidirectionalContactIds = await _permissionService
          .getBidirectionallyApprovedContacts(currentUserId);

      final contacts = <ContactInfo>[];

      for (final contactId in bidirectionalContactIds) {
        final userDoc = await _firestore.collection('users').doc(contactId).get();
        final userData = userDoc.data();

        if (userData != null) {
          final realName = userData['name'] ?? 'Usuario';
          final displayName =
              await _aliasService.getDisplayName(contactId, realName);

          contacts.add(
            ContactInfo(
              id: contactId,
              name: displayName,
              email: userData['email'] ?? '',
              avatar: userData['photoURL'],
              isOnline: userData['isOnline'] ?? false,
            ),
          );
        }
      }

      // Ordenar alfabéticamente
      contacts.sort((a, b) => a.name.compareTo(b.name));

      print('✅ Encontrados ${contacts.length} contactos');

      setState(() {
        _allContacts = contacts;
        _filteredContacts = List.from(contacts);
      });
    } catch (e) {
      print('❌ Error cargando contactos: $e');
      _showSnackbar('Error cargando contactos', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickGroupImage() async {
    try {
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
      print('❌ Error seleccionando imagen: $e');
      _showSnackbar('Error al seleccionar la imagen', isError: true);
    }
  }

  Future<String?> _uploadGroupImage() async {
    if (_groupImageFile == null) return null;

    try {
      final user = _auth.currentUser;
      if (user == null) return null;

      final fileName = 'group_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('group_images')
          .child(fileName);

      final uploadTask = await storageRef.putFile(_groupImageFile!);
      final downloadUrl = await uploadTask.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      print('❌ Error subiendo imagen del grupo: $e');
      return null;
    }
  }

  Future<void> _createGroup() async {
    final groupName = _groupNameController.text.trim();

    if (groupName.isEmpty) {
      _showSnackbar('El nombre del grupo es obligatorio', isError: true);
      return;
    }

    if (_selectedContacts.isEmpty) {
      _showSnackbar('Debes seleccionar al menos un contacto', isError: true);
      return;
    }

    setState(() => _isCreating = true);

    try {
      // Subir imagen del grupo si existe
      String? imageUrl;
      if (_groupImageFile != null) {
        imageUrl = await _uploadGroupImage();
      }

      final selectedUserIds = _selectedContacts.map((c) => c.id).toList();

      final result = await _groupService.createGroup(
        name: groupName,
        description: '',
        avatar: imageUrl,
        initialMembers: selectedUserIds,
      );

      if (mounted) {
        if (result.isSuccess || result.isPartialSuccess) {
          // Mostrar resultado y cerrar
          await _showSuccessDialog(result);
          if (mounted) {
            Navigator.pop(context, true); // Retornar true para indicar éxito
          }
        } else {
          _showSnackbar(result.error ?? 'Error creando grupo', isError: true);
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnackbar('Error creando grupo: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  Future<void> _showSuccessDialog(GroupCreationResult result) async {
    final colorScheme = Theme.of(context).colorScheme;

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: result.isSuccess
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.orange.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                result.isSuccess ? Icons.check_circle : Icons.schedule,
                size: 48,
                color: result.isSuccess ? Colors.green : Colors.orange,
              ),
            ),
            SizedBox(height: 16),
            Text(
              result.isSuccess ? '¡Grupo Creado!' : 'Grupo Creado Parcialmente',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12),
            Text(
              result.isSuccess
                  ? 'Tu grupo "${_groupNameController.text}" está listo.'
                  : '${result.pendingCount} ${result.pendingCount == 1 ? 'miembro está' : 'miembros están'} pendientes de aprobación.',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
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
      !_isCreating;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.primary,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: Icon(Icons.close),
          onPressed: _isCreating ? null : () => Navigator.pop(context),
        ),
        title: Text('Nuevo Grupo'),
        actions: [
          TextButton(
            onPressed: _canCreate ? _createGroup : null,
            child: _isCreating
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
      body: Column(
        children: [
          // Sección superior: Avatar y nombre (fija)
          Container(
            color: colorScheme.surface,
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                // Avatar
                GestureDetector(
                  onTap: _pickGroupImage,
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
                    child: _groupImageFile != null
                        ? ClipOval(
                            child: Image.file(
                              _groupImageFile!,
                              fit: BoxFit.cover,
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

          Divider(height: 1),

          // Sección inferior: Lista de contactos (scrollable)
          Expanded(
            child: _isLoading
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
                                    : '${_selectedContacts.length} de $maxMembers miembros seleccionados',
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
                        child: _allContacts.isEmpty
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
    final reachedLimit = _selectedContacts.length >= maxMembers;
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
              if (contact.isOnline)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: colorScheme.surface, width: 2),
                    ),
                  ),
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
                  _showSnackbar(
                    'Has alcanzado el límite de $maxMembers miembros',
                    isError: true,
                  );
                }
              : () {
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

// Clase para información de contacto
class ContactInfo {
  final String id;
  final String name;
  final String email;
  final String? avatar;
  final bool isOnline;

  ContactInfo({
    required this.id,
    required this.name,
    required this.email,
    this.avatar,
    required this.isOnline,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
