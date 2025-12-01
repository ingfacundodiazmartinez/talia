import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cached_network_image/cached_network_image.dart';

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
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  String _searchQuery = '';
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Contactos de ${widget.childName}'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
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
                prefixIcon: Icon(Icons.search, color: Color(0xFF9D7FE8)),
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
            child: StreamBuilder<QuerySnapshot>(
              // Query solo con arrayContains (no se puede combinar con whereIn)
              stream: _firestore
                  .collection('contacts')
                  .where('users', arrayContains: widget.childId)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF9D7FE8),
                    ),
                  );
                }

                if (snapshot.hasError) {
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
                            '${snapshot.error}',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                // ✅ Filtrar en memoria: solo approved y pending
                final allContacts = snapshot.data?.docs ?? [];
                final contacts = allContacts.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final status = data['status'] as String? ?? '';
                  return status == 'approved' || status == 'pending';
                }).toList();

                if (contacts.isEmpty) {
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

                return FutureBuilder<List<Map<String, dynamic>>>(
                  future: _loadContactsData(contacts),
                  builder: (context, contactsSnapshot) {
                    if (contactsSnapshot.connectionState == ConnectionState.waiting) {
                      return Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF9D7FE8),
                        ),
                      );
                    }

                    final contactsData = contactsSnapshot.data ?? [];

                    // Filtrar por búsqueda
                    final filteredContacts = contactsData.where((contact) {
                      final name = (contact['name'] as String? ?? '').toLowerCase();
                      return name.contains(_searchQuery);
                    }).toList();

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

                    return ListView.builder(
                      padding: EdgeInsets.all(16),
                      itemCount: filteredContacts.length,
                      itemBuilder: (context, index) {
                        final contact = filteredContacts[index];
                        return _buildContactCard(contact);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _loadContactsData(
      List<QueryDocumentSnapshot> contacts) async {
    final List<Map<String, dynamic>> contactsData = [];

    for (final contactDoc in contacts) {
      final data = contactDoc.data() as Map<String, dynamic>;
      final users = List<String>.from(data['users'] ?? []);
      final status = data['status'] as String? ?? 'pending';

      // Obtener el ID del otro usuario (no el hijo)
      final otherUserId = users.firstWhere(
        (userId) => userId != widget.childId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) continue;

      // Obtener datos del otro usuario
      final userDoc = await _firestore.collection('users').doc(otherUserId).get();
      if (!userDoc.exists) continue;

      final userData = userDoc.data()!;
      contactsData.add({
        'contactDocId': contactDoc.id,
        'userId': otherUserId,
        'name': userData['name'] ?? 'Usuario',
        'photoURL': userData['photoURL'],
        'isOnline': userData['isOnline'] ?? false,
        'status': status,
      });
    }

    // Ordenar: primero pendientes, luego por nombre
    contactsData.sort((a, b) {
      final aIsPending = a['status'] == 'pending';
      final bIsPending = b['status'] == 'pending';
      if (aIsPending && !bIsPending) return -1;
      if (!aIsPending && bIsPending) return 1;
      return (a['name'] as String).compareTo(b['name'] as String);
    });

    return contactsData;
  }

  Widget _buildContactCard(Map<String, dynamic> contact) {
    final isOnline = contact['isOnline'] as bool? ?? false;
    final isPending = contact['status'] == 'pending';
    final contactDocId = contact['contactDocId'] as String;
    final contactUserId = contact['userId'] as String;

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
            // Avatar con indicador de estado
            Stack(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFF9D7FE8).withValues(alpha: 0.1),
                  backgroundImage: contact['photoURL'] != null
                      ? CachedNetworkImageProvider(contact['photoURL'])
                      : null,
                  child: contact['photoURL'] == null
                      ? Text(
                          _getInitials(contact['name']),
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF9D7FE8),
                          ),
                        )
                      : null,
                ),
                if (isOnline && !isPending)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(width: 12),
            // Nombre y estado
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact['name'],
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
                      isOnline ? 'En línea' : 'Contacto aprobado',
                      style: TextStyle(
                        fontSize: 13,
                        color: isOnline ? Colors.green : Colors.grey,
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
                onPressed: _isLoading ? null : () => _approveContact(contactDocId, contact['name']),
              ),
              // Botón rechazar
              IconButton(
                icon: Icon(Icons.cancel, color: Colors.red, size: 28),
                tooltip: 'Rechazar contacto',
                onPressed: _isLoading ? null : () => _deleteContact(contactDocId, contactUserId, contact['name']),
              ),
            ] else ...[
              // Botón eliminar
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.red),
                tooltip: 'Eliminar contacto',
                onPressed: _isLoading ? null : () => _deleteContact(contactDocId, contactUserId, contact['name']),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Aprobar un contacto pendiente
  Future<void> _approveContact(String contactDocId, String contactName) async {
    // Buscar la solicitud de contacto asociada
    try {
      setState(() => _isLoading = true);

      // IMPORTANTE: Incluir childId en el query para que las reglas de Firestore
      // puedan verificar que el usuario es padre del hijo (isParentOfRequestChild)
      final requestsQuery = await _firestore
          .collection('contact_requests')
          .where('contactDocId', isEqualTo: contactDocId)
          .where('childId', isEqualTo: widget.childId)
          .where('status', isEqualTo: 'pending')
          .get();

      if (requestsQuery.docs.isEmpty) {
        // Si no hay solicitud, usar Cloud Function para aprobar directamente el contacto
        await _functions.httpsCallable('updateContactStatus').call({
          'contactDocId': contactDocId,
          'status': 'approved',
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Contacto $contactName aprobado'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // Usar Cloud Function para aprobar correctamente
        for (final doc in requestsQuery.docs) {
          await _functions.httpsCallable('updateContactRequestStatus').call({
            'requestId': doc.id,
            'status': 'approved',
          });
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Contacto $contactName aprobado'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al aprobar contacto: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Eliminar un contacto (y el chat asociado)
  Future<void> _deleteContact(String contactDocId, String contactUserId, String contactName) async {
    setState(() => _isLoading = true);

    try {
      // Buscar grupos donde ambos (hijo y contacto) son miembros
      final sharedGroupsQuery = await _firestore
          .collection('groups')
          .where('members', arrayContains: widget.childId)
          .get();

      final sharedGroups = sharedGroupsQuery.docs.where((doc) {
        final members = List<String>.from(doc.data()['members'] ?? []);
        return members.contains(contactUserId);
      }).toList();

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
      for (final group in sharedGroups) {
        await _firestore.collection('groups').doc(group.id).update({
          'members': FieldValue.arrayRemove([widget.childId]),
        });
      }

      if (mounted) {
        final message = sharedGroups.isEmpty
            ? 'Contacto $contactName eliminado'
            : 'Contacto $contactName eliminado y ${widget.childName} removido de ${sharedGroups.length} grupo(s)';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
          ),
        );
      }
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

  /// Genera un chatId único ordenando los IDs alfabéticamente
  String _generateChatId(String userId1, String userId2) {
    final ids = [userId1, userId2]..sort();
    return '${ids[0]}_${ids[1]}';
  }
}
