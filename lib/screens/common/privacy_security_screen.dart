import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/data_export_service.dart';
import '../../services/two_factor_auth_service.dart';
import '../../services/user_settings_service.dart';
import '../../services/account_deletion_service.dart';
import '../../services/online_status_service.dart';
import '../../services/screenshot_protection_service.dart';
import 'widgets/enable_2fa_dialog.dart';
import 'widgets/delete_account_dialog.dart';

class PrivacySecurityScreen extends StatefulWidget {
  const PrivacySecurityScreen({super.key});

  @override
  State<PrivacySecurityScreen> createState() => _PrivacySecurityScreenState();
}

class _PrivacySecurityScreenState extends State<PrivacySecurityScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final _settingsService = UserSettingsService();
  final _accountDeletionService = AccountDeletionService();

  bool _twoFactorEnabled = false;
  bool _showOnlineStatus = true;
  bool _sendReadReceipts = true;
  bool _allowScreenshots = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final data = await _settingsService.loadSettings();
      setState(() {
        _twoFactorEnabled = data['twoFactorEnabled'] ?? false;
        _showOnlineStatus = data['showOnlineStatus'] ?? true;
        _sendReadReceipts = data['sendReadReceipts'] ?? true;
        _allowScreenshots = data['allowScreenshots'] ?? false;
      });
    } catch (e) {
      // Error loading settings - silent
    }
  }

  Future<void> _updateSetting(String key, bool value) async {
    try {
      await _settingsService.updateSetting(key, value);
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
            onChanged: (value) async {
              setState(() => _showOnlineStatus = value);
              await _updateSetting('showOnlineStatus', value);

              // Forzar actualización inmediata del estado online
              if (value) {
                await OnlineStatusService().setOnline();
              } else {
                await OnlineStatusService().setOffline();
              }
            },
          ),

          _buildSwitchOption(
            icon: Icons.done_all,
            title: 'Confirmaciones de Lectura',
            subtitle: 'Permite que otros vean cuándo leíste sus mensajes',
            value: _sendReadReceipts,
            onChanged: (value) async {
              setState(() => _sendReadReceipts = value);
              await _updateSetting('sendReadReceipts', value);
            },
          ),

          _buildSwitchOption(
            icon: Icons.screenshot_outlined,
            title: 'Permitir Capturas de Pantalla',
            subtitle: Platform.isIOS
                ? 'No disponible en iOS - Apple no permite bloquear screenshots'
                : 'Permite tomar screenshots en la app',
            value: _allowScreenshots,
            onChanged: Platform.isIOS
                ? null  // Deshabilitar en iOS
                : (value) {
                    setState(() => _allowScreenshots = value);
                    _updateSetting('allowScreenshots', value);

                    // Actualizar protección de screenshots
                    ScreenshotProtectionService().updateProtection(value);
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
            icon: Icons.upload_outlined,
            title: 'Importar Datos',
            subtitle: 'Restaura un backup desde otro dispositivo',
            onTap: _showImportDataDialog,
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
    Function(bool)? onChanged,
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
        activeThumbColor: colorScheme.primary,
        activeTrackColor: colorScheme.primary.withValues(alpha: 0.5),
      ),
    );
  }

  void _showDownloadDataDialog() {
    final colorScheme = Theme.of(context).colorScheme;
    final passwordController = TextEditingController();
    bool isExporting = false;
    double exportProgress = 0.0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.download_outlined, color: colorScheme.primary),
              SizedBox(width: 8),
              Text('Exportar Cache Local'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isExporting) ...[
                Text(
                  'Crea un backup encriptado de tus mensajes en cache para migrar a otro dispositivo.',
                  style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.security, color: colorScheme.primary, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'El archivo será encriptado con tu contraseña',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Ingresa una contraseña para encriptar el backup:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Contraseña',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
              ] else ...[
                Column(
                  children: [
                    CircularProgressIndicator(value: exportProgress),
                    SizedBox(height: 16),
                    Text(
                      'Exportando cache... ${(exportProgress * 100).toInt()}%',
                      style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            if (!isExporting) ...[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (passwordController.text.length < 6) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('La contraseña debe tener al menos 6 caracteres'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  setState(() => isExporting = true);

                  final exportService = DataExportService();
                  final filePath = await exportService.exportEncryptedCache(
                    password: passwordController.text,
                    onProgress: (progress) {
                      setState(() => exportProgress = progress);
                    },
                  );

                  Navigator.pop(context);

                  if (filePath != null) {
                    // Mostrar opciones para compartir
                    _showExportSuccessDialog(filePath);
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error al exportar cache'),
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
                child: Text('Exportar'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showExportSuccessDialog(String filePath) {
    final colorScheme = Theme.of(context).colorScheme;
    final exportService = DataExportService();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('Backup Creado'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tu cache ha sido exportado exitosamente.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Archivo:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    filePath.split('/').last,
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ],
              ),
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
                      'Guarda este archivo de forma segura',
                      style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                    ),
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
            child: Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _showImportDataDialog() async {
    final colorScheme = Theme.of(context).colorScheme;
    final exportService = DataExportService();

    // Obtener lista de backups disponibles
    final backups = await exportService.listAvailableBackups();

    if (!mounted) return;

    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No hay backups disponibles'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Mostrar lista de backups para seleccionar
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.upload_outlined, color: colorScheme.primary),
            SizedBox(width: 8),
            Text('Seleccionar Backup'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Selecciona el backup que deseas restaurar:',
                style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
              ),
              SizedBox(height: 16),
              Container(
                constraints: BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: backups.length,
                  itemBuilder: (context, index) {
                    final backup = backups[index];
                    return Card(
                      margin: EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(Icons.folder_zip, color: colorScheme.primary),
                        title: Text(
                          backup.fileName,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(height: 4),
                            Text(
                              backup.formattedDate,
                              style: TextStyle(fontSize: 11),
                            ),
                            Text(
                              'Tamaño: ${backup.fileSizeMB} MB',
                              style: TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _showImportPasswordDialog(backup.filePath);
                        },
                      ),
                    );
                  },
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
        ],
      ),
    );
  }

  void _showImportPasswordDialog(String filePath) {
    final colorScheme = Theme.of(context).colorScheme;
    final passwordController = TextEditingController();
    bool isImporting = false;
    double importProgress = 0.0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.upload_outlined, color: colorScheme.primary),
              SizedBox(width: 8),
              Text('Importar Backup'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isImporting) ...[
                Text(
                  'Restaura tus mensajes desde un backup encriptado.',
                  style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Archivo seleccionado:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 4),
                      Text(
                        filePath.split('/').last,
                        style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
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
                          'Esto sobrescribirá tu cache actual',
                          style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Ingresa la contraseña del backup:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Contraseña',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
              ] else ...[
                Column(
                  children: [
                    CircularProgressIndicator(value: importProgress),
                    SizedBox(height: 16),
                    Text(
                      'Importando backup... ${(importProgress * 100).toInt()}%',
                      style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            if (!isImporting) ...[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (passwordController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Ingresa la contraseña del backup'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  setState(() => isImporting = true);

                  final exportService = DataExportService();
                  final success = await exportService.importEncryptedCache(
                    filePath: filePath,
                    password: passwordController.text,
                    onProgress: (progress) {
                      setState(() => importProgress = progress);
                    },
                  );

                  Navigator.pop(context);

                  if (!success) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error: Contraseña incorrecta o archivo corrupto'),
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
                child: Text('Importar'),
              ),
            ],
          ],
        ),
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

  void _showDeleteAccountDialog() {
    showDialog(
      context: context,
      builder: (context) => DeleteAccountDialog(
        onConfirm: (password) async {
          await _accountDeletionService.deleteAccount(password);
        },
      ),
    );
  }

  // ==========================================================================
  // AUTENTICACIÓN DE DOS FACTORES (2FA)
  // ==========================================================================

  /// Muestra el flujo para habilitar 2FA
  void _showEnable2FAFlow() async {
    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Enable2FADialog(
          onComplete: () {
            setState(() => _twoFactorEnabled = true);
          },
        ),
      );
    } catch (e) {
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
