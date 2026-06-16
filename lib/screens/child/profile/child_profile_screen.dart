import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import '../../../utils/release_logger.dart';
import '../../../link_parent_child.dart';
import '../../../theme_service.dart';
import '../../common/child_settings_screen.dart';
import '../../common/help_support_screen.dart';
import '../../common/privacy_security_screen.dart';
import '../../historias/mi_circulo_screen.dart';
import '../../historias/mis_historias_screen.dart';
import '../../../models/contact.dart';
import '../../../screens/my_code_screen.dart';
import '../../parent/profile/edit_profile_screen.dart';
import '../../../controllers/child_profile_controller.dart';
import '../../../services/child_profile_service.dart';
import '../../../services/image_service.dart';
import 'widgets/profile_header_widget.dart';
import 'widgets/link_status_widget.dart';
import 'widgets/premium_status_widget.dart';
import 'widgets/profile_option_item.dart';

class ChildProfileScreen extends StatefulWidget {
  const ChildProfileScreen({super.key});

  @override
  State<ChildProfileScreen> createState() => _ChildProfileScreenState();
}

class _ChildProfileScreenState extends State<ChildProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ChildProfileService _service = ChildProfileService();
  final ImageService _imageService = ImageService();
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

              // Estado de vinculación
              LinkStatusWidget(
                userId: user.uid,
                role: role,
              ),

              const SizedBox(height: 16),

              // Estado premium (solo para children)
              if (role == 'child')
                StreamBuilder<QuerySnapshot>(
                  stream: _service.getParentChildLinksStream(user.uid),
                  builder: (context, linksSnapshot) {
                    final hasLinkedParent = linksSnapshot.hasData &&
                        linksSnapshot.data!.docs.isNotEmpty;
                    return PremiumStatusWidget(
                      userId: user.uid,
                      hasLinkedParent: hasLinkedParent,
                    );
                  },
                ),

              const SizedBox(height: 16),

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

              // Opción de solicitar independencia para children de 18+ años con padres vinculados
              _buildRequestIndependenceOption(user.uid),

              // ✅ NUEVO: Mis historias subidas
              ProfileOptionItem(
                icon: Icons.auto_stories,
                title: 'Mis historias',
                subtitle: 'Ve las historias que publicaste',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const MisHistoriasScreen(),
                    ),
                  );
                },
              ),

              // ✅ NUEVO: Mi círculo (con badge de invitaciones pendientes)
              StreamBuilder<List<Contact>>(
                stream: Contact.watchPendingFriendRequests(user.uid),
                builder: (context, snapshot) {
                  final pending = snapshot.data?.length ?? 0;
                  return ProfileOptionItem(
                    icon: Icons.favorite,
                    title: 'Mi círculo',
                    subtitle: pending > 0
                        ? '$pending ${pending == 1 ? "invitación pendiente" : "invitaciones pendientes"}'
                        : 'Personas que comparten historias con vos',
                    badge: pending > 0 ? pending : null,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const MiCirculoScreen(),
                        ),
                      );
                    },
                  );
                },
              ),

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

              _buildDarkModeSetting(),

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

  /// Muestra opciones de imagen usando el flujo de ImageService
  /// (Mismo enfoque que EditProfileScreen - funciona en iOS)
  Future<void> _showImageOptions() async {
    ReleaseLogger.log('Iniciando cambio de foto de perfil...', tag: 'ChildProfile');

    try {
      // Mostrar selector de fuente de imagen (maneja el bottom sheet internamente)
      final source = await _imageService.showImageSourceSelection(context);
      ReleaseLogger.log('Selector cerrado. Source seleccionado: $source', tag: 'ChildProfile');

      if (source == null) {
        ReleaseLogger.log('Usuario canceló la selección', tag: 'ChildProfile');
        return;
      }

      ReleaseLogger.log('Iniciando selección y subida de imagen...', tag: 'ChildProfile');

      // Seleccionar imagen (pickAndUploadProfileImage maneja el loading dialog internamente)
      // ignore: use_build_context_synchronously
      final String? imageUrl = await _controller.pickAndUploadImage(source, context);

      ReleaseLogger.log('Resultado: ${imageUrl != null ? 'URL obtenida' : 'null'}', tag: 'ChildProfile');

      if (imageUrl != null && mounted) {
        ReleaseLogger.log('Foto de perfil actualizada exitosamente', tag: 'ChildProfile');
      }
    } catch (e) {
      ReleaseLogger.error('Error al cambiar foto: $e', tag: 'ChildProfile');
      if (mounted) {
        final errorMsg = e.toString().replaceAll('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
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
        await _controller.logout();

        // NO hacer navegación manual - AuthWrapper detectará el signOut
        // y mostrará AuthScreen automáticamente
      } catch (e) {
        ReleaseLogger.error('Error cerrando sesión: $e', tag: 'ChildProfileScreen');
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

  Widget _buildDarkModeSetting() {
    final colorScheme = Theme.of(context).colorScheme;
    final themeService = context.watch<ThemeService>();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            themeService.isDarkMode ? Icons.dark_mode : Icons.light_mode,
            color: colorScheme.primary,
          ),
        ),
        title: Text(
          'Modo oscuro',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          themeService.isDarkMode
              ? 'Tema oscuro activado'
              : 'Tema claro activado',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Switch(
          value: themeService.isDarkMode,
          onChanged: (enabled) => themeService.toggleDarkMode(enabled),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        tileColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      ),
    );
  }

  /// Widget para solicitar independencia (solo para children 18+ con padres vinculados)
  Widget _buildRequestIndependenceOption(String userId) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _service.getUserDataStream(userId),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
        final role = userData?['role'] ?? 'child';
        final birthDate = userData?['birthDate'];

        // Solo mostrar para children
        if (role != 'child') {
          return const SizedBox.shrink();
        }

        // Calcular edad
        final age = _calculateAge(birthDate);
        if (age < 18) {
          return const SizedBox.shrink();
        }

        // Verificar si tiene padres vinculados
        return StreamBuilder<QuerySnapshot>(
          stream: _service.getAllParentChildLinksStream(userId),
          builder: (context, linksSnapshot) {
            if (!linksSnapshot.hasData || linksSnapshot.data!.docs.isEmpty) {
              return const SizedBox.shrink();
            }

            // Tiene 18+ años y padres vinculados - mostrar opción
            return ProfileOptionItem(
              icon: Icons.person_off,
              title: 'Solicitar Independencia',
              subtitle: 'Pide a tus padres que te desvinculen',
              onTap: () => _showRequestIndependenceDialog(),
            );
          },
        );
      },
    );
  }

  /// Calcular edad a partir de la fecha de nacimiento
  int _calculateAge(dynamic birthDate) {
    if (birthDate == null) return 0;

    DateTime birth;
    if (birthDate is Timestamp) {
      birth = birthDate.toDate();
    } else if (birthDate is String) {
      try {
        birth = DateTime.parse(birthDate);
      } catch (e) {
        return 0;
      }
    } else {
      return 0;
    }

    final now = DateTime.now();
    int age = now.year - birth.year;
    if (now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day)) {
      age--;
    }
    return age;
  }

  /// Mostrar diálogo de confirmación para solicitar independencia
  Future<void> _showRequestIndependenceDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.person_off, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Solicitar Independencia'),
            ),
          ],
        ),
        content: const Text(
          'Al tener 18 años, puedes solicitar que tus padres te desvinculen de su supervisión.\n\n'
          'Se enviará una notificación a tus padres para que decidan si desvincularte. '
          'Ellos deberán aprobar esta solicitud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Solicitar'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    await _requestUnlink();
  }

  /// Llamar a la Cloud Function para solicitar desvinculación
  Future<void> _requestUnlink() async {
    try {
      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('requestUnlink').call();

      // Cerrar loading
      if (mounted) {
        Navigator.pop(context);
      }

      final resultData = result.data as Map<String, dynamic>;
      final success = resultData['success'] ?? false;
      final message = resultData['message'] ?? '';

      if (!mounted) return;

      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message.isNotEmpty ? message : 'No se pudo enviar la solicitud'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error solicitando independencia: $e', tag: 'ChildProfile');

      // Cerrar loading si está abierto
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al enviar la solicitud'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
