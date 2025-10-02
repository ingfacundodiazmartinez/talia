import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'link_parent_child.dart';
import 'child_settings_screen.dart';
import 'screens/my_code_screen.dart';
import 'services/image_service.dart';
import 'edit_profile_screen.dart';

class ChildProfileScreen extends StatefulWidget {
  const ChildProfileScreen({super.key});

  @override
  State<ChildProfileScreen> createState() => _ChildProfileScreenState();
}

class _ChildProfileScreenState extends State<ChildProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImageService _imageService = ImageService();

  String? _currentPhotoURL;

  @override
  void initState() {
    super.initState();
    _currentPhotoURL = _auth.currentUser?.photoURL;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mi Perfil'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Header de perfil
          Center(
            child: Column(
              children: [
                Stack(
                  children: [
                    Container(
                      padding: EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
                        ),
                      ),
                      child: CircleAvatar(
                        radius: 56,
                        backgroundColor: Colors.white,
                        child: CircleAvatar(
                          radius: 52,
                          backgroundColor: Color(0xFF9D7FE8),
                          backgroundImage: _currentPhotoURL != null
                              ? NetworkImage(_currentPhotoURL!)
                              : null,
                          child: _currentPhotoURL == null
                              ? Icon(
                                  Icons.person,
                                  size: 50,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: _showImageOptions,
                        child: Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Color(0xFF9D7FE8),
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.edit,
                            size: 16,
                            color: Color(0xFF9D7FE8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                Text(
                  _auth.currentUser?.displayName ?? 'Usuario',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  _auth.currentUser?.email ?? '',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.green.withOpacity(0.2),
                        Colors.green.withOpacity(0.1),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.green, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.shield, size: 16, color: Colors.green),
                      SizedBox(width: 6),
                      Text(
                        'Cuenta Protegida',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 32),

          // Estado de vinculación (solo para roles child)
          _auth.currentUser != null
              ? StreamBuilder<DocumentSnapshot>(
                  stream: _firestore
                      .collection('users')
                      .doc(_auth.currentUser!.uid)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || !snapshot.data!.exists) {
                      return SizedBox.shrink();
                    }

                    final userData =
                        snapshot.data!.data() as Map<String, dynamic>?;
                    final role = userData?['role'] ?? 'child';

                    // No mostrar estado de vinculación para usuarios adultos
                    if (role == 'adult') {
                      return SizedBox.shrink();
                    }

                    // Consultar parent_child_links para usuarios child
                    return StreamBuilder<QuerySnapshot>(
                      stream: _firestore
                          .collection('parent_child_links')
                          .where('childId', isEqualTo: _auth.currentUser!.uid)
                          .where('status', isEqualTo: 'approved')
                          .snapshots(),
                      builder: (context, linksSnapshot) {
                        if (linksSnapshot.connectionState == ConnectionState.waiting) {
                          return Center(child: CircularProgressIndicator());
                        }

                        final links = linksSnapshot.data?.docs ?? [];
                        final isLinked = links.isNotEmpty;

                        if (!isLinked) {
                          return Container(
                            padding: EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.orange.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.link_off,
                                    color: Colors.orange,
                                    size: 28,
                                  ),
                                ),
                                SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'No vinculado',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF2D3142),
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        'Pide a tus padres que te vinculen',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_forward_ios,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                              ],
                            ),
                          );
                        }

                        // Si está vinculado, mostrar todos los padres
                        return Column(
                          children: [
                            for (var link in links)
                              FutureBuilder<DocumentSnapshot>(
                                future: _firestore
                                    .collection('users')
                                    .doc(link['parentId'])
                                    .get(),
                                builder: (context, parentSnapshot) {
                                  String parentName = 'Cargando...';

                                  if (parentSnapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    parentName = 'Cargando...';
                                  } else if (parentSnapshot.hasError) {
                                    parentName = 'Error al cargar';
                                  } else if (parentSnapshot.hasData &&
                                      parentSnapshot.data!.exists) {
                                    final parentData =
                                        parentSnapshot.data!.data()
                                            as Map<String, dynamic>?;
                                    parentName =
                                        parentData?['name'] ??
                                        parentData?['displayName'] ??
                                        'Padre/Madre';
                                  } else {
                                    parentName = 'Padre/Madre no encontrado';
                                  }

                                  return Container(
                                    margin: EdgeInsets.only(bottom: 12),
                                    padding: EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: Colors.green.withOpacity(0.3),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Icon(
                                            Icons.link,
                                            color: Colors.green,
                                            size: 28,
                                          ),
                                        ),
                                        SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Vinculado con $parentName',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF2D3142),
                                                ),
                                              ),
                                              SizedBox(height: 4),
                                              Text(
                                                'Tu padre/madre supervisa tu cuenta',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey[600],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                          ],
                        );
                      },
                    );
                  },
                )
              : SizedBox.shrink(),

          SizedBox(height: 24),

          // Estadísticas
          Text(
            'Mi Actividad',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  icon: Icons.chat_bubble,
                  title: 'Chats',
                  value: '5',
                  color: Color(0xFF9D7FE8),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  icon: Icons.people,
                  title: 'Contactos',
                  value: '8',
                  color: Color(0xFF4CAF50),
                ),
              ),
            ],
          ),

          SizedBox(height: 32),

          // Opciones
          Text(
            'Opciones',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 12),

          _buildProfileOption(
            icon: Icons.edit,
            title: 'Editar Perfil',
            subtitle: 'Actualiza tu información personal',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => EditProfileScreen()),
              ).then((_) {
                if (mounted) {
                  setState(() {});
                }
              });
            },
          ),

          // Opción de vincular hijo para usuarios adultos
          StreamBuilder<DocumentSnapshot>(
            stream: _firestore
                .collection('users')
                .doc(_auth.currentUser?.uid)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || !snapshot.data!.exists) {
                return SizedBox.shrink();
              }

              final userData = snapshot.data!.data() as Map<String, dynamic>?;
              final role = userData?['role'] ?? 'child';

              // Mostrar opción de vincular hijo solo para adultos
              if (role != 'adult') {
                return SizedBox.shrink();
              }

              return _buildProfileOption(
                icon: Icons.family_restroom,
                title: 'Vincular Hijo',
                subtitle: 'Genera código para vincular un hijo',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => GenerateLinkCodeScreen(),
                    ),
                  );
                },
              );
            },
          ),

          // Opción de vincular padre solo para roles que no sean 'adult'
          StreamBuilder<DocumentSnapshot>(
            stream: _firestore
                .collection('users')
                .doc(_auth.currentUser?.uid)
                .snapshots(),
            builder: (context, snapshot) {
              // Por defecto mostrar la opción (para child)
              bool showLinkOption = true;

              if (snapshot.hasData && snapshot.data!.exists) {
                final userData = snapshot.data!.data() as Map<String, dynamic>?;
                final role = userData?['role'] ?? 'child';

                // Ocultar para usuarios con rol 'adult'
                if (role == 'adult') {
                  showLinkOption = false;
                }
              }

              if (!showLinkOption) {
                return SizedBox.shrink(); // No mostrar nada
              }

              return _buildProfileOption(
                icon: Icons.link,
                title: 'Vincular con Padre/Madre',
                subtitle: 'Ingresa código de vinculación',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => EnterLinkCodeScreen()),
                  ).then((linked) {
                    if (linked == true && mounted) {
                      setState(() {});
                    }
                  });
                },
              );
            },
          ),

          _buildProfileOption(
            icon: Icons.settings,
            title: 'Configuración',
            subtitle: 'Personaliza tu experiencia',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => ChildSettingsScreen()),
              );
            },
          ),

          _buildProfileOption(
            icon: Icons.qr_code,
            title: 'Mi Código',
            subtitle: 'Comparte tu código para agregar contactos',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => MyCodeScreen()),
              );
            },
          ),

          _buildProfileOption(
            icon: Icons.emoji_emotions,
            title: 'Emojis Favoritos',
            subtitle: 'Personaliza tu chat',
            onTap: () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Función próximamente')));
            },
          ),

          _buildProfileOption(
            icon: Icons.help,
            title: 'Ayuda',
            subtitle: 'Aprende a usar la app',
            onTap: () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Función próximamente')));
            },
          ),

          SizedBox(height: 16),

          _buildProfileOption(
            icon: Icons.logout,
            title: 'Cerrar Sesión',
            subtitle: 'Salir de la cuenta',
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Cerrar Sesión'),
                  content: Text('¿Estás seguro que deseas salir?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancelar'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: Text('Salir'),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                try {
                  // Actualizar estado offline en segundo plano (sin esperar)
                  if (_auth.currentUser != null) {
                    _firestore
                        .collection('users')
                        .doc(_auth.currentUser!.uid)
                        .update({
                          'isOnline': false,
                          'lastSeen': FieldValue.serverTimestamp(),
                        }).catchError((e) => print('Error actualizando isOnline: $e'));
                  }

                  // Cerrar sesión inmediatamente
                  await _auth.signOut();

                  // Limpiar stack de navegación y forzar rebuild
                  if (mounted) {
                    Navigator.of(context).pushNamedAndRemoveUntil(
                      '/',
                      (route) => false,
                    );
                  }
                } catch (e) {
                  print('Error al cerrar sesión: $e');
                }
              }
            },
            isDestructive: true,
          ),

          SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _buildProfileOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDestructive
                ? Colors.red.withOpacity(0.1)
                : Color(0xFF9D7FE8).withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: isDestructive ? Colors.red : Color(0xFF9D7FE8),
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: isDestructive ? Colors.red : Color(0xFF2D3142),
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: Colors.grey[50],
      ),
    );
  }

  void _showImageOptions() {
    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Cambiar foto de perfil',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2D3142),
              ),
            ),
            SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildImageOption(
                  icon: Icons.camera_alt,
                  label: 'Cámara',
                  onTap: () => _pickImage(ImageSource.camera),
                ),
                _buildImageOption(
                  icon: Icons.photo_library,
                  label: 'Galería',
                  onTap: () => _pickImage(ImageSource.gallery),
                ),
                if (_currentPhotoURL != null)
                  _buildImageOption(
                    icon: Icons.delete,
                    label: 'Eliminar',
                    onTap: _deleteImage,
                    isDestructive: true,
                  ),
              ],
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildImageOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDestructive
                  ? Colors.red.withOpacity(0.1)
                  : Color(0xFF9D7FE8).withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              size: 32,
              color: isDestructive ? Colors.red : Color(0xFF9D7FE8),
            ),
          ),
          SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDestructive ? Colors.red : Color(0xFF2D3142),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context); // Cerrar bottom sheet

    try {
      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('Procesando imagen...'),
            ],
          ),
        ),
      );

      final String? downloadUrl = await _imageService.pickAndUploadProfileImage(
        source: source,
        context: context,
      );

      Navigator.pop(context); // Cerrar loading

      if (downloadUrl != null) {
        // Actualizar el estado local inmediatamente
        setState(() {
          _currentPhotoURL = downloadUrl;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Foto de perfil actualizada exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      Navigator.pop(context); // Cerrar loading

      String errorMessage = 'Error desconocido';
      if (e.toString().contains('Permisos') &&
          e.toString().contains('denegados')) {
        errorMessage =
            'No se pudo acceder ${source == ImageSource.camera ? 'a la cámara' : 'a la galería'} porque los permisos fueron denegados.';
      } else if (e.toString().contains(
        'Firebase Storage no está configurado',
      )) {
        errorMessage = 'Error de configuración. Contacta al administrador.';
      } else if (e.toString().contains('cámara denegado')) {
        errorMessage =
            'Acceso a la cámara denegado. Verifica los permisos de la aplicación.';
      } else if (e.toString().contains('galería denegado')) {
        errorMessage =
            'Acceso a la galería denegado. Verifica los permisos de la aplicación.';
      } else if (e.toString().contains('PlatformException')) {
        errorMessage = 'Error de plataforma. Intenta reiniciar la aplicación.';
      } else if (e.toString().contains('conexión') ||
          e.toString().contains('internet')) {
        errorMessage =
            'Error de conexión. Verifica tu conexión a internet e intenta nuevamente.';
      } else {
        errorMessage = e.toString().replaceAll('Exception: ', '');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _deleteImage() async {
    Navigator.pop(context); // Cerrar bottom sheet

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar foto'),
        content: Text('¿Estás seguro que deseas eliminar tu foto de perfil?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _imageService.deleteProfileImage();

        // Actualizar el estado local inmediatamente
        setState(() {
          _currentPhotoURL = null;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Foto de perfil eliminada'),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar la foto'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
