import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../chat_detail_screen.dart';

/// Pantalla que muestra los contactos de un hijo específico
///
/// Permite al padre ver todos los contactos aprobados de su hijo
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
  final FirebaseAuth _auth = FirebaseAuth.instance;
  String _searchQuery = '';

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
              stream: _firestore
                  .collection('contacts')
                  .where('users', arrayContains: widget.childId)
                  .where('status', isEqualTo: 'approved')
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
                      ],
                    ),
                  );
                }

                final contacts = snapshot.data?.docs ?? [];

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
        'contactId': contactDoc.id,
        'userId': otherUserId,
        'name': userData['name'] ?? 'Usuario',
        'photoURL': userData['photoURL'],
        'isOnline': userData['isOnline'] ?? false,
      });
    }

    // Ordenar por nombre
    contactsData.sort((a, b) =>
        (a['name'] as String).compareTo(b['name'] as String));

    return contactsData;
  }

  Widget _buildContactCard(Map<String, dynamic> contact) {
    final isOnline = contact['isOnline'] as bool? ?? false;

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () {
          // Generar chatId (ordenar IDs alfabéticamente)
          final currentUserId = _auth.currentUser?.uid ?? '';
          final otherUserId = contact['userId'] as String;
          final chatId = _generateChatId(currentUserId, otherUserId);

          // Navegar al chat
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatDetailScreen(
                contactId: otherUserId,
                contactName: contact['name'],
                chatId: chatId,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
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
                  if (isOnline)
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
              // Nombre
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
                    Text(
                      isOnline ? 'En línea' : 'Desconectado',
                      style: TextStyle(
                        fontSize: 13,
                        color: isOnline ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              // Icono de chat
              Icon(
                Icons.chat_bubble_outline,
                color: Color(0xFF9D7FE8),
              ),
            ],
          ),
        ),
      ),
    );
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
