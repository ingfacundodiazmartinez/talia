import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../services/child_contacts_management_service.dart';
import '../../../utils/release_logger.dart';

/// Pantalla que muestra los contactos de un hijo específico
///
/// Permite al padre:
/// - Ver contactos aprobados y pendientes del hijo
/// - Aprobar contactos pendientes
/// - Eliminar contactos (también elimina el chat asociado)
///
/// SEGURIDAD: El padre NO puede iniciar chat con los contactos del hijo
/// (solo puede chatear con sus propios contactos)
class ChildContactsFilterScreen extends StatefulWidget {
  final String childId;
  final String childName;

  const ChildContactsFilterScreen({
    super.key,
    required this.childId,
    required this.childName,
  });

  @override
  State<ChildContactsFilterScreen> createState() => _ChildContactsFilterScreenState();
}

class _ChildContactsFilterScreenState extends State<ChildContactsFilterScreen> {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final ChildContactsManagementService _contactsService = ChildContactsManagementService();
  String _searchQuery = '';
  bool _isLoading = false;
  bool _isLoadingContacts = true;
  List<Map<String, dynamic>> _contacts = [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  /// Asegurar que linkedChildrenIds contenga el childId usando Cloud Function
  /// La Cloud Function tiene privilegios admin para actualizar el campo
  Future<bool> _ensureLinkedChildrenIds() async {
    try {
      ReleaseLogger.log('🔧 Verificando linkedChildrenIds via Cloud Function...', tag: 'ChildContactsFilter');

      // Timeout de 10 segundos para evitar spinner infinito
      final result = await _functions
          .httpsCallable('ensureLinkedChildrenIds')
          .call({'childId': widget.childId})
          .timeout(
            Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout verificando vínculo'),
          );

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] == true;

      if (success) {
        if (data['alreadyConfigured'] == true) {
          ReleaseLogger.log('✅ linkedChildrenIds ya configurado', tag: 'ChildContactsFilter');
        } else if (data['repaired'] == true) {
          ReleaseLogger.log('✅ linkedChildrenIds reparado exitosamente', tag: 'ChildContactsFilter');
        }
        return true;
      }

      return false;
    } catch (e) {
      ReleaseLogger.error('Error en ensureLinkedChildrenIds: $e', tag: 'ChildContactsFilter');
      // En caso de error, intentar continuar sin verificación
      // El query a Firestore fallará si no hay permisos
      return true;
    }
  }

