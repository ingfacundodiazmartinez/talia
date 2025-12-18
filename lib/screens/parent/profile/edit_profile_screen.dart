import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../controllers/edit_profile_controller.dart';
import '../../../services/image_service.dart';
import '../../../utils/release_logger.dart';

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
    _controller = EditProfileController();
    _nameController = TextEditingController();
    _phoneController = TextEditingController();

    _initializeController();
  }

  Future<void> _initializeController() async {
    await _controller.initialize();
    if (_controller.isUserAuthenticated) {
      _nameController.text = _controller.currentUserDisplayName ?? '';
      _loadUserData();
    }
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
            DateTime? parsedDate;

            if (userData['birthDate'] is Timestamp) {
              parsedDate = (userData['birthDate'] as Timestamp).toDate();
            } else if (userData['birthDate'] is String) {
              parsedDate = DateTime.tryParse(userData['birthDate']);
            }

            // Normalizar a fecha local sin hora para mostrar correctamente
            if (parsedDate != null) {
              _selectedBirthDate = DateTime(
                parsedDate.year,
                parsedDate.month,
                parsedDate.day,
              );
            }
          }

          _profileImageUrl = userData['photoURL'] ?? _controller.currentUserPhotoURL;
        });
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar('Error al cargar datos: ${EditProfileController.getErrorMessage(e)}');
      }
    }
  }

  Future<void> _changeProfilePhoto() async {
    ReleaseLogger.log('Iniciando cambio de foto de perfil...', tag: 'EditProfile');

    try {
      setState(() => _isUploadingImage = true);
      ReleaseLogger.log('Loading state activado', tag: 'EditProfile');

      // Mostrar selector de fuente de imagen
      ReleaseLogger.log('Mostrando selector de fuente...', tag: 'EditProfile');
      final ImageSource? source = await _imageService.showImageSourceSelection(
        context,
      );
      ReleaseLogger.log('Selector cerrado. Source seleccionado: $source', tag: 'EditProfile');

      if (source == null) {
        ReleaseLogger.log('Usuario canceló la selección', tag: 'EditProfile');
        setState(() => _isUploadingImage = false);
        return;
      }

      ReleaseLogger.log('Iniciando selección y subida de imagen desde ${source == ImageSource.camera ? 'cámara' : 'galería'}...', tag: 'EditProfile');

      // Seleccionar imagen
      final String? imageUrl = await _imageService.pickAndUploadProfileImage(
        source: source,
        context: context,
      );

      ReleaseLogger.log('Resultado de pickAndUploadProfileImage: ${imageUrl != null ? 'URL obtenida' : 'null'}', tag: 'EditProfile');

      // Si la imagen fue subida exitosamente, actualizar en Firestore via controller
      if (imageUrl != null && mounted) {
        ReleaseLogger.log('Actualizando foto de perfil en Firestore...', tag: 'EditProfile');
        await _controller.uploadProfilePhoto(imageUrl);
        setState(() {
          _profileImageUrl = imageUrl;
        });
        ReleaseLogger.log('Foto de perfil actualizada exitosamente', tag: 'EditProfile');
      } else {
        ReleaseLogger.log('No se obtuvo URL de imagen', tag: 'EditProfile');
      }
    } catch (e) {
      ReleaseLogger.error('Error al cambiar foto: $e', tag: 'EditProfile');
      if (mounted) {
        _showErrorSnackBar('Error al cambiar foto: ${EditProfileController.getErrorMessage(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _isUploadingImage = false);
        ReleaseLogger.log('Loading state desactivado', tag: 'EditProfile');
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
            child: _profileImageUrl != null && _profileImageUrl!.isNotEmpty
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: _profileImageUrl!,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Icon(
                        Icons.person,
                        size: 60,
                        color: colorScheme.primary,
                      ),
                      errorWidget: (context, url, error) => Icon(
                        Icons.person,
                        size: 60,
                        color: colorScheme.primary,
                      ),
                    ),
                  )
                : Icon(
                    Icons.person,
                    size: 60,
                    color: colorScheme.primary,
                  ),
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
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  ReleaseLogger.log('Botón de cámara tocado', tag: 'EditProfile');
                  ReleaseLogger.log('_isUploadingImage: $_isUploadingImage', tag: 'EditProfile');
                  if (!_isUploadingImage) {
                    _changeProfilePhoto();
                  } else {
                    ReleaseLogger.log('Bloqueado porque _isUploadingImage es true', tag: 'EditProfile');
                  }
                },
                customBorder: CircleBorder(),
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
          textCapitalization: TextCapitalization.words,
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
