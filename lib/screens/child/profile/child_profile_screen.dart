import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../../../link_parent_child.dart';
import '../../common/child_settings_screen.dart';
import '../../common/help_support_screen.dart';
import '../../common/privacy_security_screen.dart';
import '../../premium/premium_screen.dart';
import '../../../screens/my_code_screen.dart';
import '../../parent/profile/edit_profile_screen.dart';
import '../../../controllers/child_profile_controller.dart';
import '../../../services/child_profile_service.dart';
import '../../../services/subscription_service.dart';
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

              // Botón Premium - Para 'adult' o info para 'child'
              StreamBuilder<DocumentSnapshot>(
                stream: _service.getUserDataStream(user.uid),
                builder: (context, snapshot) {
                  if (!snapshot.hasData || !snapshot.data!.exists) {
                    return const SizedBox.shrink();
                  }

                  final userData =
                      snapshot.data!.data() as Map<String, dynamic>?;
                  final role = userData?['role'] ?? 'child';

                  // Si es adult, mostrar botón premium completo
                  if (role == 'adult') {
                    return _buildPremiumCard();
                  }

                  // Si es child, mostrar info sobre premium
                  return _buildPremiumInfoCard();
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

  Widget _buildPremiumCard() {
    final subscriptionService = SubscriptionService();

    return StreamBuilder<PremiumStatus>(
      stream: subscriptionService.premiumStatusStream(),
      builder: (context, snapshot) {
        final status = snapshot.data ?? PremiumStatus.free();
        final isPremium = status.isPremium;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isPremium
                  ? [const Color(0xFF6A1B9A), const Color(0xFF8E24AA)]
                  : [const Color(0xFF6A1B9A).withOpacity(0.8), const Color(0xFF8E24AA).withOpacity(0.8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6A1B9A).withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const PremiumScreen(),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPremium ? Icons.workspace_premium : Icons.star,
                        color: isPremium ? Colors.amber : Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isPremium ? 'Talia ${status.tier.displayName}' : 'Obtén Talia Premium',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isPremium
                                ? 'Gestiona tu suscripción'
                                : '7 días GRATIS - Filtros HD y efectos especiales',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.white,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPremiumInfoCard() {
    final subscriptionService = SubscriptionService();

    return StreamBuilder<PremiumStatus>(
      stream: subscriptionService.premiumStatusStream(),
      builder: (context, snapshot) {
        final status = snapshot.data ?? PremiumStatus.free();
        final isPremium = status.isPremium;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isPremium
                  ? [const Color(0xFF6A1B9A).withOpacity(0.5), const Color(0xFF8E24AA).withOpacity(0.5)]
                  : [Colors.grey.shade300, Colors.grey.shade200],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPremium ? const Color(0xFF6A1B9A) : Colors.grey.shade400,
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isPremium
                        ? Colors.white.withOpacity(0.3)
                        : Colors.grey.shade400,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPremium ? Icons.workspace_premium : Icons.family_restroom,
                    color: isPremium ? Colors.amber : Colors.grey.shade700,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPremium
                            ? 'Talia ${status.tier.displayName}'
                            : 'Funciones Premium',
                        style: TextStyle(
                          color: isPremium ? Colors.white : Colors.grey.shade800,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isPremium
                            ? 'Premium activo gracias a tu familia'
                            : 'Solo un padre vinculado puede darte acceso a funciones premium',
                        style: TextStyle(
                          color: isPremium
                              ? Colors.white.withOpacity(0.9)
                              : Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isPremium)
                  const Icon(
                    Icons.check_circle,
                    color: Colors.green,
                    size: 24,
                  )
                else
                  Icon(
                    Icons.info_outline,
                    color: Colors.grey.shade600,
                    size: 24,
                  ),
              ],
            ),
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
