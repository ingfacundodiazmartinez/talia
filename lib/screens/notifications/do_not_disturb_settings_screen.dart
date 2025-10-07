import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/notification_preferences_service.dart';

class DoNotDisturbSettingsScreen extends StatefulWidget {
  final Map<String, dynamic> preferences;

  const DoNotDisturbSettingsScreen({super.key, required this.preferences});

  @override
  State<DoNotDisturbSettingsScreen> createState() =>
      _DoNotDisturbSettingsScreenState();
}

class _DoNotDisturbSettingsScreenState
    extends State<DoNotDisturbSettingsScreen> {
  final NotificationPreferencesService _prefsService =
      NotificationPreferencesService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  late bool _dndEnabled;
  late String _startTime;
  late String _endTime;
  late List<String> _exceptions;

  @override
  void initState() {
    super.initState();
    _dndEnabled = widget.preferences['doNotDisturbEnabled'] ?? false;
    _startTime = widget.preferences['dndStartTime'] ?? '22:00';
    _endTime = widget.preferences['dndEndTime'] ?? '07:00';
    _exceptions = List<String>.from(widget.preferences['dndExceptions'] ?? []);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('No Molestar')),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Activar/Desactivar No Molestar
          Container(
            margin: EdgeInsets.only(bottom: 24),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SwitchListTile(
              secondary: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _dndEnabled
                      ? colorScheme.primary.withValues(alpha: 0.1)
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.do_not_disturb,
                  color: _dndEnabled
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  size: 24,
                ),
              ),
              title: Text(
                'Modo No Molestar',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                _dndEnabled
                    ? 'Las notificaciones estarán silenciadas'
                    : 'Activar para silenciar notificaciones en horarios específicos',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              value: _dndEnabled,
              onChanged: (value) async {
                setState(() => _dndEnabled = value);
                await _saveSettings();
              },
              activeColor: colorScheme.primary,
            ),
          ),

          if (_dndEnabled) ...[
            // Sección: Horario
            Text(
              'Horario',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 12),

            // Hora de inicio
            _buildTimeOption(
              icon: Icons.bedtime,
              title: 'Hora de Inicio',
              time: _startTime,
              onTap: () => _selectTime(true),
              colorScheme: colorScheme,
            ),

            // Hora de fin
            _buildTimeOption(
              icon: Icons.wb_sunny,
              title: 'Hora de Fin',
              time: _endTime,
              onTap: () => _selectTime(false),
              colorScheme: colorScheme,
            ),

            SizedBox(height: 24),

            // Sección: Excepciones
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Excepciones',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                TextButton.icon(
                  onPressed: _showAddExceptionDialog,
                  icon: Icon(Icons.add, size: 20),
                  label: Text('Agregar'),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),

            if (_exceptions.isEmpty)
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.person_off,
                        size: 48,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Sin excepciones',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Agrega contactos que puedan notificarte incluso en modo No Molestar',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ..._exceptions.map((contactId) {
                return FutureBuilder<DocumentSnapshot>(
                  future: _firestore.collection('users').doc(contactId).get(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return SizedBox();

                    final userData =
                        snapshot.data!.data() as Map<String, dynamic>?;
                    final name = userData?['name'] ?? 'Usuario';
                    final photoURL = userData?['photoURL'];

                    return Container(
                      margin: EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: colorScheme.primary.withValues(
                            alpha: 0.2,
                          ),
                          backgroundImage:
                              photoURL != null && photoURL.isNotEmpty
                              ? NetworkImage(photoURL)
                              : null,
                          child: photoURL == null || photoURL.isEmpty
                              ? Text(
                                  name[0].toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(
                          name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          'Puede notificarte siempre',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.close, color: Colors.red),
                          onPressed: () => _removeException(contactId),
                        ),
                      ),
                    );
                  },
                );
              }).toList(),

            SizedBox(height: 24),

            // Información
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
                      'Durante el modo No Molestar, no recibirás notificaciones excepto de los contactos en la lista de excepciones.',
                      style: TextStyle(fontSize: 13, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimeOption({
    required IconData icon,
    required String title,
    required String time,
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              time,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
            SizedBox(width: 8),
            Icon(
              Icons.access_time,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Future<void> _selectTime(bool isStartTime) async {
    final currentTime = isStartTime ? _startTime : _endTime;
    final parts = currentTime.split(':');
    final initialTime = TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );

    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return Theme(data: Theme.of(context), child: child!);
      },
    );

    if (picked != null) {
      final formattedTime =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';

      setState(() {
        if (isStartTime) {
          _startTime = formattedTime;
        } else {
          _endTime = formattedTime;
        }
      });

      await _saveSettings();
    }
  }

  Future<void> _showAddExceptionDialog() async {
    // Obtener contactos aprobados del usuario
    final contacts = await _getApprovedContacts();

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No tienes contactos aprobados'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Filtrar contactos que ya están en excepciones
    final availableContacts = contacts
        .where((contact) => !_exceptions.contains(contact['id']))
        .toList();

    if (availableContacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Todos tus contactos ya están en excepciones'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Agregar Excepción',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Selecciona un contacto que pueda notificarte durante el modo No Molestar:',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: 16),
            Container(
              constraints: BoxConstraints(maxHeight: 300),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: availableContacts.length,
                itemBuilder: (context, index) {
                  final contact = availableContacts[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: colorScheme.primary.withValues(
                        alpha: 0.2,
                      ),
                      backgroundImage:
                          contact['photoURL'] != null &&
                              contact['photoURL'].isNotEmpty
                          ? NetworkImage(contact['photoURL'])
                          : null,
                      child:
                          contact['photoURL'] == null ||
                              contact['photoURL'].isEmpty
                          ? Text(
                              contact['name'][0].toUpperCase(),
                              style: TextStyle(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                    title: Text(
                      contact['name'],
                      style: TextStyle(color: colorScheme.onSurface),
                    ),
                    onTap: () {
                      _addException(contact['id']);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _getApprovedContacts() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return [];

      // Obtener contactos aprobados
      final contactsSnapshot = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .where('status', isEqualTo: 'approved')
          .get();

      final List<Map<String, dynamic>> contacts = [];

      for (var doc in contactsSnapshot.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);
        final otherUserId = users.firstWhere(
          (id) => id != userId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) continue;

        // Obtener datos del usuario
        final userDoc = await _firestore
            .collection('users')
            .doc(otherUserId)
            .get();

        if (userDoc.exists) {
          final userData = userDoc.data()!;
          contacts.add({
            'id': otherUserId,
            'name': userData['name'] ?? 'Usuario',
            'photoURL': userData['photoURL'],
          });
        }
      }

      return contacts;
    } catch (e) {
      print('Error getting contacts: $e');
      return [];
    }
  }

  Future<void> _addException(String contactId) async {
    setState(() {
      _exceptions.add(contactId);
    });
    await _saveSettings();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Excepción agregada'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _removeException(String contactId) async {
    setState(() {
      _exceptions.remove(contactId);
    });
    await _saveSettings();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Excepción eliminada'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveSettings() async {
    try {
      await _prefsService.updateMultiplePreferences({
        'doNotDisturbEnabled': _dndEnabled,
        'dndStartTime': _startTime,
        'dndEndTime': _endTime,
        'dndExceptions': _exceptions,
      });
    } catch (e) {
      print('Error saving settings: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al guardar configuración'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
