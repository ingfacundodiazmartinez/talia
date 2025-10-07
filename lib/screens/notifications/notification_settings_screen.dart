import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/notification_preferences_service.dart';
import 'do_not_disturb_settings_screen.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  final NotificationPreferencesService _prefsService =
      NotificationPreferencesService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isParent = false;

  @override
  void initState() {
    super.initState();
    _checkUserRole();
  }

  Future<void> _checkUserRole() async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(_auth.currentUser?.uid)
          .get();

      if (doc.exists) {
        final role = doc.data()?['role'] ?? 'child';
        setState(() {
          _isParent = role == 'parent';
        });
      }
    } catch (e) {
      print('Error checking user role: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('Configuración de Notificaciones')),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: _prefsService.preferencesStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(color: colorScheme.primary),
            );
          }

          final prefs = snapshot.data!;

          return ListView(
            padding: EdgeInsets.all(20),
            children: [
              // Sección: Tipos de Notificaciones
              _buildSectionTitle('Tipos de Notificaciones', colorScheme),
              SizedBox(height: 12),

              _buildSwitchOption(
                icon: Icons.message,
                title: 'Mensajes Nuevos',
                subtitle: 'Recibir notificación cuando llegue un mensaje',
                value: prefs['messagesEnabled'] ?? true,
                onChanged: (value) => _updatePref('messagesEnabled', value),
                colorScheme: colorScheme,
              ),

              _buildSwitchOption(
                icon: Icons.person_add,
                title: 'Solicitudes de Contacto',
                subtitle: _isParent
                    ? 'Cuando un contacto solicita permiso para chatear'
                    : 'Cuando un padre aprueba o rechaza una solicitud',
                value: prefs['contactRequestsEnabled'] ?? true,
                onChanged: (value) =>
                    _updatePref('contactRequestsEnabled', value),
                colorScheme: colorScheme,
              ),

              if (_isParent)
                _buildSwitchOption(
                  icon: Icons.warning,
                  title: 'Alertas de Actividad',
                  subtitle:
                      'Cuando el hijo intenta contactar a alguien no aprobado',
                  value: prefs['activityAlertsEnabled'] ?? true,
                  onChanged: (value) =>
                      _updatePref('activityAlertsEnabled', value),
                  colorScheme: colorScheme,
                ),

              _buildSwitchOption(
                icon: Icons.phone_missed,
                title: 'Llamadas Perdidas',
                subtitle: 'Notificación de videollamadas perdidas',
                value: prefs['missedCallsEnabled'] ?? true,
                onChanged: (value) => _updatePref('missedCallsEnabled', value),
                colorScheme: colorScheme,
              ),

              if (_isParent)
                _buildSwitchOption(
                  icon: Icons.checklist,
                  title: 'Cambios en Lista Blanca',
                  subtitle: 'Cuando el hijo aprueba o rechaza contactos',
                  value: prefs['whitelistChangesEnabled'] ?? true,
                  onChanged: (value) =>
                      _updatePref('whitelistChangesEnabled', value),
                  colorScheme: colorScheme,
                ),

              SizedBox(height: 32),

              // Sección: Sonido y Vibración
              _buildSectionTitle('Sonido y Vibración', colorScheme),
              SizedBox(height: 12),

              _buildSwitchOption(
                icon: Icons.volume_up,
                title: 'Sonido de Notificación',
                subtitle: 'Reproducir sonido al recibir notificaciones',
                value: prefs['soundEnabled'] ?? true,
                onChanged: (value) => _updatePref('soundEnabled', value),
                colorScheme: colorScheme,
              ),

              _buildSwitchOption(
                icon: Icons.vibration,
                title: 'Vibración',
                subtitle: 'Vibrar al recibir notificaciones',
                value: prefs['vibrationEnabled'] ?? true,
                onChanged: (value) => _updatePref('vibrationEnabled', value),
                colorScheme: colorScheme,
              ),

              _buildSwitchOption(
                icon: Icons.music_note,
                title: 'Sonido en la App',
                subtitle:
                    'Reproducir sonido cuando recibes mensaje dentro de la app',
                value: prefs['inAppSoundEnabled'] ?? true,
                onChanged: (value) => _updatePref('inAppSoundEnabled', value),
                colorScheme: colorScheme,
              ),

              SizedBox(height: 32),

              // Sección: No Molestar
              _buildSectionTitle('No Molestar', colorScheme),
              SizedBox(height: 12),

              _buildNavigationOption(
                icon: Icons.do_not_disturb,
                title: 'Configurar No Molestar',
                subtitle: prefs['doNotDisturbEnabled'] ?? false
                    ? 'Activado (${prefs['dndStartTime']} - ${prefs['dndEndTime']})'
                    : 'Desactivado',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          DoNotDisturbSettingsScreen(preferences: prefs),
                    ),
                  );
                },
                colorScheme: colorScheme,
              ),

              SizedBox(height: 32),

              // Información adicional
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue, size: 24),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Las notificaciones te ayudan a estar al tanto de la actividad importante. Puedes personalizar qué tipos de notificaciones deseas recibir.',
                        style: TextStyle(fontSize: 13, color: Colors.blue[800]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionTitle(String title, ColorScheme colorScheme) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: colorScheme.onSurface,
      ),
    );
  }

  Widget _buildSwitchOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Function(bool) onChanged,
    required ColorScheme colorScheme,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        secondary: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: colorScheme.primary, size: 24),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        value: value,
        onChanged: onChanged,
        activeColor: colorScheme.primary,
      ),
    );
  }

  Widget _buildNavigationOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required ColorScheme colorScheme,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: colorScheme.primary, size: 24),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Future<void> _updatePref(String key, dynamic value) async {
    try {
      await _prefsService.updatePreference(key, value);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Preferencia actualizada'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al actualizar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
