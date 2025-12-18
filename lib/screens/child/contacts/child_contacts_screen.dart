import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../controllers/child_contacts_controller.dart';
import '../../../models/contact.dart' as contact_model;
import '../../../screens/add_contact_screen.dart';
import '../../../services/create_chat_service.dart';
import '../../../services/contacts_sync_service.dart';
import '../../../services/device_contacts_service.dart';
import '../../../services/phone_normalization_service.dart';
import '../../../widgets/synced_user_widgets.dart';
import '../../../utils/release_logger.dart';
import 'widgets/potential_contact_card.dart';
import 'widgets/potential_contact_sheet.dart';

/// Pantalla de contactos para niños con lista unificada
///
/// Características:
/// - Lista unificada: Aprobados → Pendientes → Rechazados
/// - Búsqueda de contactos en tiempo real
/// - Solicitudes pendientes y rechazadas con acciones
/// - Contactos aprobados con estado en línea
/// - Navegación a chat individual
/// - Soporte completo para tema oscuro
class ChildContactsScreen extends StatefulWidget {
  final String childId;
  final ChildHomeController controller;

  const ChildContactsScreen({
    super.key,
    required this.childId,
    required this.controller,
  });

  @override
  State<ChildContactsScreen> createState() => _ChildContactsScreenState();
}

class _ChildContactsScreenState extends State<ChildContactsScreen> {
  late final ChildContactsController _contactsController;
  String _contactSearchQuery = '';
  bool _isSyncing = false;

  // Cache de contactos del dispositivo para lookup de nombres
  List<Contact>? _deviceContacts;
  final PhoneNormalizationService _phoneNormalizer = PhoneNormalizationService();

  @override
  void initState() {
    super.initState();
    _contactsController = ChildContactsController(childId: widget.childId);
    _contactsController.initialize();
    _loadDeviceContacts();
  }

