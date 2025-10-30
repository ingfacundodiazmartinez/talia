import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../../../link_parent_child.dart';
import '../../common/child_settings_screen.dart';
import '../../common/help_support_screen.dart';
import '../../common/privacy_security_screen.dart';
import '../../../screens/my_code_screen.dart';
import '../../parent/profile/edit_profile_screen.dart';
import '../../../controllers/child_profile_controller.dart';
import '../../../services/child_profile_service.dart';
import 'widgets/profile_header_widget.dart';
import 'widgets/link_status_widget.dart';
import 'widgets/activity_stats_widget.dart';
import 'widgets/profile_option_item.dart';
import 'widgets/theme_setting_widget.dart';
import 'widgets/image_picker_dialog.dart';
import 'widgets/permanent_stories_gallery.dart';

class ChildProfileScreen extends StatefulWidget {
  const ChildProfileScreen({super.key});

  @override
  State<ChildProfileScreen> createState() => _ChildProfileScreenState();
}

class _ChildProfileScreenState extends State<ChildProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ChildProfileService _service = ChildProfileService();
  late ChildProfileController _controller;

  @override
  void initState() {
    super.initState();
    final user = _auth.currentUser;
    if (user != null) {
      _controller = ChildProfileController(userId: user.uid);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Usuario no autenticado')),
      );
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: _service.getUserDataStream(user.uid),
      builder: (context, snapshot) {
        final userData = snapshot.data?.data() as Map<String, dynamic>?;
        final photoURL = userData?['photoURL'];
        final role = userData?['role'] ?? 'child';

        return Scaffold(
          appBar: AppBar(
            title: const Text('Mi Perfil'),
            elevation: 0,
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Header de perfil
              ProfileHeaderWidget(
                photoURL: photoURL,
                displayName: _auth.currentUser?.displayName ?? 'Usuario',
                email: _auth.currentUser?.email ?? '',
                onEditPhoto: _showImageOptions,
              ),

              const SizedBox(height: 24),

              // Galería de historias permanentes
              PermanentStoriesGallery(
                userId: user.uid,
                isOwnProfile: true,
              ),

              const SizedBox(height: 24),

              // Estado de vinculación
              LinkStatusWidget(
                userId: user.uid,
                role: role,
              ),

              const SizedBox(height: 24),

              // Estadísticas
              ActivityStatsWidget(userId: user.uid),

              const SizedBox(height: 32),

              // Opciones
              Text(
                'Opciones',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),

              ProfileOptionItem(
                icon: Icons.edit,
                title: 'Editar Perfil',
                subtitle: 'Actualiza tu información personal',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const EditProfileScreen(),
                    ),
                  ).then((_) {
                    if (mounted) {
                      setState(() {});
                    }
                  });
                },
              ),

              // Opción de vincular hijo para usuarios adultos
              StreamBuilder<DocumentSnapshot>(
                stream: _service.getUserDataStream(user.uid),
                builder: (context, snapshot) {
                  if (!snapshot.hasData || !snapshot.data!.exists) {
                    return const SizedBox.shrink();
                  }

                  final userData =
                      snapshot.data!.data() as Map<String, dynamic>?;
                  final role = userData?['role'] ?? 'child';

                  if (role != 'adult') {
                    return const SizedBox.shrink();
                  }

                  return ProfileOptionItem(
                    icon: Icons.family_restroom,
                    title: 'Vincular Hijo',
                    subtitle: 'Genera código para vincular un hijo',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const GenerateLinkCodeScreen(),
                        ),
                      );
                    },
                  );
                },
              ),

              // Opción de vincular padre solo para roles que no sean 'adult'
              StreamBuilder<DocumentSnapshot>(
                stream: _service.getUserDataStream(user.uid),
                builder: (context, snapshot) {
                  bool showLinkOption = true;

                  if (snapshot.hasData && snapshot.data!.exists) {
                    final userData =
                        snapshot.data!.data() as Map<String, dynamic>?;
                    final role = userData?['role'] ?? 'child';

                    if (role == 'adult') {
                      showLinkOption = false;
                    }
                  }

                  if (!showLinkOption) {
                    return const SizedBox.shrink();
                  }

                  return ProfileOptionItem(
                    icon: Icons.link,
                    title: 'Vincular con Padre/Madre',
                    subtitle: 'Ingresa código de vinculación',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const EnterLinkCodeScreen(),
                        ),
                      ).then((linked) {
                        if (linked == true && mounted) {
                          setState(() {});
                        }
                      });
                    },
                  );
                },
              ),

              const ThemeSettingWidget(),

              ProfileOptionItem(
                icon: Icons.settings,
                title: 'Configuración',
                subtitle: 'Personaliza tu experiencia',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const ChildSettingsScreen(),
                    ),
                  );
                },
              ),

              ProfileOptionItem(
                icon: Icons.qr_code,
                title: 'Mi Código',
                subtitle: 'Comparte tu código para agregar contactos',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const MyCodeScreen()),
                  );
                },
              ),

              ProfileOptionItem(
                icon: Icons.security,
                title: 'Privacidad y Seguridad',
                subtitle: 'Gestiona tu privacidad y exporta/importa datos',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const PrivacySecurityScreen(),
                    ),
                  );
                },
              ),

              ProfileOptionItem(
                icon: Icons.help,
                title: 'Ayuda y Soporte',
                subtitle: 'Aprende a usar la app y obtén ayuda',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const HelpSupportScreen(),
                    ),
                  );
                },
              ),

              const SizedBox(height: 16),

              ProfileOptionItem(
                icon: Icons.logout,
                title: 'Cerrar Sesión',
                subtitle: 'Salir de la cuenta',
                onTap: _handleLogout,
                isDestructive: true,
              ),

              const SizedBox(height: 40),
            ],
          ),
        );
      },
    );
  }

  void _showImageOptions() {
    ImagePickerDialog.show(
      context,
      onCamera: () => _pickImage(ImageSource.camera),
      onGallery: () => _pickImage(ImageSource.gallery),
      onDelete: _deleteImage,
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context); // Cerrar bottom sheet

    // Guardar referencia al contexto de la pantalla antes de mostrar cualquier diálogo
    final scaffoldContext = context;

    try {
      // Primero, permitir al usuario seleccionar la imagen
      // El ImageService maneja la selección y LUEGO procesa
      // NO mostrar loading todavía - esperar a que el usuario seleccione

      final String? downloadUrl = await _controller.pickAndUploadImage(
        source,
        scaffoldContext,
      );

      // Si llegamos aquí, la imagen se procesó exitosamente
      // El diálogo de loading se maneja dentro de ImageService

      // Image uploaded successfully
    } catch (e) {
      // Si hay error, mostrar mensaje
      final errorMessage = ChildProfileController.getErrorMessage(e, source);

      if (mounted) {
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _deleteImage() async {
    Navigator.pop(context); // Cerrar bottom sheet

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar foto'),
        content:
            const Text('¿Estás seguro que deseas eliminar tu foto de perfil?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _controller.deleteProfileImage();

        // Image deleted successfully
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al eliminar la foto'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar Sesión'),
        content: const Text('¿Estás seguro que deseas salir?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Salir'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        print('🚪 Cerrando sesión...');
        await _controller.logout();
        print('✅ Sesión cerrada - AuthWrapper detectará el cambio automáticamente');

        // NO hacer navegación manual - AuthWrapper detectará el signOut
        // y mostrará AuthScreen automáticamente
      } catch (e) {
        print('❌ Error cerrando sesión: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al cerrar sesión: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}
