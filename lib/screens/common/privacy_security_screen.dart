import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/data_export_service.dart';
import '../../services/two_factor_auth_service.dart';
import '../../services/user_settings_service.dart';
import '../../services/account_deletion_service.dart';
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
        _allowScreenshots = data['allowScreenshots'] ?? false;
      });
    } catch (e) {
      print('Error loading settings: $e');
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
    print('🔐 Iniciando flujo de 2FA...');
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
