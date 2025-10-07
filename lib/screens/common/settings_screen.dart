import 'package:flutter/material.dart';
import '../../services/theme_service.dart';
import 'privacy_security_screen.dart';
import '../../screens/notifications/notification_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ThemeService _themeService = ThemeService();

  @override
  void initState() {
    super.initState();
    _themeService.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeService.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Configuración'),
      ),
      body: ListView(
        children: [
          // Sección de Apariencia
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Apariencia',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          SwitchListTile(
            secondary: Icon(
              _themeService.isDarkMode ? Icons.dark_mode : Icons.light_mode,
              color: colorScheme.primary,
            ),
            title: Text(
              'Modo Oscuro',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
            subtitle: Text(
              _themeService.isDarkMode
                  ? 'Desactivar para usar tema claro'
                  : 'Activar para reducir fatiga visual',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            value: _themeService.isDarkMode,
            activeColor: colorScheme.primary,
            onChanged: (bool value) async {
              await _themeService.toggleTheme();
            },
          ),
          Divider(),

          // Sección de Notificaciones (placeholder)
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Notificaciones',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.notifications, color: colorScheme.primary),
            title: Text(
              'Notificaciones Push',
              style: TextStyle(color: colorScheme.onSurface),
            ),
            subtitle: Text(
              'Gestionar notificaciones de la aplicación',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => NotificationSettingsScreen(),
                ),
              );
            },
          ),
          Divider(),

          // Sección de Privacidad (placeholder)
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Privacidad y Seguridad',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.privacy_tip, color: colorScheme.primary),
            title: Text(
              'Privacidad',
              style: TextStyle(color: colorScheme.onSurface),
            ),
            subtitle: Text(
              'Configurar opciones de privacidad',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PrivacySecurityScreen(),
                ),
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.security, color: colorScheme.primary),
            title: Text(
              'Seguridad',
              style: TextStyle(color: colorScheme.onSurface),
            ),
            subtitle: Text(
              'Gestionar opciones de seguridad',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PrivacySecurityScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
