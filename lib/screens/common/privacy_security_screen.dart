import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/data_export_service.dart';
import '../../services/two_factor_auth_service.dart';

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


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Privacidad y Seguridad'),
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
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),

          _buildSwitchOption(
            icon: Icons.verified_user,
            title: 'Autenticación de Dos Factores',
            subtitle: 'Añade una capa extra de seguridad',
            value: _twoFactorEnabled,
            onChanged: (value) {
              if (value) {
                _showEnable2FAFlow();
              } else {
                _showDisable2FADialog();
              }
            },
          ),

          SizedBox(height: 32),

          // Sección de Privacidad
          Text(
            'Privacidad',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
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
              color: colorScheme.onSurface,
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
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDestructive
                ? Colors.red.withValues(alpha: 0.1)
                : colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: isDestructive ? Colors.red : colorScheme.primary,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDestructive ? Colors.red : colorScheme.onSurface,
          ),
        ),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: colorScheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: colorScheme.surfaceContainerHighest,
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
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        secondary: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: colorScheme.primary),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        activeColor: colorScheme.primary,
        activeTrackColor: colorScheme.primary.withValues(alpha: 0.5),
      ),
    );
  }

  void _showDownloadDataDialog() {
    final colorScheme = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.construction, color: Colors.orange),
            SizedBox(width: 8),
            Text('Funcionalidad en Desarrollo'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Esta funcionalidad está en progreso',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'La exportación de datos aún no está disponible. Estamos trabajando para habilitarla pronto.',
              style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
            ),
            SizedBox(height: 16),
            Text(
              '¿Qué podrás hacer cuando esté lista?',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 8),
            _buildFeatureItem('• Descargar toda tu información personal'),
            _buildFeatureItem('• Exportar tus mensajes y conversaciones'),
            _buildFeatureItem('• Obtener historial de actividad'),
            _buildFeatureItem('• Cumplimiento con GDPR y CCPA'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureItem(String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildExportOption({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required String description,
    required String time,
    required List<String> features,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          if (subtitle != null) ...[
                            SizedBox(width: 8),
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                subtitle,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green[700],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: 4),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: colorScheme.onSurfaceVariant),
                SizedBox(width: 4),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            ...features.map((feature) => Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.check, size: 14, color: Colors.green),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      feature,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // EXPORTACIÓN DE DATOS
  // ==========================================================================

  Future<void> _performQuickExport() async {
    final colorScheme = Theme.of(context).colorScheme;
    final exportService = DataExportService();

    try {
      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: colorScheme.primary),
                SizedBox(height: 16),
                Text(
                  'Recopilando tus datos...',
                  style: TextStyle(color: colorScheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      );

      final result = await exportService.performQuickExport();

      Navigator.pop(context); // Cerrar loading

      // Compartir archivos (JSON + README)
      await Share.shareXFiles(
        [
          XFile(result.jsonFile.path),
          XFile(result.readmeFile.path),
        ],
        subject: 'Mis Datos Personales - Talia (Export Rápido)',
        text:
            'Aquí tienes una copia de tus datos personales de Talia.\n\n'
            'Incluye: ${result.dataSummary['totalSections']} secciones de datos.',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Expanded(child: Text('Export rápido completado')),
              ],
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      Navigator.of(context, rootNavigator: true).pop(); // Cerrar loading
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al exportar datos: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _requestFullExport() async {
    final colorScheme = Theme.of(context).colorScheme;
    final exportService = DataExportService();

    try {
      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: colorScheme.primary),
                SizedBox(height: 16),
                Text(
                  'Creando solicitud...',
                  style: TextStyle(color: colorScheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      );

      await exportService.requestFullExport();

      Navigator.pop(context); // Cerrar loading

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text('Solicitud Enviada'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tu solicitud de export completo ha sido enviada.',
                  style: TextStyle(fontSize: 14),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.blue, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '¿Qué pasa ahora?',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue[800],
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '• Procesaremos tu solicitud en 5-15 minutos\n'
                        '• Recibirás una notificación cuando esté listo\n'
                        '• El link de descarga expira en 7 días',
                        style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
                child: Text('Entendido'),
              ),
            ],
          ),
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.schedule, color: Colors.white),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Tu export se está procesando. Te notificaremos cuando esté listo.'),
                ),
              ],
            ),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      Navigator.of(context, rootNavigator: true).pop(); // Cerrar loading
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al crear solicitud: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showDeleteAccountDialog() {
    final passwordController = TextEditingController();
    final colorScheme = Theme.of(context).colorScheme;
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
                    color: Colors.red.withValues(alpha: 0.1),
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
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
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
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
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
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
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
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: colorScheme.onSurfaceVariant,
        ),
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

      // Eliminar de contactos
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .get();
      for (var doc in contactsQuery.docs) {
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

  // ==========================================================================
  // AUTENTICACIÓN DE DOS FACTORES (2FA)
  // ==========================================================================

  /// Muestra el flujo para habilitar 2FA
  void _showEnable2FAFlow() async {
    print('🔐 Iniciando flujo de 2FA...');
    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => _Enable2FADialog(
          onComplete: () {
            setState(() => _twoFactorEnabled = true);
          },
        ),
      );
    } catch (e) {
      print('❌ Error en flujo de 2FA: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al abrir configuración de 2FA: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Muestra el diálogo para deshabilitar 2FA
  void _showDisable2FADialog() {
    final colorScheme = Theme.of(context).colorScheme;
    final codeController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.shield_outlined, color: colorScheme.primary),
            SizedBox(width: 8),
            Text('Deshabilitar 2FA'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '¿Estás seguro que deseas deshabilitar la autenticación de dos factores?',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tu cuenta será menos segura sin 2FA',
                      style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Ingresa el código de tu app de autenticación para confirmar:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            SizedBox(height: 8),
            TextField(
              controller: codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
              decoration: InputDecoration(
                hintText: '000000',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                counterText: '',
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
              if (codeController.text.length != 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Por favor ingresa un código de 6 dígitos'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              // Mostrar loading
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => Center(
                  child: CircularProgressIndicator(),
                ),
              );

              final twoFactorService = TwoFactorAuthService();

              // Obtener el secreto del usuario
              final secret = await twoFactorService.get2FASecret(_auth.currentUser!.uid);

              Navigator.pop(context); // Cerrar loading

              if (secret == null) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: No se encontró configuración de 2FA'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
                return;
              }

              // Verificar el código TOTP
              final verified = twoFactorService.verifyTOTPCode(
                secret,
                codeController.text,
              );

              if (verified) {
                try {
                  await twoFactorService.disable2FA(_auth.currentUser!.uid);

                  Navigator.pop(context); // Cerrar diálogo

                  setState(() => _twoFactorEnabled = false);

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.white),
                            SizedBox(width: 8),
                            Text('2FA deshabilitado correctamente'),
                          ],
                        ),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error al deshabilitar 2FA: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Código incorrecto. Verifica en tu app de autenticación.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: Text('Deshabilitar'),
          ),
        ],
      ),
    );
  }
}

