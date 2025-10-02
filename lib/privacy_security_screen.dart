import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'dart:convert';

class PrivacySecurityScreen extends StatefulWidget {
  const PrivacySecurityScreen({super.key});

  @override
  State<PrivacySecurityScreen> createState() => _PrivacySecurityScreenState();
}

class _PrivacySecurityScreenState extends State<PrivacySecurityScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _twoFactorEnabled = false;
  bool _showOnlineStatus = true;
  bool _allowScreenshots = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(_auth.currentUser?.uid)
          .get();
      if (doc.exists) {
        final data = doc.data();
        setState(() {
          _twoFactorEnabled = data?['twoFactorEnabled'] ?? false;
          _showOnlineStatus = data?['showOnlineStatus'] ?? true;
          _allowScreenshots = data?['allowScreenshots'] ?? false;
        });
      }
    } catch (e) {
      print('Error loading settings: $e');
    }
  }

  Future<void> _updateSetting(String key, bool value) async {
    try {
      await _firestore.collection('users').doc(_auth.currentUser?.uid).update({
        key: value,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al actualizar configuración'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showChangePasswordDialog() {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cambiar Contraseña'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Contraseña Actual',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: newPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Nueva Contraseña',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Confirmar Contraseña',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (newPasswordController.text !=
                  confirmPasswordController.text) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Las contraseñas no coinciden')),
                );
                return;
              }

              try {
                // Reautenticar usuario
                final credential = EmailAuthProvider.credential(
                  email: _auth.currentUser!.email!,
                  password: currentPasswordController.text,
                );
                await _auth.currentUser!.reauthenticateWithCredential(
                  credential,
                );

                // Cambiar contraseña
                await _auth.currentUser!.updatePassword(
                  newPasswordController.text,
                );

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Contraseña actualizada exitosamente'),
                    backgroundColor: Colors.green,
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error: ${e.toString()}'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Color(0xFF9D7FE8)),
            child: Text('Cambiar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Privacidad y Seguridad'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Sección de Seguridad
          Text(
            'Seguridad',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildSecurityOption(
            icon: Icons.lock_outline,
            title: 'Cambiar Contraseña',
            subtitle: 'Actualiza tu contraseña de acceso',
            onTap: _showChangePasswordDialog,
          ),

          _buildSwitchOption(
            icon: Icons.verified_user,
            title: 'Autenticación de Dos Factores',
            subtitle: 'Añade una capa extra de seguridad',
            value: _twoFactorEnabled,
            onChanged: (value) {
              setState(() => _twoFactorEnabled = value);
              _updateSetting('twoFactorEnabled', value);
            },
          ),

          SizedBox(height: 32),

          // Sección de Privacidad
          Text(
            'Privacidad',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildSwitchOption(
            icon: Icons.visibility_outlined,
            title: 'Mostrar Estado en Línea',
            subtitle: 'Otros pueden ver cuando estás activo',
            value: _showOnlineStatus,
            onChanged: (value) {
              setState(() => _showOnlineStatus = value);
              _updateSetting('showOnlineStatus', value);
            },
          ),

          _buildSwitchOption(
            icon: Icons.screenshot_outlined,
            title: 'Permitir Capturas de Pantalla',
            subtitle: 'Permite tomar screenshots en la app',
            value: _allowScreenshots,
            onChanged: (value) {
              setState(() => _allowScreenshots = value);
              _updateSetting('allowScreenshots', value);
            },
          ),

          SizedBox(height: 32),

          // Sección de Datos
          Text(
            'Gestión de Datos',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildSecurityOption(
            icon: Icons.download_outlined,
            title: 'Descargar Mis Datos',
            subtitle: 'Descarga una copia de tu información',
            onTap: _showDownloadDataDialog,
          ),

          _buildSecurityOption(
            icon: Icons.delete_outline,
            title: 'Eliminar Cuenta',
            subtitle: 'Elimina permanentemente tu cuenta',
            isDestructive: true,
            onTap: () => _showDeleteAccountDialog(),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDestructive
                ? Colors.red.withOpacity(0.1)
                : Color(0xFF9D7FE8).withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: isDestructive ? Colors.red : Color(0xFF9D7FE8),
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDestructive ? Colors.red : Color(0xFF2D3142),
          ),
        ),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12)),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: Colors.grey[50],
      ),
    );
  }

  Widget _buildSwitchOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Function(bool) onChanged,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        secondary: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Color(0xFF9D7FE8).withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Color(0xFF9D7FE8)),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF2D3142),
          ),
        ),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12)),
        activeThumbColor: Color(0xFF9D7FE8),
      ),
    );
  }

  void _showDownloadDataDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.download_outlined, color: Color(0xFF9D7FE8)),
            SizedBox(width: 8),
            Text('Descargar Mis Datos'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Se creará un archivo con toda tu información personal según GDPR:',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            _buildDataIncludeItem('• Información de perfil'),
            _buildDataIncludeItem('• Configuraciones de privacidad'),
            _buildDataIncludeItem('• Historial de actividad'),
            _buildDataIncludeItem('• Metadata de sesiones'),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'El archivo será compartido de forma segura y no incluye contenido de mensajes.',
                      style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _downloadUserData();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFF9D7FE8),
              foregroundColor: Colors.white,
            ),
            child: Text('Descargar'),
          ),
        ],
      ),
    );
  }

  Widget _buildDataIncludeItem(String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: Colors.grey[700]),
      ),
    );
  }

  Future<void> _downloadUserData() async {
    try {
      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF9D7FE8)),
                SizedBox(height: 16),
                Text('Recopilando tus datos...'),
              ],
            ),
          ),
        ),
      );

      final userData = await _collectUserData();
      final file = await _createDataFile(userData);

      Navigator.pop(context); // Cerrar loading

      // Compartir archivo
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Mis Datos Personales - SmartConvo',
        text:
            'Aquí tienes una copia de todos tus datos personales de SmartConvo.',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Datos descargados exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      Navigator.of(
        context,
        rootNavigator: true,
      ).pop(); // Cerrar loading si hay error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al descargar datos: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<Map<String, dynamic>> _collectUserData() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    final Map<String, dynamic> allData = {
      'exportInfo': {
        'exportDate': DateTime.now().toIso8601String(),
        'exportVersion': '1.0',
        'userId': user.uid,
      },
      'profile': {},
      'settings': {},
      'activityMetadata': {},
    };

    // Recopilar datos del perfil
    try {
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (userDoc.exists) {
        final data = Map<String, dynamic>.from(userDoc.data()!);
        // Remover datos sensibles que no deberían exportarse
        data.remove('fcmToken');
        allData['profile'] = data;
      }
    } catch (e) {
      print('Error collecting profile data: $e');
    }

    // Recopilar metadata de configuraciones
    allData['settings'] = {
      'twoFactorEnabled': _twoFactorEnabled,
      'showOnlineStatus': _showOnlineStatus,
      'allowScreenshots': _allowScreenshots,
    };

    // Recopilar metadata de actividad (sin contenido de mensajes)
    try {
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      allData['activityMetadata'] = {
        'totalChats': chatsQuery.docs.length,
        'chatCreationDates': chatsQuery.docs
            .map((doc) {
              final data = doc.data();
              return data['createdAt']?.toDate()?.toIso8601String();
            })
            .where((date) => date != null)
            .toList(),
      };
    } catch (e) {
      print('Error collecting activity metadata: $e');
    }

    // Recopilar reportes de soporte enviados
    try {
      final reportsQuery = await _firestore
          .collection('support_reports')
          .where('userId', isEqualTo: user.uid)
          .get();

      allData['supportReports'] = reportsQuery.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        // Mantener solo metadata relevante
        return {
          'reportId': doc.id,
          'category': data['category'],
          'title': data['title'],
          'status': data['status'],
          'createdAt': data['createdAt']?.toDate()?.toIso8601String(),
        };
      }).toList();
    } catch (e) {
      print('Error collecting support reports: $e');
    }

    return allData;
  }

  Future<File> _createDataFile(Map<String, dynamic> userData) async {
    final directory = await getApplicationDocumentsDirectory();
    final fileName =
        'smartconvo_datos_${DateTime.now().millisecondsSinceEpoch}.json';
    final file = File('${directory.path}/$fileName');

    final jsonString = JsonEncoder.withIndent('  ').convert(userData);
    await file.writeAsString(jsonString);

    return file;
  }

  void _showDeleteAccountDialog() {
    final passwordController = TextEditingController();
    String confirmationText = '';
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.warning, color: Colors.red),
              SizedBox(width: 8),
              Text('Eliminar Cuenta'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber,
                            color: Colors.red,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'ADVERTENCIA',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Esta acción es PERMANENTE e IRREVERSIBLE.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.red[800],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Se eliminarán permanentemente:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                _buildDeleteItem('• Tu perfil y toda la información personal'),
                _buildDeleteItem('• Todos los chats y mensajes'),
                _buildDeleteItem('• Vínculos con hijos o padres'),
                _buildDeleteItem('• Configuraciones y preferencias'),
                _buildDeleteItem('• Historial de actividad'),
                SizedBox(height: 16),
                Text(
                  'Para confirmar, ingresa tu contraseña:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  enabled: !isLoading,
                  decoration: InputDecoration(
                    hintText: 'Tu contraseña actual',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: Icon(Icons.lock_outline),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Escribe "ELIMINAR CUENTA" para confirmar:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                TextField(
                  enabled: !isLoading,
                  onChanged: (value) {
                    setState(() {
                      confirmationText = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'ELIMINAR CUENTA',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(context),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed:
                  isLoading ||
                      passwordController.text.trim().isEmpty ||
                      confirmationText != 'ELIMINAR CUENTA'
                  ? null
                  : () async {
                      setState(() {
                        isLoading = true;
                      });

                      try {
                        await _deleteUserAccount(
                          passwordController.text.trim(),
                        );
                        Navigator.of(context, rootNavigator: true).pop();
                        // Navegar al login
                        Navigator.of(
                          context,
                        ).pushNamedAndRemoveUntil('/login', (route) => false);
                      } catch (e) {
                        setState(() {
                          isLoading = false;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Error: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: isLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text('Eliminar Cuenta'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteItem(String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: Colors.grey[700]),
      ),
    );
  }

  Future<void> _deleteUserAccount(String password) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      // 1. Reautenticar usuario
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: password,
      );
      await user.reauthenticateWithCredential(credential);

      // 2. Eliminar datos de Firestore
      await _deleteUserDataFromFirestore(user.uid);

      // 3. Eliminar imágenes de Storage
      await _deleteUserImagesFromStorage(user.uid);

      // 4. Eliminar cuenta de Authentication
      await user.delete();
    } catch (e) {
      throw Exception('Error al eliminar cuenta: ${e.toString()}');
    }
  }

  Future<void> _deleteUserDataFromFirestore(String userId) async {
    final batch = _firestore.batch();

    try {
      // Eliminar documento del usuario
      batch.delete(_firestore.collection('users').doc(userId));

      // Eliminar de listas blancas
      final whitelistQuery = await _firestore
          .collection('whitelist')
          .where('childId', isEqualTo: userId)
          .get();
      for (var doc in whitelistQuery.docs) {
        batch.delete(doc.reference);
      }

      final whitelistQuery2 = await _firestore
          .collection('whitelist')
          .where('contactId', isEqualTo: userId)
          .get();
      for (var doc in whitelistQuery2.docs) {
        batch.delete(doc.reference);
      }

      // Eliminar chats y mensajes
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .get();

      for (var chatDoc in chatsQuery.docs) {
        // Eliminar mensajes del chat
        final messagesQuery = await chatDoc.reference
            .collection('messages')
            .get();
        for (var msgDoc in messagesQuery.docs) {
          batch.delete(msgDoc.reference);
        }
        // Eliminar el chat
        batch.delete(chatDoc.reference);
      }

      // Eliminar reportes de soporte
      final reportsQuery = await _firestore
          .collection('support_reports')
          .where('userId', isEqualTo: userId)
          .get();
      for (var doc in reportsQuery.docs) {
        batch.delete(doc.reference);
      }

      // Eliminar solicitudes de contacto
      final contactRequestsQuery = await _firestore
          .collection('contact_requests')
          .where('childId', isEqualTo: userId)
          .get();
      for (var doc in contactRequestsQuery.docs) {
        batch.delete(doc.reference);
      }

      // Ejecutar todas las eliminaciones
      await batch.commit();
    } catch (e) {
      throw Exception('Error eliminando datos de Firestore: $e');
    }
  }

  Future<void> _deleteUserImagesFromStorage(String userId) async {
    try {
      // Eliminar carpeta de imágenes de perfil del usuario
      final storageRef = FirebaseStorage.instance.ref('profile_images');
      final listResult = await storageRef.listAll();

      for (var item in listResult.items) {
        if (item.name.contains(userId)) {
          try {
            await item.delete();
          } catch (e) {
            print('Error eliminando imagen ${item.name}: $e');
          }
        }
      }
    } catch (e) {
      print('Error eliminando imágenes de Storage: $e');
      // No lanzar error aquí para no bloquear la eliminación de la cuenta
    }
  }
}
