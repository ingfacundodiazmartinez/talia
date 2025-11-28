import 'package:flutter/material.dart';
import '../../services/notification_preferences_service.dart';

/// Pantalla de configuración de notificaciones
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  final _service = NotificationPreferencesService();
  Map<String, dynamic> _preferences = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await _service.getPreferences();
    setState(() {
      _preferences = prefs;
      _loading = false;
    });
  }

  Future<void> _updatePreference(String key, dynamic value) async {
    try {
      await _service.updatePreference(key, value);
      setState(() {
        _preferences[key] = value;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preferencia actualizada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _configureDndSchedule() async {
    final startTime = _service.parseTime(_preferences['dndStartTime']);
    final endTime = _service.parseTime(_preferences['dndEndTime']);

    final TimeOfDay? pickedStart = await showTimePicker(
      context: context,
      initialTime: startTime,
      helpText: 'Hora de inicio',
    );

    if (pickedStart == null) return;

    if (!mounted) return;

    final TimeOfDay? pickedEnd = await showTimePicker(
      context: context,
      initialTime: endTime,
      helpText: 'Hora de fin',
    );

    if (pickedEnd == null) return;

    final startStr =
        '${pickedStart.hour.toString().padLeft(2, '0')}:${pickedStart.minute.toString().padLeft(2, '0')}';
    final endStr =
        '${pickedEnd.hour.toString().padLeft(2, '0')}:${pickedEnd.minute.toString().padLeft(2, '0')}';

    await _service.updateMultiplePreferences({
      'dndStartTime': startStr,
      'dndEndTime': endStr,
    });

    await _loadPreferences();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notificaciones')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notificaciones'),
      ),
      body: ListView(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            child: Row(
              children: [
                const Icon(Icons.notifications, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Configuración de Notificaciones',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Personaliza cómo y cuándo recibir notificaciones',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Tipos de notificaciones
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Tipos de Notificaciones',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.message),
            title: const Text('Mensajes'),
            subtitle: const Text('Recibir notificaciones de nuevos mensajes'),
            value: _preferences['messagesEnabled'] ?? true,
            onChanged: (value) => _updatePreference('messagesEnabled', value),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.call),
            title: const Text('Llamadas Perdidas'),
            subtitle:
                const Text('Notificar cuando pierdes una videollamada'),
            value: _preferences['missedCallsEnabled'] ?? true,
            onChanged: (value) =>
                _updatePreference('missedCallsEnabled', value),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.person_add),
            title: const Text('Solicitudes de Contacto'),
            subtitle: const Text('Nuevas solicitudes de contacto'),
            value: _preferences['contactRequestsEnabled'] ?? true,
            onChanged: (value) =>
                _updatePreference('contactRequestsEnabled', value),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.emergency),
            title: const Text('Alertas de Actividad'),
            subtitle: const Text('Actividad importante de tus contactos'),
            value: _preferences['activityAlertsEnabled'] ?? true,
            onChanged: (value) =>
                _updatePreference('activityAlertsEnabled', value),
          ),

          const Divider(),

          // Sonido y Vibración
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Sonido y Vibración',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.volume_up),
            title: const Text('Sonido'),
            subtitle: const Text('Reproducir sonido para notificaciones'),
            value: _preferences['soundEnabled'] ?? true,
            onChanged: (value) => _updatePreference('soundEnabled', value),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.vibration),
            title: const Text('Vibración'),
            subtitle: const Text('Vibrar al recibir notificaciones'),
            value: _preferences['vibrationEnabled'] ?? true,
            onChanged: (value) => _updatePreference('vibrationEnabled', value),
          ),

          const Divider(),

          // No Molestar
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No Molestar',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.do_not_disturb),
            title: const Text('Modo No Molestar'),
            subtitle: Text(
              _preferences['doNotDisturbEnabled'] ?? false
                  ? 'Activo de ${_preferences['dndStartTime']} a ${_preferences['dndEndTime']}'
                  : 'Silenciar notificaciones en horario específico',
            ),
            value: _preferences['doNotDisturbEnabled'] ?? false,
            onChanged: (value) =>
                _updatePreference('doNotDisturbEnabled', value),
          ),

          if (_preferences['doNotDisturbEnabled'] ?? false)
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Horario No Molestar'),
              subtitle: Text(
                'De ${_preferences['dndStartTime']} a ${_preferences['dndEndTime']}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _configureDndSchedule,
            ),

          const Divider(),

          // Información adicional
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sobre las Notificaciones',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  '• Las emergencias siempre notifican, incluso en modo No Molestar',
                ),
                const Text(
                  '• Puedes silenciar chats individuales desde el chat',
                ),
                const Text(
                  '• Los sonidos se reproducen según la configuración de tu dispositivo',
                ),
                const SizedBox(height: 16),
                Text(
                  'Prioridades',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Crítico - Emergencias'),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Alta - Llamadas'),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Normal - Mensajes'),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Baja - Actualizaciones'),
                  ],
                ),
              ],
            ),
          ),

          // Botón de prueba
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.notifications_active),
              label: const Text('Enviar Notificación de Prueba'),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Funcionalidad en desarrollo'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