/// Widget para el flujo de habilitación de 2FA
class _Enable2FADialog extends StatefulWidget {
  final VoidCallback onComplete;

  const _Enable2FADialog({required this.onComplete});

  @override
  State<_Enable2FADialog> createState() => _Enable2FADialogState();
}

class _Enable2FADialogState extends State<_Enable2FADialog> {
  final _twoFactorService = TwoFactorAuthService();
  final _auth = FirebaseAuth.instance;
  final _codeController = TextEditingController();

  int _step = 1; // 1: QR Code, 2: Verificación, 3: Códigos de recuperación
  bool _isLoading = false;
  String? _secret;
  String? _qrCodeUri;
  List<String>? _recoveryCodes;

  @override
  void initState() {
    super.initState();
    print('🔐 _Enable2FADialog initState llamado');
    // Ejecutar después de que el widget esté construido
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _generateSecretAndQR();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  /// Genera el secreto y QR al iniciar
  Future<void> _generateSecretAndQR() async {
    print('🔐 Generando secreto y QR...');
    setState(() => _isLoading = true);

    try {
      print('🔐 Generando secreto TOTP...');
      _secret = _twoFactorService.generateSecret();
      print('✅ Secreto generado: ${_secret?.substring(0, 8)}...');

      print('🔐 Generando URI de QR...');
      final userIdentifier = _auth.currentUser?.email ??
                            _auth.currentUser?.phoneNumber ??
                            _auth.currentUser?.uid ??
                            'Usuario Talia';
      print('📱 Identificador de usuario: $userIdentifier');

      _qrCodeUri = _twoFactorService.generateQRCodeUri(
        secret: _secret!,
        email: userIdentifier,
      );
      print('✅ QR URI generado: ${_qrCodeUri?.substring(0, 30)}...');

      print('🔐 Generando códigos de recuperación...');
      _recoveryCodes = _twoFactorService.generateRecoveryCodes();
      print('✅ ${_recoveryCodes?.length} códigos generados');

      print('✅ 2FA setup completado exitosamente');
    } catch (e, stackTrace) {
      print('❌ Error generando datos 2FA: $e');
      print('Stack trace: $stackTrace');

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al generar código QR: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    print('🔐 _Enable2FADialog build - step: $_step, loading: $_isLoading');
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !(_isLoading && _step == 1),
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.verified_user, color: colorScheme.primary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                _isLoading && _step == 1
                    ? 'Configurando 2FA'
                    : _step == 1
                        ? 'Escanea el código QR'
                        : _step == 2
                            ? 'Verifica el código'
                            : 'Códigos de Recuperación',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 400,
            maxHeight: 600,
          ),
          child: SingleChildScrollView(
            child: _buildStepContent(),
          ),
        ),
        actions: _isLoading && _step == 1 ? [] : _buildActions(colorScheme),
      ),
    );
  }

  Widget _buildStepContent() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading && _step == 1) {
      return Container(
        padding: EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: colorScheme.primary,
              strokeWidth: 3,
            ),
            SizedBox(height: 24),
            Text(
              'Preparando autenticación...',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Esto tomará solo unos segundos',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    switch (_step) {
      case 1:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Añade una capa extra de seguridad a tu cuenta',
                      style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Escanea este código QR con tu app de autenticación:',
              style: TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              '(Google Authenticator, Authy, Microsoft Authenticator, etc.)',
              style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: SizedBox(
                width: 200,
                height: 200,
                child: QrImageView(
                  data: _qrCodeUri ?? '',
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    '¿No puedes escanear?',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Clave manual:',
                    style: TextStyle(fontSize: 11),
                  ),
                  SizedBox(height: 4),
                  SelectableText(
                    _secret ?? '',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _secret ?? ''));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Clave copiada al portapapeles'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: Icon(Icons.copy, size: 16),
                    label: Text('Copiar clave', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
        );

      case 2:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ingresa el código de 6 dígitos que aparece en tu app de autenticación:',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: !_isLoading,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
              decoration: InputDecoration(
                hintText: '000000',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                counterText: '',
              ),
            ),
          ],
        );

      case 3:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '¡IMPORTANTE! Guarda estos códigos en un lugar seguro.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Códigos de recuperación:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            SizedBox(height: 8),
            Text(
              'Usa estos códigos si pierdes acceso a tu app de autenticación. Cada código solo se puede usar una vez.',
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...(_recoveryCodes ?? []).map((code) => Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          code,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )),
                ],
              ),
            ),
            SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () {
                final allCodes = (_recoveryCodes ?? []).join('\n');
                Clipboard.setData(ClipboardData(text: allCodes));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Códigos copiados al portapapeles'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: Icon(Icons.copy),
              label: Text('Copiar todos los códigos'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );

      default:
        return SizedBox.shrink();
    }
  }

  List<Widget> _buildActions(ColorScheme colorScheme) {
    if (_step == 3) {
      return [
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            widget.onComplete();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
          child: Text('¡Entendido!'),
        ),
      ];
    }

    return [
      if (_step > 1)
        TextButton(
          onPressed: _isLoading
              ? null
              : () {
                  setState(() => _step--);
                },
          child: Text('Atrás'),
        ),
      if (_step < 2)
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancelar'),
        ),
      ElevatedButton(
        onPressed: _isLoading ? null : _handleNextStep,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: Colors.white,
        ),
        child: _isLoading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(_step == 2 ? 'Verificar' : 'Siguiente'),
      ),
    ];
  }

  Future<void> _handleNextStep() async {
    setState(() => _isLoading = true);

    try {
      switch (_step) {
        case 1:
          // Ir al paso de verificación
          setState(() => _step = 2);
          break;
        case 2:
          await _verifyCodeAndEnable2FA();
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
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

  Future<void> _verifyCodeAndEnable2FA() async {
    if (_codeController.text.length != 6) {
      throw Exception('Por favor ingresa un código de 6 dígitos');
    }

    final isValid = _twoFactorService.verifyTOTPCode(
      _secret!,
      _codeController.text,
    );

    if (!isValid) {
      throw Exception('Código incorrecto. Por favor intenta nuevamente.');
    }

    // Habilitar 2FA
    await _twoFactorService.enable2FA(
      userId: _auth.currentUser!.uid,
      secret: _secret!,
      recoveryCodes: _recoveryCodes!,
    );

    // Log evento de seguridad
    await _twoFactorService.logSecurityEvent(
      userId: _auth.currentUser!.uid,
      eventType: '2fa_enabled',
      description: 'Usuario habilitó autenticación de dos factores',
    );

    setState(() => _step = 3);
  }
}
