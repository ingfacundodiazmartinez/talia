import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'edit_profile_screen.dart';
import 'privacy_security_screen.dart';
import 'help_support_screen.dart';
import 'privacy_policy_screen.dart';
import 'services/image_service.dart';

class ParentProfileScreen extends StatefulWidget {
  const ParentProfileScreen({super.key});

  @override
  State<ParentProfileScreen> createState() => _ParentProfileScreenState();
}

class _ParentProfileScreenState extends State<ParentProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImageService _imageService = ImageService();

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Mi Perfil')),
      body: SingleChildScrollView(
        physics: ClampingScrollPhysics(),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          // Header de perfil
          StreamBuilder<DocumentSnapshot>(
            stream: _firestore
                .collection('users')
                .doc(_auth.currentUser!.uid)
                .snapshots(),
            builder: (context, snapshot) {
              String? photoURL;
              String? displayName;
              String? email = _auth.currentUser?.email;

              if (snapshot.hasData && snapshot.data!.exists) {
                final data = snapshot.data!.data() as Map<String, dynamic>?;
                photoURL = data?['photoURL'];
                displayName = data?['name'];
              }

              return Center(
                child: Column(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 60,
                          backgroundColor: Theme.of(context).primaryColor,
                          backgroundImage: photoURL != null
                              ? NetworkImage(photoURL)
                              : null,
                          child: photoURL == null
                              ? Icon(Icons.person, size: 60, color: Colors.white)
                              : null,
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
                                  color: Theme.of(context).primaryColor,
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                Icons.camera_alt,
                                size: 20,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    Text(
                      displayName ?? 'Usuario',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2D3142),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      email ?? '',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                    SizedBox(height: 8),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Cuenta Padre',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          SizedBox(height: 32),

          // Sección de Hijos
          _buildSectionTitle('Mis Hijos'),
          SizedBox(height: 12),

          StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('parent_children')
                .where('parentId', isEqualTo: _auth.currentUser?.uid)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return Container(
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Text(
                      'No hay hijos vinculados',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ),
                );
              }

              return Column(
                children: snapshot.data!.docs.map((doc) {
                  final childId = doc['childId'];
                  return FutureBuilder<DocumentSnapshot>(
                    future: _firestore.collection('users').doc(childId).get(),
                    builder: (context, userSnapshot) {
                      if (!userSnapshot.hasData) return SizedBox();

                      final userData =
                          userSnapshot.data!.data() as Map<String, dynamic>?;
                      final name = userData?['name'] ?? 'Usuario';

                      return _buildChildCard(name: name);
                    },
                  );
                }).toList(),
              );
            },
          ),

          SizedBox(height: 32),

          // Estadísticas
          _buildSectionTitle('Estadísticas'),
          SizedBox(height: 12),

          // Cargar estadísticas reales desde Firestore
          _buildStatisticsSection(),

          SizedBox(height: 32),

          // Configuración
          _buildSectionTitle('Configuración'),
          SizedBox(height: 12),

          _buildProfileOption(
            icon: Icons.edit,
            title: 'Editar Perfil',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => EditProfileScreen()),
              );
            },
          ),
          _buildProfileOption(
            icon: Icons.security,
            title: 'Privacidad y Seguridad',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PrivacySecurityScreen(),
                ),
              );
            },
          ),
          _buildAutoApprovalSetting(),
          _buildProfileOption(
            icon: Icons.notifications,
            title: 'Notificaciones',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Las notificaciones ya están configuradas'),
                ),
              );
            },
          ),
          _buildProfileOption(
            icon: Icons.help,
            title: 'Ayuda y Soporte',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => HelpSupportScreen()),
              );
            },
          ),
          _buildProfileOption(
            icon: Icons.privacy_tip,
            title: 'Política de Privacidad',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => PrivacyPolicyScreen()),
              );
            },
          ),

          SizedBox(height: 16),

          _buildProfileOption(
            icon: Icons.logout,
            title: 'Cerrar Sesión',
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
        ),
      ),
    );
  }


  void _showImageOptions() {
    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StreamBuilder<DocumentSnapshot>(
        stream: _firestore
            .collection('users')
            .doc(_auth.currentUser!.uid)
            .snapshots(),
        builder: (context, snapshot) {
          String? photoURL;
          if (snapshot.hasData && snapshot.data!.exists) {
            final data = snapshot.data!.data() as Map<String, dynamic>?;
            photoURL = data?['photoURL'];
          }

          return Container(
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
                    if (photoURL != null)
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
          );
        },
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
                  : Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              size: 32,
              color: isDestructive
                  ? Colors.red
                  : Theme.of(context).primaryColor,
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
    // Cerrar bottom sheet y esperar a que se complete la animación
    Navigator.pop(context);

    // Esperar un momento para que el contexto esté disponible correctamente
    await Future.delayed(Duration(milliseconds: 300));

    // Verificar que el widget aún está montado
    if (!mounted) return;

    try {
      print('🔄 Iniciando selección de imagen desde: ${source == ImageSource.camera ? 'cámara' : 'galería'}');

      // Usar ImagePicker directamente como en ProfileCompletionScreen
      final pickedFile = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );

      if (pickedFile == null) {
        print('📷 Usuario canceló la selección de imagen');
        return;
      }

      print('✅ Imagen seleccionada: ${pickedFile.path}');

      // Mostrar loading para subida
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('Subiendo imagen...'),
              ],
            ),
          ),
        );
      }

      // Subir imagen usando ImageService (solo la parte de subida)
      final String? downloadUrl = await _imageService.uploadImageToStorage(pickedFile.path);

      // Cerrar loading si el widget aún está montado
      if (mounted) {
        Navigator.pop(context);
      }

      if (downloadUrl != null) {
        // Actualizar Firestore (el StreamBuilder se actualizará automáticamente)
        await _firestore.collection('users').doc(_auth.currentUser!.uid).update({
          'photoURL': downloadUrl,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Foto de perfil actualizada exitosamente'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      print('❌ Error en _pickImage: $e');

      // Cerrar loading si el widget aún está montado
      if (mounted) {
        try {
          Navigator.pop(context);
        } catch (popError) {
          print('⚠️ Error al cerrar loading dialog: $popError');
        }
      }

      String errorMessage = 'Error desconocido';
      if (e.toString().contains('PlatformException')) {
        if (e.toString().contains('camera_access_denied')) {
          errorMessage = 'Acceso a la cámara denegado. Ve a Configuración > Aplicaciones > Talia > Permisos para habilitarlo.';
        } else if (e.toString().contains('photo_access_denied')) {
          errorMessage = 'Acceso a la galería denegado. Ve a Configuración > Aplicaciones > Talia > Permisos para habilitarlo.';
        } else {
          errorMessage = 'Error de plataforma. Intenta reiniciar la aplicación.';
        }
      } else if (e.toString().contains('Firebase Storage no está configurado')) {
        errorMessage = 'Error de configuración. Contacta al administrador.';
      } else if (e.toString().contains('conexión') || e.toString().contains('internet')) {
        errorMessage = 'Error de conexión. Verifica tu conexión a internet e intenta nuevamente.';
      } else {
        errorMessage = e.toString().replaceAll('Exception: ', '');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
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

        // Actualizar Firestore (el StreamBuilder se actualizará automáticamente)
        await _firestore.collection('users').doc(_auth.currentUser!.uid).update({
          'photoURL': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
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

  Widget _buildStatisticsSection() {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .snapshots(),
      builder: (context, userSnapshot) {
        // Calcular días activos
        int daysActive = 0;
        if (userSnapshot.hasData && userSnapshot.data!.exists) {
          final data = userSnapshot.data!.data() as Map<String, dynamic>?;
          final createdAt = data?['createdAt'] as Timestamp?;
          if (createdAt != null) {
            final now = DateTime.now();
            final created = createdAt.toDate();
            daysActive = now.difference(created).inDays;
          }
        }

        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    icon: Icons.calendar_today,
                    title: 'Días activo',
                    value: '$daysActive',
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _firestore
                        .collection('alerts')
                        .where('parentId', isEqualTo: _auth.currentUser!.uid)
                        .snapshots(),
                    builder: (context, alertsSnapshot) {
                      final reportCount = alertsSnapshot.hasData
                          ? alertsSnapshot.data!.docs.length
                          : 0;
                      return _buildStatCard(
                        icon: Icons.assessment,
                        title: 'Reportes',
                        value: '$reportCount',
                        color: Color(0xFF4CAF50),
                      );
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _firestore
                        .collection('whitelist')
                        .where('parentId', isEqualTo: _auth.currentUser!.uid)
                        .snapshots(),
                    builder: (context, contactsSnapshot) {
                      final totalContacts = contactsSnapshot.hasData
                          ? contactsSnapshot.data!.docs.length
                          : 0;
                      return _buildStatCard(
                        icon: Icons.contacts,
                        title: 'Contactos',
                        value: '$totalContacts',
                        color: Color(0xFF2196F3),
                      );
                    },
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _firestore
                        .collection('whitelist')
                        .where('parentId', isEqualTo: _auth.currentUser!.uid)
                        .where('status', isEqualTo: 'approved')
                        .snapshots(),
                    builder: (context, approvedSnapshot) {
                      final approvedCount = approvedSnapshot.hasData
                          ? approvedSnapshot.data!.docs.length
                          : 0;
                      return _buildStatCard(
                        icon: Icons.check_circle,
                        title: 'Aprobados',
                        value: '$approvedCount',
                        color: Color(0xFFFF9800),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: Color(0xFF2D3142),
      ),
    );
  }

  Widget _buildChildCard({required String name}) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: Theme.of(context).primaryColor.withOpacity(0.2),
            child: Text(
              name[0].toUpperCase(),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).primaryColor,
              ),
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Hijo vinculado',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey[400]),
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          icon,
          color: isDestructive ? Colors.red : Theme.of(context).primaryColor,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: isDestructive ? Colors.red : Color(0xFF2D3142),
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: Colors.grey[50],
      ),
    );
  }

  Widget _buildAutoApprovalSetting() {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore
          .collection('parent_settings')
          .doc(_auth.currentUser!.uid)
          .snapshots(),
      builder: (context, snapshot) {
        bool autoApprovalEnabled = false;

        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          autoApprovalEnabled = data?['autoApproveRequests'] ?? false;
        }

        return Container(
          margin: EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(
              Icons.auto_awesome,
              color: Theme.of(context).primaryColor,
            ),
            title: Text(
              'Aceptar solicitudes por defecto',
              style: TextStyle(
                color: Color(0xFF2D3142),
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              autoApprovalEnabled
                  ? 'Las nuevas solicitudes se aprueban automáticamente'
                  : 'Requiere aprobación manual para cada solicitud',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            trailing: Switch(
              value: autoApprovalEnabled,
              onChanged: (value) => _toggleAutoApproval(value),
              activeThumbColor: Theme.of(context).primaryColor,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: Colors.grey[50],
          ),
        );
      },
    );
  }

  Future<void> _toggleAutoApproval(bool enabled) async {
    try {
      await _firestore
          .collection('parent_settings')
          .doc(_auth.currentUser!.uid)
          .set({
            'autoApproveRequests': enabled,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? 'Aprobación automática activada'
                : 'Aprobación automática desactivada',
          ),
          backgroundColor: enabled ? Colors.green : Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al actualizar configuración: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
