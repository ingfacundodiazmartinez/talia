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
      final userData = await _profileService.loadExistingUserData(user.uid);
      if (userData != null && mounted) {
        setState(() {
          _nameController.text = userData['name'] ?? '';
          _selectedBirthDate = userData['birthDate'];
          _existingPhotoURL = userData['photoURL'];
          _isEditMode = true;
        });
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
      print('❌ Error seleccionando imagen: $e');
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
      print('❌ Error en skip: $e');
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
        MaterialPageRoute(builder: (context) => ParentMainShell()),
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
}
