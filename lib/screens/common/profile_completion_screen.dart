import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../services/device_management_service.dart';
import '../../services/user_role_service.dart';
import '../parent/parent_main_shell.dart';
import '../child/child_main_shell.dart';

class ProfileCompletionScreen extends StatefulWidget {
  final String phoneNumber;

  const ProfileCompletionScreen({
    super.key,
    required this.phoneNumber,
  });

  @override
  State<ProfileCompletionScreen> createState() =>
      _ProfileCompletionScreenState();
}

class _ProfileCompletionScreenState extends State<ProfileCompletionScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final DeviceManagementService _deviceService = DeviceManagementService();
  final UserRoleService _roleService = UserRoleService();

  File? _profileImage;
  String? _existingPhotoURL;
  DateTime? _selectedBirthDate;
  bool _isLoading = false;
  bool _isEditMode = false;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _animationController.forward();
    _loadExistingUserData();
  }

  Future<void> _loadExistingUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();

        if (doc.exists) {
          final data = doc.data();
          if (data != null) {
            setState(() {
              _nameController.text = data['name'] ?? '';
              // Cargar fecha de nacimiento si existe, sino intentar con edad
              if (data['birthDate'] != null) {
                if (data['birthDate'] is Timestamp) {
                  _selectedBirthDate = (data['birthDate'] as Timestamp).toDate();
                } else if (data['birthDate'] is String) {
                  _selectedBirthDate = DateTime.tryParse(data['birthDate']);
                }
              }
              _existingPhotoURL = data['photoURL'];
              _isEditMode = true;
            });
          }
        }
      } catch (e) {
        print('Error loading existing user data: $e');
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // Calcular edad desde fecha de nacimiento
  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final pickedFile = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );

      if (pickedFile != null) {
        setState(() {
          _profileImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      print('❌ Error seleccionando imagen: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error seleccionando imagen: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showImagePickerOptions() {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        'Seleccionar foto de perfil',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildImageOption(
                            icon: Icons.camera_alt,
                            title: 'Cámara',
                            onTap: () {
                              Navigator.pop(context);
                              _pickImage(ImageSource.camera);
                            },
                          ),
                          _buildImageOption(
                            icon: Icons.photo_library,
                            title: 'Galería',
                            onTap: () {
                              Navigator.pop(context);
                              _pickImage(ImageSource.gallery);
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageOption({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: colorScheme.primary),
            SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _uploadProfileImage() async {
    if (_profileImage == null) return null;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ Usuario no autenticado al intentar subir imagen');
        return null;
      }

      // Forzar la recarga del token de autenticación
      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser == null) {
        print('❌ Usuario no disponible después de reload');
        return null;
      }

      // Obtener el ID token para asegurar que Storage tenga acceso
      final idToken = await refreshedUser.getIdToken(true); // true = force refresh
      print('🔑 ID Token obtenido: ${idToken?.substring(0, 20)}...');

      // Dar tiempo para que el SDK de Storage actualice su caché de token
      await Future.delayed(Duration(milliseconds: 500));
      print('⏱️ Esperando propagación del token al SDK de Storage...');

      // Crear referencia única para la imagen
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('${refreshedUser.uid}.jpg');

      print('📁 Subiendo a: profile_images/${refreshedUser.uid}.jpg');

      // Subir la imagen
      final uploadTask = storageRef.putFile(_profileImage!);
      final snapshot = await uploadTask;

      // Obtener la URL de descarga
      final downloadUrl = await snapshot.ref.getDownloadURL();
      print('📸 Imagen subida exitosamente: $downloadUrl');

      return downloadUrl;
    } catch (e) {
      print('❌ Error subiendo imagen: $e');
      return null;
    }
  }

  Future<void> _completeProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      // Verificar si el número de teléfono ya existe en otro usuario
      if (!_isEditMode) {
        final existingUsers = await FirebaseFirestore.instance
            .collection('users')
            .where('phone', isEqualTo: widget.phoneNumber)
            .get();

        if (existingUsers.docs.isNotEmpty) {
          // Verificar si alguno de los documentos NO es el usuario actual
          final isDuplicate = existingUsers.docs.any((doc) => doc.id != user.uid);

          if (isDuplicate) {
            throw Exception('Este número de teléfono ya está registrado en otra cuenta');
          }
        }
      }

      // Actualizar nombre de usuario en Firebase Auth
      await user.updateDisplayName(_nameController.text.trim());

      // Subir imagen de perfil a Firebase Storage
      String? profileImageUrl;
      print('🖼️ _profileImage: ${_profileImage?.path ?? "null"}');
      if (_profileImage != null) {
        print('📤 Iniciando subida de imagen...');
        profileImageUrl = await _uploadProfileImage();
        print('📸 URL de imagen obtenida: $profileImageUrl');
      } else {
        print('⚠️ No hay imagen seleccionada');
        if (_existingPhotoURL != null) {
          // Mantener la foto existente si no se seleccionó una nueva
          profileImageUrl = _existingPhotoURL;
          print('🔄 Usando foto existente: $profileImageUrl');
        }
      }

      // Validar que haya fecha de nacimiento
      if (_selectedBirthDate == null) {
        throw Exception('Por favor selecciona tu fecha de nacimiento');
      }

      // Calcular edad desde fecha de nacimiento
      final age = _calculateAge(_selectedBirthDate!);
      final role = await _roleService.determineUserRole(user.uid, age);

      // Verificar si el usuario ya existe para decidir entre crear o actualizar
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (userDoc.exists && userDoc.data()?['createdAt'] != null) {
        // Usuario ya existe, actualizar solo campos modificables
        await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
          'name': _nameController.text.trim(),
          'birthDate': Timestamp.fromDate(_selectedBirthDate!),
          'photoURL': profileImageUrl,
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
        });
      } else {
        // Usuario nuevo, crear documento completo
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'name': _nameController.text.trim(),
          'birthDate': Timestamp.fromDate(_selectedBirthDate!),
          'phone': widget.phoneNumber,
          'phoneVerified': true,
          'photoURL': profileImageUrl,
          'role': role,
          'createdAt': FieldValue.serverTimestamp(),
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
        });
      }

      // Registrar dispositivo para el nuevo usuario
      await _registerUserDevice(user.uid);

      print('✅ Perfil completado exitosamente con rol: $role');

      // Mostrar mensaje de éxito
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Perfil completado exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      }

      // Navegación directa a la pantalla principal correspondiente
      if (mounted) {
        if (role == 'parent') {
          // Navegar a ParentMainShell solo si el rol es 'parent'
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => ParentMainShell()),
            (route) => false,
          );
        } else {
          // Navegar a ChildMainShell para 'child' y 'adult'
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => ChildMainShell()),
            (route) => false,
          );
        }
      }
    } catch (e) {
      print('❌ Error completando perfil: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completando perfil: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // Registrar dispositivo para nuevo usuario
  Future<void> _registerUserDevice(String userId) async {
    try {
      final result = await _deviceService.registerDeviceForUser(userId);

      if (!result.isSuccess) {
        print('⚠️ Advertencia registrando dispositivo: ${result.error}');
        // No bloquear el flujo por errores de dispositivo
      }
    } catch (e) {
      print('❌ Error registrando dispositivo: $e');
      // No bloquear el flujo por errores de dispositivo
    }
  }

  Widget _buildDefaultPhotoPlaceholder() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.camera_alt,
          size: 40,
          color: colorScheme.primary,
        ),
        SizedBox(height: 4),
        Text(
          _isEditMode ? 'Cambiar\nFoto' : 'Agregar\nFoto',
          style: TextStyle(
            color: colorScheme.primary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDarkMode
                ? [
                    colorScheme.primary.withValues(alpha: 0.3),
                    colorScheme.primary.withValues(alpha: 0.2),
                    colorScheme.secondary.withValues(alpha: 0.2),
                  ]
                : [
                    Color(0xFF9D7FE8),
                    Color(0xFFB39DDB),
                    Color(0xFFCE93D8),
                  ],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Icon
                    Container(
                      height: 100,
                      width: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isDarkMode
                            ? colorScheme.surfaceVariant.withValues(alpha: 0.3)
                            : Colors.white.withValues(alpha: 0.2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 20,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.person_add,
                          size: 50,
                          color: isDarkMode
                              ? colorScheme.onSurface
                              : Colors.white,
                        ),
                      ),
                    ),

                    SizedBox(height: 24),

                    // Title
                    Text(
                      _isEditMode ? 'Actualizar Perfil' : 'Completar Perfil',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: isDarkMode
                            ? colorScheme.onSurface
                            : Colors.white,
                      ),
                    ),

                    SizedBox(height: 8),

                    Text(
                      _isEditMode
                          ? 'Modifica tu información si lo deseas'
                          : 'Ayúdanos a personalizar tu experiencia',
                      style: TextStyle(
                        fontSize: 16,
                        color: isDarkMode
                            ? colorScheme.onSurface.withValues(alpha: 0.9)
                            : Colors.white.withValues(alpha: 0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),

                    SizedBox(height: 32),

                    // Form Card
                    Container(
                      padding: EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 30,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            // Profile Image Section
                            GestureDetector(
                              onTap: _showImagePickerOptions,
                              child: Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colorScheme.primaryContainer,
                                  border: Border.all(
                                    color: colorScheme.primary.withValues(alpha: 0.3),
                                    width: 2,
                                  ),
                                ),
                                child: _profileImage != null
                                    ? ClipOval(
                                        child: Image.file(
                                          _profileImage!,
                                          width: 120,
                                          height: 120,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : _existingPhotoURL != null
                                        ? ClipOval(
                                            child: Image.network(
                                              _existingPhotoURL!,
                                              width: 120,
                                              height: 120,
                                              fit: BoxFit.cover,
                                              loadingBuilder: (context, child, loadingProgress) {
                                                if (loadingProgress == null) return child;
                                                return Center(
                                                  child: CircularProgressIndicator(
                                                    color: colorScheme.primary,
                                                  ),
                                                );
                                              },
                                              errorBuilder: (context, error, stackTrace) {
                                                return _buildDefaultPhotoPlaceholder();
                                              },
                                            ),
                                          )
                                        : _buildDefaultPhotoPlaceholder(),
                              ),
                            ),

                            SizedBox(height: 24),

                            // Name Field
                            TextFormField(
                              controller: _nameController,
                              decoration: InputDecoration(
                                labelText: 'Nombre',
                                prefixIcon: Icon(
                                  Icons.person_outline,
                                  color: colorScheme.primary,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: colorScheme.surfaceVariant,
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Por favor ingresa tu nombre';
                                }
                                if (value.trim().length < 2) {
                                  return 'El nombre debe tener al menos 2 caracteres';
                                }
                                return null;
                              },
                            ),

                            SizedBox(height: 16),

                            // Birth Date Field
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
                                  color: colorScheme.surfaceVariant,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.cake_outlined,
                                      color: colorScheme.primary,
                                    ),
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        _selectedBirthDate == null
                                            ? 'Fecha de nacimiento'
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
                                        '(${_calculateAge(_selectedBirthDate!)} años)',
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

                            SizedBox(height: 16),

                            // Phone Number Display (read-only)
                            Container(
                              padding: EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.green.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.check_circle,
                                    color: Colors.green[700],
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Teléfono verificado: ${widget.phoneNumber}',
                                      style: TextStyle(
                                        color: Colors.green[700],
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            SizedBox(height: 32),

                            // Complete Profile Button
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _completeProfile,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: colorScheme.primary,
                                  foregroundColor: colorScheme.onPrimary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: _isLoading
                                    ? CircularProgressIndicator(
                                        color: colorScheme.onPrimary,
                                      )
                                    : Text(
                                        _isEditMode ? 'Actualizar Perfil' : 'Completar Perfil',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              ),
                            ),

                            SizedBox(height: 16),

                            // Skip Button
                            TextButton(
                              onPressed: _isLoading
                                  ? null
                                  : () async {
                                      // Completar perfil con datos mínimos
                                      setState(() => _isLoading = true);
                                      try {
                                        final user =
                                            FirebaseAuth.instance.currentUser;
                                        if (user != null) {
                                          // Verificar si el usuario ya tiene un perfil completo
                                          final userDoc = await FirebaseFirestore.instance
                                              .collection('users')
                                              .doc(user.uid)
                                              .get();

                                          // Si el usuario ya existe con datos completos, solo navegar
                                          if (userDoc.exists && userDoc.data()?['name'] != null && userDoc.data()?['createdAt'] != null) {
                                            final role = userDoc.data()?['role'] ?? 'child';

                                            await _registerUserDevice(user.uid);

                                            // Navegación según rol
                                            if (role == 'parent') {
                                              Navigator.of(context).pushAndRemoveUntil(
                                                MaterialPageRoute(
                                                  builder: (context) => ParentMainShell(),
                                                ),
                                                (route) => false,
                                              );
                                            } else {
                                              Navigator.of(context).pushAndRemoveUntil(
                                                MaterialPageRoute(
                                                  builder: (context) => ChildMainShell(),
                                                ),
                                                (route) => false,
                                              );
                                            }
                                            return;
                                          }

                                          // Verificar si el número de teléfono ya existe en otro usuario
                                          if (!_isEditMode) {
                                            final existingUsers = await FirebaseFirestore.instance
                                                .collection('users')
                                                .where('phone', isEqualTo: widget.phoneNumber)
                                                .get();

                                            if (existingUsers.docs.isNotEmpty) {
                                              final isDuplicate = existingUsers.docs.any((doc) => doc.id != user.uid);

                                              if (isDuplicate) {
                                                throw Exception('Este número de teléfono ya está registrado en otra cuenta');
                                              }
                                            }
                                          }

                                          // Subir imagen si existe
                                          String? profileImageUrl;
                                          if (_profileImage != null) {
                                            profileImageUrl =
                                                await _uploadProfileImage();
                                          }

                                          // Fecha de nacimiento por defecto: 30 años atrás
                                          final defaultBirthDate = DateTime.now().subtract(Duration(days: 30 * 365));
                                          const defaultAge = 30;
                                          final role = await _roleService.determineUserRole(user.uid, defaultAge);

                                          await FirebaseFirestore.instance
                                              .collection('users')
                                              .doc(user.uid)
                                              .set({
                                                'name': 'Usuario',
                                                'birthDate': Timestamp.fromDate(defaultBirthDate),
                                                'phone': widget.phoneNumber,
                                                'phoneVerified': true,
                                                'photoURL': profileImageUrl,
                                                'role': role,
                                                'createdAt':
                                                    FieldValue.serverTimestamp(),
                                                'isOnline': true,
                                                'lastSeen':
                                                    FieldValue.serverTimestamp(),
                                              });

                                          await _registerUserDevice(user.uid);

                                          // Navegación después del skip
                                          if (role == 'parent') {
                                            Navigator.of(
                                              context,
                                            ).pushAndRemoveUntil(
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ParentMainShell(),
                                              ),
                                              (route) => false,
                                            );
                                          } else {
                                            Navigator.of(
                                              context,
                                            ).pushAndRemoveUntil(
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ChildMainShell(),
                                              ),
                                              (route) => false,
                                            );
                                          }
                                        }
                                      } catch (e) {
                                        print('❌ Error en skip: $e');
                                      } finally {
                                        if (mounted) {
                                          setState(() => _isLoading = false);
                                        }
                                      }
                                    },
                              child: Text(
                                'Completar después',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
