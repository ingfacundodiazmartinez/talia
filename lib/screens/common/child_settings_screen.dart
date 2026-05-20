import 'package:flutter/material.dart';
import '../../services/user_settings_service.dart';

class ChildSettingsScreen extends StatefulWidget {
  const ChildSettingsScreen({super.key});

  @override
  State<ChildSettingsScreen> createState() => _ChildSettingsScreenState();
}

class _ChildSettingsScreenState extends State<ChildSettingsScreen> {
  final UserSettingsService _settingsService = UserSettingsService();

  bool _notificationsEnabled = true;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  bool _showOnlineStatus = false; // Default OFF para menores (privacidad)

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final data = await _settingsService.loadSettings();
      if (data.isNotEmpty) {
        setState(() {
          _notificationsEnabled = data['notificationsEnabled'] ?? true;
          _soundEnabled = data['soundEnabled'] ?? true;
          _vibrationEnabled = data['vibrationEnabled'] ?? true;
          _showOnlineStatus = data['showOnlineStatus'] ?? false;
        });
      }
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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Configuración'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Notificaciones
          Text(
            'Notificaciones',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),

          _buildSwitchOption(
            context: context,
            icon: Icons.notifications,
            title: 'Notificaciones',
            subtitle: 'Recibir alertas de mensajes',
            value: _notificationsEnabled,
            onChanged: (value) {
              setState(() => _notificationsEnabled = value);
              _updateSetting('notificationsEnabled', value);
            },
          ),

          _buildSwitchOption(
            context: context,
            icon: Icons.volume_up,
            title: 'Sonido',
            subtitle: 'Sonidos de notificación',
            value: _soundEnabled,
            onChanged: (value) {
              setState(() => _soundEnabled = value);
              _updateSetting('soundEnabled', value);
            },
          ),

          _buildSwitchOption(
            context: context,
            icon: Icons.vibration,
            title: 'Vibración',
            subtitle: 'Vibrar al recibir mensajes',
            value: _vibrationEnabled,
            onChanged: (value) {
              setState(() => _vibrationEnabled = value);
              _updateSetting('vibrationEnabled', value);
            },
          ),

          SizedBox(height: 32),

          // Privacidad
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
            context: context,
            icon: Icons.visibility,
            title: 'Mostrar Estado',
            subtitle: 'Otros pueden ver cuando estás en línea',
            value: _showOnlineStatus,
            onChanged: (value) {
              setState(() => _showOnlineStatus = value);
              _updateSetting('showOnlineStatus', value);
            },
          ),

          SizedBox(height: 32),

          // Información
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: colorScheme.primary,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Algunos ajustes pueden ser controlados por tus padres',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSwitchOption({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Function(bool) onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDarkMode
            ? colorScheme.surfaceContainerHighest
            : colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        secondary: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
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
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        activeThumbColor: colorScheme.primary,
      ),
    );
  }

}
