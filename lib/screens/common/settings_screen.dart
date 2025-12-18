import 'package:flutter/material.dart';
import 'privacy_security_screen.dart';
import '../../screens/notifications/notification_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Configuración'),
      ),
      body: ListView(
        children: [
          // Sección de Notificaciones
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
              Navigator.of(context).push(
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
              Navigator.of(context).push(
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
              Navigator.of(context).push(
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
