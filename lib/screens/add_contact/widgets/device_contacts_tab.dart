import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../services/device_contacts_service.dart';
import '../../../services/permission_service.dart';

/// Tab para importar contactos del dispositivo
class DeviceContactsTab extends StatefulWidget {
  const DeviceContactsTab({super.key});

  @override
  State<DeviceContactsTab> createState() => _DeviceContactsTabState();
}

class _DeviceContactsTabState extends State<DeviceContactsTab> {
  final DeviceContactsService _deviceContacts = DeviceContactsService();
  final PermissionService _permissionService = PermissionService();

  bool _isLoading = false;
  bool _hasPermission = false;
  List<RegisteredContact> _registeredContacts = [];
  String? _errorMessage;
  ContactsImportResult? _result;

  @override
  void initState() {
    super.initState();
    _checkAndRequestPermission();
  }

  Future<void> _checkAndRequestPermission() async {
    setState(() {
      _isLoading = true;
    });

    // Verificar si ya tiene permiso
    final hasPermission = await _deviceContacts.hasPermission();

    if (hasPermission) {
      setState(() {
        _hasPermission = true;
      });
      await _loadContacts();
    } else {
      // Solicitar permiso automáticamente usando el servicio nativo
      final granted = await _deviceContacts.requestPermission();

      if (granted) {
        setState(() {
          _hasPermission = true;
        });
        await _loadContacts();
      } else {
        setState(() {
          _hasPermission = false;
          _isLoading = false;
          _errorMessage = 'Permiso de contactos denegado';
        });
      }
    }
  }

  Future<void> _loadContacts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _deviceContacts.getContactsWithStats();

      setState(() {
        _result = result;
        _registeredContacts = result.registeredContacts;
        _isLoading = false;

        if (!result.success) {
          _errorMessage = result.error ?? 'Error desconocido';
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error cargando contactos: $e';
        _isLoading = false;
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return _buildLoading();
    }

    if (_errorMessage != null) {
      return _buildError(colorScheme);
    }

    if (_registeredContacts.isEmpty) {
      return _buildEmptyState(colorScheme);
    }

    return _buildContactsList(colorScheme);
  }


  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Buscando contactos...',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ColorScheme colorScheme) {
    final isPermissionError = _errorMessage?.contains('denegado') ?? false;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPermissionError ? Icons.block : Icons.error_outline,
              size: 80,
              color: Colors.red.withValues(alpha: 0.5),
            ),
            SizedBox(height: 24),
            Text(
              isPermissionError ? 'Permiso Denegado' : 'Error',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text(
              isPermissionError
                  ? 'Para ver tus contactos que usan Talia, necesitas habilitar el permiso de contactos en la configuración.'
                  : _errorMessage!,
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 32),
            if (isPermissionError)
              ElevatedButton.icon(
                onPressed: () async {
                  await _permissionService.openSettings();
                },
                icon: Icon(Icons.settings),
                label: Text('Abrir Configuración'),
              )
            else
              ElevatedButton(
                onPressed: _checkAndRequestPermission,
                child: Text('Reintentar'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person_search,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.5),
            ),
            SizedBox(height: 24),
            Text(
              'No hay contactos en Talia',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text(
              _result != null
                  ? 'Tienes ${_result!.contactsWithPhone} contactos con teléfono, pero ninguno está registrado en Talia aún.'
                  : 'Ninguno de tus contactos está usando Talia todavía.',
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 32),
            OutlinedButton(
              onPressed: _checkAndRequestPermission,
              child: Text('Actualizar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsList(ColorScheme colorScheme) {
    return Column(
      children: [
        // Header con estadísticas
        if (_result != null)
          Container(
            padding: EdgeInsets.all(16),
            color: colorScheme.primaryContainer,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStat(
                  'Contactos',
                  _result!.totalDeviceContacts.toString(),
                  Icons.contacts,
                ),
                _buildStat(
                  'Con Teléfono',
                  _result!.contactsWithPhone.toString(),
                  Icons.phone,
                ),
                _buildStat(
                  'En Talia',
                  _result!.registeredCount.toString(),
                  Icons.check_circle,
                  color: Colors.green,
                ),
              ],
            ),
          ),

        // Lista de contactos
        Expanded(
          child: ListView.builder(
            itemCount: _registeredContacts.length,
            itemBuilder: (context, index) {
              final contact = _registeredContacts[index];
              return _buildContactItem(contact, colorScheme);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStat(String label, String value, IconData icon, {Color? color}) {
    return Column(
      children: [
        Icon(icon, color: color),
        SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildContactItem(RegisteredContact contact, ColorScheme colorScheme) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: contact.photoUrl != null
            ? CircleAvatar(
                backgroundImage: CachedNetworkImageProvider(contact.photoUrl!),
              )
            : CircleAvatar(
                child: Text(contact.displayName[0].toUpperCase()),
              ),
        title: Text(
          contact.displayName,
          style: TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(contact.phone),
            SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  contact.isParent ? Icons.supervisor_account : Icons.person,
                  size: 14,
                  color: Colors.grey[600],
                ),
                SizedBox(width: 4),
                Text(
                  contact.isParent ? 'Adulto' : 'Usuario',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ],
        ),
        trailing: Icon(
          Icons.check_circle,
          color: Colors.green,
        ),
        isThreeLine: true,
      ),
    );
  }
}
