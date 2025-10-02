import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'services/device_management_service.dart';
import 'services/user_role_service.dart';
import 'parent_home_screen.dart';
import 'child_home_screen.dart';

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
  final _ageController = TextEditingController();
  final DeviceManagementService _deviceService = DeviceManagementService();
  final UserRoleService _roleService = UserRoleService();

  File? _profileImage;
  String? _existingPhotoURL;
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
          final data = doc.data() as Map<String, dynamic>?;
          if (data != null) {
            setState(() {
              _nameController.text = data['name'] ?? '';
              _ageController.text = data['age']?.toString() ?? '';
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
    _ageController.dispose();
    super.dispose();
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
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
                    color: Colors.grey[300],
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
                          color: Color(0xFF2D3142),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Color(0xFF9D7FE8).withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Color(0xFF9D7FE8).withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: Color(0xFF9D7FE8)),
            SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: Color(0xFF2D3142),
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
      if (user == null) return null;

      // Crear referencia única para la imagen
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('${user.uid}.jpg');

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
      if (_profileImage != null) {
        profileImageUrl = await _uploadProfileImage();
      } else if (_existingPhotoURL != null) {
        // Mantener la foto existente si no se seleccionó una nueva
        profileImageUrl = _existingPhotoURL;
      }

      // Determinar rol basado en edad (sin considerar parent_child_link aún porque es nuevo usuario)
      final age = int.tryParse(_ageController.text.trim()) ?? 0;
      final role = await _roleService.determineUserRole(user.uid, age);

      // Crear documento de usuario en Firestore
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'name': _nameController.text.trim(),
        'age': age,
        'phone': widget.phoneNumber,
        'phoneVerified': true,
        'photoURL': profileImageUrl,
        'role': role,
        'createdAt': FieldValue.serverTimestamp(),
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
      });

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
          // Navegar a ParentHomeScreen solo si el rol es 'parent'
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => ParentHomeScreen()),
            (route) => false,
          );
        } else {
          // Navegar a ChildHomeScreen para 'child' y 'adult'
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => ChildHomeScreen()),
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.camera_alt,
          size: 40,
          color: Color(0xFF9D7FE8),
        ),
        SizedBox(height: 4),
        Text(
          _isEditMode ? 'Cambiar\nFoto' : 'Agregar\nFoto',
          style: TextStyle(
            color: Color(0xFF9D7FE8),
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
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB), Color(0xFFCE93D8)],
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
                        color: Colors.white.withOpacity(0.2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 20,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.person_add,
                          size: 50,
                          color: Colors.white,
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
                        color: Colors.white,
                      ),
                    ),

                    SizedBox(height: 8),

                    Text(
                      _isEditMode
                          ? 'Modifica tu información si lo deseas'
                          : 'Ayúdanos a personalizar tu experiencia',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white.withOpacity(0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),

                    SizedBox(height: 32),

                    // Form Card
                    Container(
                      padding: EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
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
                                  color: Color(0xFF9D7FE8).withOpacity(0.1),
                                  border: Border.all(
                                    color: Color(0xFF9D7FE8).withOpacity(0.3),
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
                                                    color: Color(0xFF9D7FE8),
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
                                  color: Color(0xFF9D7FE8),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Color(0xFFF5F5F5),
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

                            // Age Field
                            TextFormField(
                              controller: _ageController,
                              decoration: InputDecoration(
                                labelText: 'Edad',
                                prefixIcon: Icon(
                                  Icons.cake_outlined,
                                  color: Color(0xFF9D7FE8),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Color(0xFFF5F5F5),
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Por favor ingresa tu edad';
                                }
                                final age = int.tryParse(value.trim());
                                if (age == null) {
                                  return 'Por favor ingresa una edad válida';
                                }
                                if (age < 5 || age > 100) {
                                  return 'La edad debe estar entre 5 y 100 años';
                                }
                                return null;
                              },
                            ),

                            SizedBox(height: 16),

                            // Phone Number Display (read-only)
                            Container(
                              padding: EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.green.withOpacity(0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
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
                                  backgroundColor: Color(0xFF9D7FE8),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: _isLoading
                                    ? CircularProgressIndicator(
                                        color: Colors.white,
                                      )
                                    : Text(
                                        _isEditMode ? 'Actualizar Perfil' : 'Completar Perfil',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
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

                                          // Edad por defecto: adult (30 años)
                                          const defaultAge = 30;
                                          final role = await _roleService.determineUserRole(user.uid, defaultAge);

                                          await FirebaseFirestore.instance
                                              .collection('users')
                                              .doc(user.uid)
                                              .set({
                                                'name': 'Usuario',
                                                'age': defaultAge,
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
                                                    ParentHomeScreen(),
                                              ),
                                              (route) => false,
                                            );
                                          } else {
                                            Navigator.of(
                                              context,
                                            ).pushAndRemoveUntil(
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ChildHomeScreen(),
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
                                  color: Colors.grey[600],
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
