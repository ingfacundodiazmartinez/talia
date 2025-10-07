import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../../../controllers/edit_profile_controller.dart';
import '../../../services/image_service.dart';

/// Screen para editar perfil de usuario
///
/// Responsabilidades (SOLO UI):
/// - Mostrar formulario de edición
/// - Validar campos de entrada
/// - Delegar lógica al EditProfileController
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ImageService _imageService = ImageService();
  final _formKey = GlobalKey<FormState>();

  late EditProfileController _controller;
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  DateTime? _selectedBirthDate;
  bool _isLoading = false;
  bool _isUploadingImage = false;
  String? _profileImageUrl;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: _auth.currentUser?.displayName ?? '',
    );
    _phoneController = TextEditingController();

    _controller = EditProfileController(userId: _auth.currentUser!.uid);
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    try {
      await _controller.initialize();
      final userData = await _controller.loadUserData();

      if (userData != null && mounted) {
        setState(() {
          _phoneController.text = userData['phone'] ?? '';

          // Cargar fecha de nacimiento
          if (userData['birthDate'] != null) {
            if (userData['birthDate'] is Timestamp) {
              _selectedBirthDate =
                  (userData['birthDate'] as Timestamp).toDate();
            } else if (userData['birthDate'] is String) {
              _selectedBirthDate = DateTime.tryParse(userData['birthDate']);
            }
          }

          _profileImageUrl = userData['photoURL'] ?? _auth.currentUser?.photoURL;
        });
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar('Error al cargar datos: ${EditProfileController.getErrorMessage(e)}');
      }
    }
  }

  Future<void> _changeProfilePhoto() async {
    try {
      setState(() => _isUploadingImage = true);

      // Mostrar selector de fuente de imagen
      final ImageSource? source = await _imageService.showImageSourceSelection(
        context,
      );

      if (source == null) {
        setState(() => _isUploadingImage = false);
        return;
      }

      // Seleccionar imagen
      final String? imageUrl = await _imageService.pickAndUploadProfileImage(
        source: source,
        context: context,
      );

      // Si la imagen fue subida exitosamente, actualizar en Firestore via controller
      if (imageUrl != null && mounted) {
        await _controller.uploadProfilePhoto(imageUrl);
        setState(() {
          _profileImageUrl = imageUrl;
        });
        _showSuccessSnackBar('Foto de perfil actualizada exitosamente');
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar('Error al cambiar foto: ${EditProfileController.getErrorMessage(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _isUploadingImage = false);
      }
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await _controller.saveProfile(
        name: _nameController.text,
        phone: _phoneController.text,
        birthDate: _selectedBirthDate!,
      );

      if (mounted) {
        _showSuccessSnackBar('Perfil actualizado exitosamente');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar('Error al actualizar perfil: ${EditProfileController.getErrorMessage(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
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

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Editar Perfil'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildProfileAvatar(colorScheme),
                SizedBox(height: 40),
                _buildNameField(colorScheme),
                SizedBox(height: 24),
                _buildEmailField(colorScheme),
                SizedBox(height: 24),
                _buildPhoneField(colorScheme),
                SizedBox(height: 24),
                _buildBirthDateField(colorScheme),
                SizedBox(height: 40),
                _buildSaveButton(colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileAvatar(ColorScheme colorScheme) {
    return Center(
      child: Stack(
        children: [
          CircleAvatar(
            radius: 60,
            backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
            backgroundImage: _profileImageUrl != null &&
                    _profileImageUrl!.isNotEmpty
                ? NetworkImage(_profileImageUrl!)
                : null,
            child: _profileImageUrl == null || _profileImageUrl!.isEmpty
                ? Icon(
                    Icons.person,
                    size: 60,
                    color: colorScheme.primary,
                  )
                : null,
          ),
          if (_isUploadingImage)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              ),
            ),
          Positioned(
            bottom: 0,
            right: 0,
            child: GestureDetector(
              onTap: _isUploadingImage ? null : _changeProfilePhoto,
              child: Container(
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.surface, width: 3),
                ),
                child: Icon(
                  Icons.camera_alt,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNameField(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Nombre Completo',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        SizedBox(height: 8),
        TextFormField(
          controller: _nameController,
          decoration: InputDecoration(
            hintText: 'Ingresa tu nombre completo',
            prefixIcon: Icon(Icons.person_outline, color: colorScheme.primary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest,
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Por favor ingresa tu nombre';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildEmailField(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Correo Electrónico',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        SizedBox(height: 8),
        TextFormField(
          initialValue: _auth.currentUser?.email ?? '',
          enabled: false,
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.email_outlined,
                color: colorScheme.onSurfaceVariant),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor:
                colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          ),
        ),
        SizedBox(height: 8),
        Text(
          'El correo no se puede modificar',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildPhoneField(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Teléfono',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        SizedBox(height: 8),
        TextFormField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            hintText: '+54 9 11 1234-5678',
            prefixIcon: Icon(Icons.phone_outlined, color: colorScheme.primary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest,
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Por favor ingresa tu teléfono';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildBirthDateField(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Fecha de Nacimiento',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        SizedBox(height: 8),
        InkWell(
          onTap: () async {
            final DateTime? picked = await showDatePicker(
              context: context,
              initialDate: _selectedBirthDate ?? DateTime(2000, 1, 1),
              firstDate: DateTime(1924),
              lastDate: DateTime.now(),
            );
            if (picked != null) {
              setState(() {
                _selectedBirthDate = picked;
              });
            }
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              border: Border.all(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.2)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.cake_outlined, color: colorScheme.primary),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _selectedBirthDate == null
                        ? 'Selecciona tu fecha de nacimiento'
                        : '${_selectedBirthDate!.day}/${_selectedBirthDate!.month}/${_selectedBirthDate!.year}',
                    style: TextStyle(
                      fontSize: 16,
                      color: _selectedBirthDate == null
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                ),
                if (_selectedBirthDate != null)
                  Text(
                    '(${_controller.calculateAge(_selectedBirthDate!)} años)',
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(ColorScheme colorScheme) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _saveProfile,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: _isLoading
            ? SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                'Guardar Cambios',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