  /// Cargar contactos del dispositivo para lookup de nombres
  Future<void> _loadDeviceContacts() async {
    try {
      // Verificar permiso primero sin acceder a contactos
      final status = await Permission.contacts.status;
      if (!status.isGranted) {
        return; // No tenemos permiso, no intentar cargar
      }

      final contacts = await DeviceContactsService().getDeviceContacts();
      if (mounted) {
        setState(() {
          _deviceContacts = contacts;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando contactos del dispositivo: $e', tag: 'ChildContacts');
    }
  }

  /// Obtener nombre del contacto desde la agenda del dispositivo
  String _getDeviceContactName(String phoneNumber) {
    if (_deviceContacts == null || phoneNumber.isEmpty) {
      return phoneNumber;
    }

    // Normalizar el número que buscamos
    final normalizedSearch = _phoneNormalizer.normalizePhone(phoneNumber);
    final searchVariations = _phoneNormalizer.generateVariations(phoneNumber);

    for (final contact in _deviceContacts!) {
      for (final phone in contact.phones) {
        final normalizedPhone = _phoneNormalizer.normalizePhone(phone.number);
        if (normalizedPhone == normalizedSearch ||
            searchVariations.contains(normalizedPhone)) {
          return contact.displayName;
        }
      }
    }

    // Si no se encuentra, devolver el número de teléfono formateado
    return phoneNumber;
  }

  /// Solicitar aprobación para un contacto potential
  Future<void> _requestContactApproval(contact_model.Contact contact, String contactName) async {
    final currentUserId = _contactsController.currentUserId;
    if (currentUserId == null) return;

    try {
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('requestContactApproval').call({
        'contactDocId': contact.id,
      });

      if (!mounted) return;

      final resultData = result.data as Map<String, dynamic>;
      final success = resultData['success'] ?? false;
      final newStatus = resultData['newStatus'] ?? '';

      if (success) {
        String message;
        if (newStatus == 'approved') {
          message = '¡Contacto aprobado! Ya puedes chatear con $contactName';
        } else {
          message = 'Solicitud enviada. Tu padre/madre debe aprobarla.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        final errorMessage = resultData['message'] ?? 'Error desconocido';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error solicitando aprobación: $e', tag: 'ChildContacts');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al solicitar aprobación'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _contactsController.dispose();
    super.dispose();
  }

  /// Sincronizar contactos del dispositivo
  Future<void> _syncContacts() async {
    if (_isSyncing) return;

    setState(() => _isSyncing = true);

    try {
      await ContactsSyncService().syncContacts(force: true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contactos sincronizados'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error sincronizando contactos: $e', tag: 'ChildContacts');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al sincronizar contactos'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Mis Contactos'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
        actions: [
          IconButton(
            onPressed: _isSyncing ? null : _syncContacts,
            icon: _isSyncing
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
                    ),
                  )
                : Icon(Icons.refresh),
            tooltip: 'Sincronizar contactos',
          ),
        ],
      ),
      body: Column(
        children: [
          // Buscador
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
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
                  _contactSearchQuery = value.toLowerCase();
                });
              },
              decoration: InputDecoration(
                hintText: 'Buscar contactos...',
                hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                prefixIcon: Icon(Icons.search, color: colorScheme.primary),
                suffixIcon: _contactSearchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: colorScheme.onSurfaceVariant),
                        onPressed: () {
                          setState(() {
                            _contactSearchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: isDarkMode
                    ? colorScheme.surfaceContainerHighest
                    : colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
          // Lista unificada de contactos con múltiples StreamBuilders
          Expanded(
            child: StreamBuilder<List<String>>(
              stream: _contactsController.getBlockedContactsStream(),
              builder: (context, blockedSnapshot) {
                final blockedContacts = blockedSnapshot.data ?? [];

                return StreamBuilder<List<contact_model.Contact>>(
                  // Contactos SUGERIDOS (potential) - descubiertos en sync
                  stream: _contactsController.getPotentialContactsStream(),
                  builder: (context, potentialSnapshot) {
                    return StreamBuilder<List<contact_model.Contact>>(
                      // Contactos donde MI aprobación está pendiente (mis padres deben aprobar)
                      stream: _contactsController.getMyPendingContactsStream(),
                      builder: (context, myPendingSnapshot) {
                        return StreamBuilder<List<contact_model.Contact>>(
                          // Contactos donde el OTRO tiene aprobación pendiente (sus padres deben aprobar)
                          stream: _contactsController.getOtherPendingContactsStream(),
                          builder: (context, otherPendingSnapshot) {
                            return StreamBuilder<List<contact_model.Contact>>(
                              // Contactos RECHAZADOS donde yo soy el child
                              stream: _contactsController.getRejectedContactsStream(),
                              builder: (context, rejectedSnapshot) {
                                return StreamBuilder<List<String>>(
                                  stream: _contactsController.getBidirectionallyApprovedContactsStream(),
                                  builder: (context, approvedSnapshot) {
                                    if (potentialSnapshot.hasError ||
                                        myPendingSnapshot.hasError ||
                                        otherPendingSnapshot.hasError ||
                                        rejectedSnapshot.hasError ||
                                        approvedSnapshot.hasError) {
                                      return Center(
                                        child: Text(
                                          'Error cargando contactos',
                                          style: TextStyle(color: colorScheme.error),
                                        ),
                                      );
                                    }

                                    if (potentialSnapshot.connectionState == ConnectionState.waiting ||
                                        myPendingSnapshot.connectionState == ConnectionState.waiting ||
                                        otherPendingSnapshot.connectionState == ConnectionState.waiting ||
                                        rejectedSnapshot.connectionState == ConnectionState.waiting ||
                                        approvedSnapshot.connectionState == ConnectionState.waiting) {
                                      return Center(
                                        child: CircularProgressIndicator(
                                          color: colorScheme.primary,
                                        ),
                                      );
                                    }

                                    // Obtener contactos sugeridos (potential)
                                    final potentialContacts = potentialSnapshot.data ?? [];

                                    // Combinar todos los contactos pendientes
                                    final allPendingContacts = <contact_model.Contact>[
                                      ...myPendingSnapshot.data ?? [],
                                      ...otherPendingSnapshot.data ?? [],
                                    ];

                                    // Obtener contactos rechazados
                                    final rejectedContacts = rejectedSnapshot.data ?? [];

                                    final hasPotentialContacts = potentialContacts.isNotEmpty;
                                    final hasPendingRequests = allPendingContacts.isNotEmpty;
                                    final hasRejectedRequests = rejectedContacts.isNotEmpty;
                                    final hasApprovedContacts = approvedSnapshot.hasData &&
                                                                approvedSnapshot.data!.isNotEmpty;

                                    if (!hasPotentialContacts && !hasPendingRequests && !hasRejectedRequests && !hasApprovedContacts) {
                                      return _buildEmptyState(colorScheme);
                                    }

                                    return ListView(
                                      padding: EdgeInsets.all(16),
                                      children: [
                                        // 0. Sección de contactos SUGERIDOS (potential) - primero
                                        if (hasPotentialContacts) ...[
                                          _buildSectionHeader(
                                            'Sugeridos',
                                            colorScheme,
                                            icon: Icons.person_add_alt_1,
                                            iconColor: Colors.teal,
                                          ),
                                          SizedBox(height: 12),
                                          ..._buildPotentialContactsList(
                                            potentialContacts,
                                            colorScheme,
                                          ),
                                          SizedBox(height: 24),
                                        ],

                                        // 1. Sección de contactos aprobados
                                        if (hasApprovedContacts) ...[
                                          _buildSectionHeader(
                                            'Contactos',
                                            colorScheme,
                                            icon: Icons.check_circle,
                                            iconColor: Colors.green,
                                          ),
                                          SizedBox(height: 12),
                                          ...approvedSnapshot.data!
                                              .where((contactId) => !blockedContacts.contains(contactId))
                                              .map((contactId) {
                                            return FutureBuilder<DocumentSnapshot>(
                                              future: _contactsController.getUserDocument(contactId),
                                              builder: (context, userSnapshot) {
                                                if (!userSnapshot.hasData) {
                                                  return SizedBox();
                                                }

                                                final userData =
                                                    userSnapshot.data!.data() as Map<String, dynamic>?;
                                                final name = userData?['name'] ?? 'Usuario';
                                                final phone = userData?['phone'] as String? ?? '';
                                                final photoURL = userData?['photoURL'];

                                                // Filtrar por búsqueda
                                                if (_contactSearchQuery.isNotEmpty &&
                                                    !name.toLowerCase().contains(_contactSearchQuery)) {
                                                  return SizedBox();
                                                }

                                                return _buildContactCard(
                                                  contactId: contactId,
                                                  name: name,
                                                  phone: phone,
                                                  photoURL: photoURL,
                                                  colorScheme: colorScheme,
                                                );
                                              },
                                            );
                                          }),
                                          SizedBox(height: 24),
                                        ],

                                        // 2. Sección de contactos pendientes
                                        if (hasPendingRequests) ...[
                                          _buildSectionHeader(
                                            'Pendientes de Aprobación',
                                            colorScheme,
                                            icon: Icons.schedule,
                                            iconColor: Colors.amber.shade600,
                                          ),
                                          SizedBox(height: 12),
                                          ..._buildGroupedPendingContacts(
                                            allPendingContacts,
                                            colorScheme,
                                          ),
                                          SizedBox(height: 24),
                                        ],

                                        // 3. Sección de contactos rechazados
                                        if (hasRejectedRequests) ...[
                                          _buildSectionHeader(
                                            'Solicitudes Rechazadas',
                                            colorScheme,
                                            icon: Icons.cancel,
                                            iconColor: Colors.red.shade400,
                                          ),
                                          SizedBox(height: 12),
                                          ..._buildGroupedRejectedContacts(
                                            rejectedContacts,
                                            colorScheme,
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => AddContactScreen()),
          );
        },
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        child: Icon(Icons.person_add),
      ),
    );
  }

  /// Estado vacío cuando no hay contactos
  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline,
            size: 64,
            color: colorScheme.outlineVariant,
          ),
          SizedBox(height: 16),
          Text(
            'No tienes contactos aún',
            style: TextStyle(
              fontSize: 16,
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),
          Text(
            'Agrega contactos usando el botón +',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Construir lista de contactos sugeridos (potential)
  List<Widget> _buildPotentialContactsList(
    List<contact_model.Contact> contacts,
    ColorScheme colorScheme,
  ) {
    final currentUserId = _contactsController.currentUserId;
    if (currentUserId == null) return [];

    return contacts.map((contact) {
      final otherUserId = contact.getOtherUserId(currentUserId);

      // Obtener el teléfono del otro usuario desde el mapa phones
      final phoneNumber = contact.phones[otherUserId] ?? '';

      // Obtener el nombre del contacto de la agenda del dispositivo
      final deviceContactName = _getDeviceContactName(phoneNumber);

      // Filtrar por búsqueda
      if (_contactSearchQuery.isNotEmpty &&
          !deviceContactName.toLowerCase().contains(_contactSearchQuery) &&
          !phoneNumber.contains(_contactSearchQuery)) {
        return SizedBox();
      }

      return PotentialContactCard(
        contact: contact,
        deviceContactName: deviceContactName,
        phoneNumber: phoneNumber,
        onTap: () => _showPotentialContactSheet(contact, deviceContactName, phoneNumber),
      );
    }).toList();
  }

  /// Mostrar sheet de contacto sugerido
  Future<void> _showPotentialContactSheet(
    contact_model.Contact contact,
    String deviceContactName,
    String phoneNumber,
  ) async {
    final currentUserId = _contactsController.currentUserId;
    if (currentUserId == null) return;

    // Obtener datos del usuario actual para determinar el mensaje
    final currentUserDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUserId)
        .get();

    final currentUserData = currentUserDoc.data();
    final linkedParentIds = List<String>.from(currentUserData?['linkedParentIds'] ?? []);
    final hasLinkedParents = linkedParentIds.isNotEmpty;

    // Determinar mensaje según quién necesita aprobación
    String explanationMessage;
    if (hasLinkedParents) {
      // El usuario actual tiene padres vinculados - su padre debe aprobar
      explanationMessage = 'Este contacto ya está en Talia.\n\nPara poder chatear, tu padre o madre debe aprobar la solicitud.';
    } else {
      // El usuario actual NO tiene padres - el padre del otro debe aprobar (si tiene)
      explanationMessage = 'Este contacto ya está en Talia.\n\nPara poder chatear, el padre o madre de $deviceContactName debe aprobar la solicitud.';
    }

    if (!mounted) return;

    PotentialContactSheet.show(
      context: context,
      contact: contact,
      deviceContactName: deviceContactName,
      phoneNumber: phoneNumber,
      explanationMessage: explanationMessage,
      onRequestApproval: () => _requestContactApproval(contact, deviceContactName),
    );
  }

  /// Agrupar contactos pendientes por el "otro usuario"
  List<Widget> _buildGroupedPendingContacts(
    List<contact_model.Contact> contacts,
    ColorScheme colorScheme,
  ) {
    final currentUserId = _contactsController.currentUserId;
    if (currentUserId == null) return [];

    // Agrupar contactos por el "otro usuario" (el que no soy yo)
    final Map<String, contact_model.Contact> groupedContacts = {};

    for (var contact in contacts) {
      final otherUserId = contact.getOtherUserId(currentUserId);
      if (otherUserId.isNotEmpty && !groupedContacts.containsKey(otherUserId)) {
        groupedContacts[otherUserId] = contact;
      }
    }

    // Crear una card por cada contacto único
    return groupedContacts.entries.map((entry) {
      final contact = entry.value;
      final otherUserId = entry.key;

      return _buildPendingContactCard(contact, otherUserId, colorScheme);
    }).toList();
  }

  /// Header de sección con icono personalizable
  Widget _buildSectionHeader(
    String title,
    ColorScheme colorScheme, {
    required IconData icon,
    required Color iconColor,
  }) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 16,
            color: iconColor,
          ),
        ),
        SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  /// Card compacta de contacto pendiente - click para ver detalles
  Widget _buildPendingContactCard(
    contact_model.Contact contact,
    String otherUserId,
    ColorScheme colorScheme,
  ) {
    // Intentar obtener el teléfono del mapa phones del contacto
    final phoneFromContact = contact.phones[otherUserId] ?? '';

    // Si tenemos el teléfono en el documento de contacto, usarlo para buscar nombre
    String? deviceNameFromContactPhone;
    if (phoneFromContact.isNotEmpty) {
      deviceNameFromContactPhone = _getDeviceContactName(phoneFromContact);
    }

    return FutureBuilder<DocumentSnapshot>(
      future: _contactsController.getUserDocument(otherUserId),
      builder: (context, otherUserSnapshot) {
        String displayName = 'Usuario';
        String phoneNumber = phoneFromContact; // Usar teléfono del contacto como fallback

        if (otherUserSnapshot.hasData) {
          final docExists = otherUserSnapshot.data!.exists;

          if (docExists) {
            final userData = otherUserSnapshot.data!.data() as Map<String, dynamic>?;
            final firestoreName = userData?['name'] as String? ?? '';
            final firestorePhone = userData?['phone'] as String? ?? '';
            phoneNumber = firestorePhone.isNotEmpty ? firestorePhone : phoneFromContact;

            // Intentar obtener nombre de la agenda del dispositivo
            final deviceName = phoneNumber.isNotEmpty ? _getDeviceContactName(phoneNumber) : '';

            // Usar nombre de Firestore si existe, sino nombre de agenda, sino "Usuario"
            if (firestoreName.isNotEmpty && firestoreName != 'Usuario') {
              displayName = firestoreName;
            } else if (deviceNameFromContactPhone != null && deviceNameFromContactPhone != phoneFromContact && deviceNameFromContactPhone.isNotEmpty) {
              // Primero intentar con el teléfono del documento de contacto
              displayName = deviceNameFromContactPhone;
            } else if (deviceName != phoneNumber && deviceName.isNotEmpty) {
              displayName = deviceName;
            } else {
              displayName = firestoreName.isNotEmpty ? firestoreName : 'Usuario';
            }
          } else {
            // Documento no existe, usar nombre de dispositivo si tenemos el teléfono
            if (deviceNameFromContactPhone != null && deviceNameFromContactPhone != phoneFromContact) {
              displayName = deviceNameFromContactPhone;
            }
          }
        } else {
          // Aún cargando, pero podemos usar el nombre del dispositivo si lo tenemos
          if (deviceNameFromContactPhone != null && deviceNameFromContactPhone != phoneFromContact) {
            displayName = deviceNameFromContactPhone;
          }
        }

        // Filtrar por búsqueda
        if (_contactSearchQuery.isNotEmpty &&
            !displayName.toLowerCase().contains(_contactSearchQuery)) {
          return SizedBox();
        }

        return GestureDetector(
          onTap: () => _showPendingContactDetailsDialog(contact, displayName, colorScheme),
          child: Container(
            margin: EdgeInsets.only(bottom: 12),
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.amber.shade600,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Avatar con inicial (sin foto porque no está aprobado)
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.amber.shade100,
                  child: Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.amber.shade800,
                    ),
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Pendiente de aprobación',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.amber.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _showPendingContactDetailsDialog(contact, displayName, colorScheme),
                  icon: Icon(
                    Icons.info_outline,
                    color: Colors.amber.shade600,
                  ),
                  tooltip: 'Ver detalles',
                ),
                IconButton(
                  onPressed: () => _cancelPendingContact(contact, displayName),
                  icon: Icon(
                    Icons.close,
                    color: colorScheme.error,
                  ),
                  tooltip: 'Cancelar solicitud',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Cancelar/rechazar un contacto pendiente
  Future<void> _cancelPendingContact(
    contact_model.Contact contact,
    String contactName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cancelar solicitud'),
        content: Text(
          '¿Estás seguro de cancelar la solicitud de contacto con $contactName?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Sí, cancelar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final currentUserId = _contactsController.currentUserId;
      if (currentUserId == null) return;

      final firestore = FirebaseFirestore.instance;

      // Marcar mi approval como rejected en el contacto
      await firestore.collection('contacts').doc(contact.id).update({
        'approvals.$currentUserId.status': 'rejected',
        'approvals.$currentUserId.rejectedAt': FieldValue.serverTimestamp(),
        'approvals.$currentUserId.rejectedBy': currentUserId,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solicitud con $contactName cancelada'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al cancelar solicitud: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Dialog de detalles de contacto pendiente
  void _showPendingContactDetailsDialog(
    contact_model.Contact contact,
    String contactName,
    ColorScheme colorScheme,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.schedule, color: Colors.amber.shade600),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                contactName,
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Text(
          'Esta solicitud de contacto está pendiente de aprobación por tu padre/madre.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _cancelPendingContact(contact, contactName);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Cancelar solicitud'),
          ),
        ],
      ),
    );
  }

  /// Agrupar contactos rechazados por el "otro usuario"
  List<Widget> _buildGroupedRejectedContacts(
    List<contact_model.Contact> contacts,
    ColorScheme colorScheme,
  ) {
    final currentUserId = _contactsController.currentUserId;
    if (currentUserId == null) return [];

    // Un widget por cada contacto rechazado
    return contacts.map((contact) {
      final otherUserId = contact.getOtherUserId(currentUserId);
      return _buildRejectedContactCard(contact, otherUserId, colorScheme);
    }).toList();
  }

  /// Card de contacto rechazado con opción de reenviar
  Widget _buildRejectedContactCard(
    contact_model.Contact contact,
    String otherUserId,
    ColorScheme colorScheme,
  ) {
    final currentUserId = _contactsController.currentUserId;
    final myApproval = currentUserId != null ? contact.approvals[currentUserId] : null;
    final rejectedByName = myApproval?.rejectedBy != null ? 'tu padre/madre' : 'tu padre/madre';

    return FutureBuilder<DocumentSnapshot>(
      future: _contactsController.getUserDocument(otherUserId),
      builder: (context, otherUserSnapshot) {
        String displayName = 'Usuario';
        if (otherUserSnapshot.hasData) {
          final userData = otherUserSnapshot.data!.data() as Map<String, dynamic>?;
          displayName = userData?['name'] ?? 'Usuario';
        }

        // Filtrar por búsqueda
        if (_contactSearchQuery.isNotEmpty &&
            !displayName.toLowerCase().contains(_contactSearchQuery)) {
          return SizedBox();
        }

        return GestureDetector(
          onTap: () => _showResendContactDialog(contact, otherUserId, displayName, colorScheme),
          child: Container(
            margin: EdgeInsets.only(bottom: 12),
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.red.shade300,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Avatar con inicial (sin foto porque fue rechazado)
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.red.shade50,
                  child: Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.red.shade700,
                    ),
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Rechazado por $rejectedByName',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.red.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                // Botón para reenviar solicitud
                IconButton(
                  onPressed: () => _showResendContactDialog(contact, otherUserId, displayName, colorScheme),
                  icon: Icon(
                    Icons.refresh,
                    color: colorScheme.primary,
                  ),
                  tooltip: 'Reenviar solicitud',
                ),
                // Botón para eliminar
                IconButton(
                  onPressed: () => _deleteRejectedContact(contact, displayName),
                  icon: Icon(
                    Icons.delete_outline,
                    color: Colors.red.shade400,
                  ),
                  tooltip: 'Eliminar',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Dialog para confirmar reenvío de contacto rechazado
  void _showResendContactDialog(
    contact_model.Contact contact,
    String otherUserId,
    String contactName,
    ColorScheme colorScheme,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.refresh, color: colorScheme.primary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '¿Reenviar solicitud?',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Text(
          'Tu padre/madre rechazó la solicitud de contacto con $contactName. '
          '¿Quieres enviar una nueva solicitud?\n\n'
          'Tu padre/madre recibirá una notificación para aprobar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _resendContact(contact, otherUserId, contactName);
            },
            child: Text('Reenviar'),
          ),
        ],
      ),
    );
  }

  /// Reenviar solicitud de contacto (resetea el estado a pending)
  Future<void> _resendContact(
    contact_model.Contact contact,
    String otherUserId,
    String contactName,
  ) async {
    try {
      // Llamar a la Cloud Function para crear nueva solicitud
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('createContactRequest').call({
        'contactUserId': otherUserId,
      });

      if (!mounted) return;

      final resultData = result.data as Map<String, dynamic>;
      final success = resultData['success'] ?? false;

      if (success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Solicitud reenviada a $contactName'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        final message = resultData['message'] ?? 'Error desconocido';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error reenviando solicitud: $e', tag: 'ChildContacts');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al reenviar solicitud'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Eliminar un contacto rechazado (elimina el documento)
  Future<void> _deleteRejectedContact(
    contact_model.Contact contact,
    String contactName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar solicitud'),
        content: Text(
          '¿Estás seguro de eliminar la solicitud rechazada con $contactName?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Sí, eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await FirebaseFirestore.instance.collection('contacts').doc(contact.id).delete();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solicitud eliminada'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar solicitud'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Card de contacto aprobado con teléfono y navegación a chat
  Widget _buildContactCard({
    required String contactId,
    required String name,
    required String phone,
    String? photoURL,
    required ColorScheme colorScheme,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: colorScheme.primaryContainer,
            backgroundImage: photoURL != null && photoURL.isNotEmpty
                ? CachedNetworkImageProvider(photoURL)
                : null,
            child: photoURL == null || photoURL.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  )
                : null,
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SyncedUserName(
                  userId: contactId,
                  fallbackName: name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  phone.isNotEmpty ? phone : 'Sin teléfono',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              // ✅ SEGURIDAD: Crear chat mediante Cloud Function (valida contactos, bloqueos, restricciones)
              CreateChatService.createAndNavigateToChat(
                context: context,
                otherUserId: contactId,
                otherUserName: name,
              );
            },
            icon: Icon(
              Icons.chat_bubble_outline,
              color: colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

}