  /// Cargar contactos usando query directo de Firestore (más rápido)
  Future<void> _loadContacts() async {
    if (!mounted) return;

    setState(() {
      _isLoadingContacts = true;
      _loadError = null;
    });

    try {
      ReleaseLogger.log('📋 Cargando contactos de ${widget.childName}', tag: 'ChildContactsFilter');

      // 1. Asegurar que linkedChildrenIds esté configurado
      final hasPermission = await _ensureLinkedChildrenIds();
      if (!hasPermission) {
        throw Exception('No se pudo verificar el vínculo padre-hijo. Intenta de nuevo.');
      }

      // 2. Obtener contactos via servicio
      final contacts = await _contactsService.getChildContacts(widget.childId)
          .timeout(
            Duration(seconds: 15),
            onTimeout: () => throw Exception('Timeout cargando contactos'),
          );

      if (!mounted) return;

      ReleaseLogger.log('✅ Cargados ${contacts.length} contactos', tag: 'ChildContactsFilter');

      if (mounted) {
        setState(() {
          _contacts = contacts;
          _isLoadingContacts = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error cargando contactos: $e', tag: 'ChildContactsFilter');
      if (mounted) {
        setState(() {
          _loadError = e.toString();
          _isLoadingContacts = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Contactos de ${widget.childName}'),
        backgroundColor: ThemeService.primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _isLoadingContacts ? null : _loadContacts,
            icon: _isLoadingContacts
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(Icons.refresh),
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: Column(
        children: [
          // Barra de búsqueda
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: TextField(
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.toLowerCase();
                });
              },
              decoration: InputDecoration(
                hintText: 'Buscar contactos...',
                prefixIcon: Icon(Icons.search, color: ThemeService.primaryColor),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear),
                        onPressed: () {
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // Lista de contactos
          Expanded(
            child: _buildContactsList(),
          ),
        ],
      ),
    );
  }

  Widget _buildContactsList() {
    if (_isLoadingContacts) {
      return Center(
        child: CircularProgressIndicator(
          color: ThemeService.primaryColor,
        ),
      );
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red),
            SizedBox(height: 16),
            Text('Error al cargar contactos'),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _loadError!,
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadContacts,
              icon: Icon(Icons.refresh),
              label: Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    // Filtrar solo approved y pending
    final filteredByStatus = _contacts.where((contact) {
      final status = contact['status'] as String? ?? '';
      return status == 'approved' || status == 'pending';
    }).toList();

    if (filteredByStatus.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: Colors.grey,
            ),
            SizedBox(height: 16),
            Text(
              '${widget.childName} no tiene contactos aún',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      );
    }

    // Filtrar por búsqueda
    final filteredContacts = filteredByStatus.where((contact) {
      final name = (contact['contactName'] as String? ?? contact['name'] as String? ?? '').toLowerCase();
      return name.contains(_searchQuery);
    }).toList();

    // Ordenar: primero pendientes, luego por nombre
    filteredContacts.sort((a, b) {
      final aIsPending = a['status'] == 'pending';
      final bIsPending = b['status'] == 'pending';
      if (aIsPending && !bIsPending) return -1;
      if (!aIsPending && bIsPending) return 1;
      final aName = a['contactName'] as String? ?? a['name'] as String? ?? '';
      final bName = b['contactName'] as String? ?? b['name'] as String? ?? '';
      return aName.compareTo(bName);
    });

    if (filteredContacts.isEmpty && _searchQuery.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: Colors.grey,
            ),
            SizedBox(height: 16),
            Text(
              'No se encontraron contactos',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadContacts,
      color: ThemeService.primaryColor,
      child: ListView.builder(
        padding: EdgeInsets.all(16),
        itemCount: filteredContacts.length,
        itemBuilder: (context, index) {
          final contact = filteredContacts[index];
          return _buildContactCard(contact);
        },
      ),
    );
  }

  Widget _buildContactCard(Map<String, dynamic> contact) {
    final isPending = contact['status'] == 'pending';
    final contactUserId = contact['contactId'] as String? ?? '';
    final chatId = contact['chatId'] as String? ?? '';
    final contactName = contact['name'] as String? ?? 'Usuario';

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isPending
            ? BorderSide(color: Colors.orange, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            // Avatar
            CircleAvatar(
              radius: 28,
              backgroundColor: ThemeService.primaryColor.withValues(alpha: 0.1),
              backgroundImage: contact['photoURL'] != null
                  ? CachedNetworkImageProvider(contact['photoURL'])
                  : null,
              child: contact['photoURL'] == null
                  ? Text(
                      _getInitials(contactName),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: ThemeService.primaryColor,
                      ),
                    )
                  : null,
            ),
            SizedBox(width: 12),
            // Nombre y estado
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contactName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 4),
                  if (isPending)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Pendiente de aprobación',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange[800],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  else
                    Text(
                      'Contacto aprobado',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                      ),
                    ),
                ],
              ),
            ),
            // Botones de acción
            if (isPending) ...[
              // Botón aprobar
              IconButton(
                icon: Icon(Icons.check_circle, color: Colors.green, size: 28),
                tooltip: 'Aprobar contacto',
                onPressed: _isLoading ? null : () => _approveContact(chatId, contactUserId, contactName),
              ),
              // Botón rechazar
              IconButton(
                icon: Icon(Icons.cancel, color: Colors.red, size: 28),
                tooltip: 'Rechazar contacto',
                onPressed: _isLoading ? null : () => _deleteContact(chatId, contactUserId, contactName),
              ),
            ] else ...[
              // Botón eliminar
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.red),
                tooltip: 'Eliminar contacto',
                onPressed: _isLoading ? null : () => _deleteContact(chatId, contactUserId, contactName),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Aprobar un contacto pendiente
  Future<void> _approveContact(String chatId, String contactUserId, String contactName) async {
    ReleaseLogger.log('🔄 [ApproveContact] Iniciando aprobación de $contactName (childId: ${widget.childId}, contactId: $contactUserId)', tag: 'ChildContactsFilter');

    try {
      setState(() => _isLoading = true);

      // Buscar el contactDocId usando childId y contactUserId
      final users = [widget.childId, contactUserId]..sort();
      final contactDocId = '${users[0]}_${users[1]}';

      ReleaseLogger.log('📤 [ApproveContact] Llamando CF updateContactStatus con contactDocId: $contactDocId', tag: 'ChildContactsFilter');

      // Usar Cloud Function para aprobar el contacto
      // La Cloud Function actualiza el status y el mapa de approvals
      final result = await _functions.httpsCallable('updateContactStatus').call({
        'contactDocId': contactDocId,
        'status': 'approved',
      });

      ReleaseLogger.log('✅ [ApproveContact] CF respondió: ${result.data}', tag: 'ChildContactsFilter');

      // Recargar contactos
      await _loadContacts();
    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [ApproveContact] Error: $e', tag: 'ChildContactsFilter');
      ReleaseLogger.error('❌ [ApproveContact] StackTrace: $stackTrace', tag: 'ChildContactsFilter');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al aprobar contacto: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Eliminar un contacto (y el chat asociado)
  Future<void> _deleteContact(String chatId, String contactUserId, String contactName) async {
    setState(() => _isLoading = true);

    try {
      // Buscar el contactDocId usando childId y contactUserId
      final users = [widget.childId, contactUserId]..sort();
      final contactDocId = '${users[0]}_${users[1]}';

      // Buscar grupos donde ambos (hijo y contacto) son miembros
      final sharedGroups = await _contactsService.getSharedGroups(
        childId: widget.childId,
        contactId: contactUserId,
      );

      if (!mounted) return;

      // Mostrar dialog de confirmación con info de grupos compartidos
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Eliminar contacto'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '¿Estás seguro de eliminar a $contactName de los contactos de ${widget.childName}?',
              ),
              SizedBox(height: 12),
              Text(
                '• Se eliminará el historial de chat entre ellos.',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
              if (sharedGroups.isNotEmpty) ...[
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber, color: Colors.orange.shade700, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${widget.childName} será removido de ${sharedGroups.length} grupo(s):',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Colors.orange.shade800,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      ...sharedGroups.map((group) {
                        final groupName = group.data()['name'] ?? 'Grupo sin nombre';
                        return Padding(
                          padding: EdgeInsets.only(left: 28, bottom: 4),
                          child: Text(
                            '• $groupName',
                            style: TextStyle(fontSize: 13, color: Colors.orange.shade900),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text('Eliminar'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      // Eliminar contacto (cambiar status a deleted) via Cloud Function
      // El trigger invalidateChatOnContactDelete se encarga de invalidar el chat automáticamente
      await _functions.httpsCallable('updateContactStatus').call({
        'contactDocId': contactDocId,
        'status': 'deleted',
      });

      // Remover al hijo de los grupos compartidos
      await _contactsService.removeChildFromGroups(
        groups: sharedGroups,
        childId: widget.childId,
      );

      // Recargar contactos
      await _loadContacts();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar contacto: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _getInitials(String name) {
    if (name.isEmpty) return 'U';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}
