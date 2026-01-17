import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../parent/parent_main_shell.dart';
import '../child/child_main_shell.dart';
import '../../services/profile/profile_completion_service.dart';
import 'profile_completion/widgets/profile_header.dart';
import 'profile_completion/widgets/profile_image_picker.dart';
import 'profile_completion/widgets/profile_form_fields.dart';
import 'profile_completion/widgets/image_picker_modal.dart';
import '../../utils/release_logger.dart';

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
  final ProfileCompletionService _profileService = ProfileCompletionService();

  File? _profileImage;
  String? _existingPhotoURL;
  DateTime? _selectedBirthDate;
  bool _isLoading = false;
  bool _isLoadingData = true; // Nuevo: estado de carga inicial
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
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ReleaseLogger.log('❌ No hay usuario autenticado');
        return;
      }

      ReleaseLogger.log('📋 Cargando datos del usuario: ${user.uid}', tag: 'ProfileCompletionScreen');
      ReleaseLogger.log('   Email: ${_redactEmail(user.email)}', tag: 'ProfileCompletionScreen');
      ReleaseLogger.log('   Phone: ${_redactPhoneNumber(user.phoneNumber)}', tag: 'ProfileCompletionScreen');

      final userData = await _profileService.loadExistingUserData(user.uid);

      if (userData != null && mounted) {
        ReleaseLogger.log('✅ Datos del usuario cargados exitosamente:', tag: 'ProfileCompletionScreen');
        ReleaseLogger.log('   Nombre: ${userData['name']}', tag: 'ProfileCompletionScreen');
        ReleaseLogger.log('   Fecha nacimiento: ${userData['birthDate']}', tag: 'ProfileCompletionScreen');
        ReleaseLogger.log('   Foto: ${userData['photoURL'] != null ? "Sí" : "No"}');

        setState(() {
          _nameController.text = userData['name'] ?? '';
          _selectedBirthDate = userData['birthDate'];
          _existingPhotoURL = userData['photoURL'];
          _isEditMode = true;
        });
      } else {
        ReleaseLogger.log('ℹ️ No hay datos previos del usuario en Firestore (primera vez o documento vacío)', tag: 'ProfileCompletionScreen');
        ReleaseLogger.log('   userData == null: ${userData == null}');
      }
    } catch (e, stackTrace) {
      ReleaseLogger.log('❌ ERROR cargando datos del usuario: $e', tag: 'ProfileCompletionScreen');
      ReleaseLogger.log('   Stack trace: $stackTrace');

      // Mostrar un mensaje al usuario sobre el error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al cargar datos del perfil. Verifica tu conexión.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      // Siempre marcar como cargado, incluso si hubo error
      if (mounted) {
        setState(() {
          _isLoadingData = false;
        });
        ReleaseLogger.log('✅ Pantalla de completar perfil lista para mostrar (isEditMode: $_isEditMode)');
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _nameController.dispose();
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
      ReleaseLogger.log('❌ Error seleccionando imagen: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error seleccionando imagen: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showImagePickerOptions() {
    ImagePickerModal.show(
      context,
      onSourceSelected: _pickImage,
    );
  }

  Future<void> _completeProfile() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedBirthDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Por favor selecciona tu fecha de nacimiento'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      final result = await _profileService.completeProfile(
        userId: user.uid,
        name: _nameController.text.trim(),
        birthDate: _selectedBirthDate!,
        phoneNumber: widget.phoneNumber,
        profileImage: _profileImage,
        existingPhotoURL: _existingPhotoURL,
        isEditMode: _isEditMode,
      );

      if (!result.success) {
        throw Exception(result.error ?? 'Error desconocido');
      }

      if (mounted) {
        _navigateToMainScreen(result.role ?? 'child');
      }
    } catch (e) {
      ReleaseLogger.log('❌ Error completando perfil: $e');

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

  Future<void> _skipProfile() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      final result = await _profileService.completeProfileWithDefaults(
        userId: user.uid,
        phoneNumber: widget.phoneNumber,
        profileImage: _profileImage,
        isEditMode: _isEditMode,
      );

      if (!result.success) {
        throw Exception(result.error ?? 'Error desconocido');
      }

      if (mounted) {
        _navigateToMainScreen(result.role ?? 'child');
      }
    } catch (e) {
      ReleaseLogger.log('❌ Error en skip: $e');
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
        setState(() => _isLoading = false);
      }
    }
  }

  void _navigateToMainScreen(String role) {
    if (role == 'parent') {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => ParentMainShell(key: ParentMainShell.shellKey)),
        (route) => false,
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => ChildMainShell()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Forzar tema claro para la pantalla de completar perfil
    return Theme(
      data: ThemeData.light().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(0xFF9D7FE8),
          brightness: Brightness.light,
        ),
      ),
      child: Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;

          return Scaffold(
            body: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF9D7FE8),
                    Color(0xFFB39DDB),
                    Color(0xFFCE93D8),
                  ],
                ),
              ),
              child: SafeArea(
                child: _isLoadingData
                    ? _buildLoadingView(colorScheme)
                    : FadeTransition(
                        opacity: _fadeAnimation,
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                ProfileHeader(isEditMode: _isEditMode),
                                SizedBox(height: 32),
                                _buildFormCard(colorScheme),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadingView(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(
            color: colorScheme.onPrimary,
            strokeWidth: 3,
          ),
          SizedBox(height: 24),
          Text(
            'Preparando tu perfil...',
            style: TextStyle(
              color: colorScheme.onPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard(ColorScheme colorScheme) {
    return Container(
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
            ProfileImagePicker(
              profileImage: _profileImage,
              existingPhotoURL: _existingPhotoURL,
              onTap: _showImagePickerOptions,
              isEditMode: _isEditMode,
            ),
            SizedBox(height: 24),
            ProfileFormFields(
              nameController: _nameController,
              selectedBirthDate: _selectedBirthDate,
              phoneNumber: widget.phoneNumber,
              onBirthDateSelected: (date) {
                setState(() {
                  _selectedBirthDate = date;
                });
              },
              calculateAge: _profileService.calculateAge,
            ),
            SizedBox(height: 32),
            _buildCompleteButton(colorScheme),
            SizedBox(height: 16),
            _buildSkipButton(colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildCompleteButton(ColorScheme colorScheme) {
    return SizedBox(
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
    );
  }

  Widget _buildSkipButton(ColorScheme colorScheme) {
    return TextButton(
      onPressed: _isLoading ? null : _skipProfile,
      child: Text(
        'Completar después',
        style: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // 🔒 PRIVACY HELPERS - Redact sensitive data for GDPR/COPPA compliance
  String _redactEmail(String? email) {
    if (email == null || email.isEmpty) return 'null';
    final parts = email.split('@');
    if (parts.length != 2) return '***@***';
    final username = parts[0];
    final domain = parts[1];

    // Show first 2 chars + *** + last char @ domain
    if (username.length <= 3) return '***@$domain';
    return '${username.substring(0, 2)}***${username.substring(username.length - 1)}@$domain';
  }

  String _redactPhoneNumber(String? phoneNumber) {
    if (phoneNumber == null || phoneNumber.isEmpty) return 'null';
    if (phoneNumber.length < 6) return '***';

    // Show country code + first 2 digits + *** + last 2 digits
    final first = phoneNumber.substring(0, 3);
    final last = phoneNumber.substring(phoneNumber.length - 2);
    return '$first***$last';
  }
}
