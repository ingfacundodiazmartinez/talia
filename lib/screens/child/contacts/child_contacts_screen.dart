import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../services/chat_permission_service.dart';
import '../../../screens/add_contact_screen.dart';
import '../../chat_detail_screen.dart';

/// Pantalla de contactos para niños con funcionalidad completa
///
/// Características:
/// - Búsqueda de contactos en tiempo real
/// - Solicitudes pendientes agrupadas por usuario
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
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ChatPermissionService _permissionService = ChatPermissionService();

  String _contactSearchQuery = '';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Mis Contactos'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
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
          // Lista de contactos con triple StreamBuilder
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              // Solicitudes donde YO soy el hijo (mis padres deben aprobar)
              stream: _firestore
                  .collection('contact_requests')
                  .where('childId', isEqualTo: _auth.currentUser?.uid)
                  .where('status', isEqualTo: 'pending')
                  .snapshots(),
              builder: (context, myRequestsSnapshot) {
                return StreamBuilder<QuerySnapshot>(
                  // Solicitudes donde YO soy el contacto (padres del otro deben aprobar)
                  stream: _firestore
                      .collection('contact_requests')
                      .where('contactId', isEqualTo: _auth.currentUser?.uid)
                      .where('status', isEqualTo: 'pending')
                      .snapshots(),
                  builder: (context, otherRequestsSnapshot) {
                    return StreamBuilder<List<String>>(
                      stream: _permissionService.watchBidirectionallyApprovedContacts(
                        _auth.currentUser?.uid ?? '',
                      ),
                      builder: (context, approvedSnapshot) {
                        if (myRequestsSnapshot.hasError ||
                            otherRequestsSnapshot.hasError ||
                            approvedSnapshot.hasError) {
                          return Center(
                            child: Text(
                              'Error cargando contactos',
                              style: TextStyle(color: colorScheme.error),
                            ),
                          );
                        }

                        if (myRequestsSnapshot.connectionState == ConnectionState.waiting ||
                            otherRequestsSnapshot.connectionState == ConnectionState.waiting ||
                            approvedSnapshot.connectionState == ConnectionState.waiting) {
                          return Center(
                            child: CircularProgressIndicator(
                              color: colorScheme.primary,
                            ),
                          );
                        }

                        // Combinar todas las solicitudes pendientes
                        final allPendingDocs = <QueryDocumentSnapshot>[];
                        if (myRequestsSnapshot.hasData) {
                          allPendingDocs.addAll(myRequestsSnapshot.data!.docs);
                        }
                        if (otherRequestsSnapshot.hasData) {
                          allPendingDocs.addAll(otherRequestsSnapshot.data!.docs);
                        }

                        final hasPendingRequests = allPendingDocs.isNotEmpty;
                        final hasApprovedContacts = approvedSnapshot.hasData &&
                                                    approvedSnapshot.data!.isNotEmpty;

                        if (!hasPendingRequests && !hasApprovedContacts) {
                          return _buildEmptyState(colorScheme);
                        }

                        return ListView(
                          padding: EdgeInsets.all(16),
                          children: [
                            // Sección de solicitudes pendientes
                            if (hasPendingRequests) ...[
                              _buildSectionHeader(
                                'Solicitudes Pendientes',
                                colorScheme,
                                isPending: true,
                              ),
                              SizedBox(height: 12),
                              ..._buildGroupedPendingRequests(
                                allPendingDocs,
                                colorScheme,
                              ),
                              SizedBox(height: 24),
                            ],

                            // Sección de contactos aprobados
                            if (hasApprovedContacts) ...[
                              _buildSectionHeader(
                                'Contactos Aprobados',
                                colorScheme,
                                isPending: false,
                              ),
                              SizedBox(height: 12),
                              ...approvedSnapshot.data!.map((contactId) {
                                return FutureBuilder<DocumentSnapshot>(
                                  future: _firestore.collection('users').doc(contactId).get(),
                                  builder: (context, userSnapshot) {
                                    if (!userSnapshot.hasData) {
                                      return SizedBox();
                                    }

                                    final userData =
                                        userSnapshot.data!.data() as Map<String, dynamic>?;
                                    final name = userData?['name'] ?? 'Usuario';
                                    final isOnline = userData?['isOnline'] ?? false;
                                    final photoURL = userData?['photoURL'];

                                    // Filtrar por búsqueda
                                    if (_contactSearchQuery.isNotEmpty &&
                                        !name.toLowerCase().contains(_contactSearchQuery)) {
                                      return SizedBox();
                                    }

                                    return _buildContactCard(
                                      contactId: contactId,
                                      name: name,
                                      status: isOnline ? 'En línea' : 'Desconectado',
                                      isOnline: isOnline,
                                      photoURL: photoURL,
                                      colorScheme: colorScheme,
                                    );
                                  },
                                );
                              }).toList(),
                            ],
                          ],
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

  /// Agrupar solicitudes pendientes por el "otro usuario"
  List<Widget> _buildGroupedPendingRequests(
    List<QueryDocumentSnapshot> docs,
    ColorScheme colorScheme,
  ) {
    final currentUserId = _auth.currentUser?.uid;
    // Agrupar solicitudes por el "otro usuario" (el que no soy yo)
    final Map<String, List<QueryDocumentSnapshot>> groupedRequests = {};

    for (var doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final childId = data['childId'] as String;
      final contactId = data['contactId'] as String;

      // Identificar quién es el "otro usuario" dependiendo de mi rol en la solicitud
      final otherUserId = (childId == currentUserId) ? contactId : childId;

      if (!groupedRequests.containsKey(otherUserId)) {
        groupedRequests[otherUserId] = [];
      }
      groupedRequests[otherUserId]!.add(doc);
    }

    // Crear una card por cada contacto único y filtrar por búsqueda
    return groupedRequests.entries.map((entry) {
      final requests = entry.value;
      if (requests.isEmpty) return SizedBox();

      final firstRequest = requests.first.data() as Map<String, dynamic>;
      final childId = firstRequest['childId'] as String;
      final contactId = firstRequest['contactId'] as String;

      final otherUserName = (childId == currentUserId)
          ? (firstRequest['contactName'] ?? 'Usuario')
          : (firstRequest['childName'] ?? 'Usuario');

      // Filtrar por búsqueda
      if (_contactSearchQuery.isNotEmpty &&
          !otherUserName.toLowerCase().contains(_contactSearchQuery)) {
        return SizedBox();
      }

      return _buildPendingRequestCard(entry.value, colorScheme);
    }).toList();
  }

  /// Header de sección (Pendientes o Aprobados)
  Widget _buildSectionHeader(String title, ColorScheme colorScheme, {required bool isPending}) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            isPending ? Icons.schedule : Icons.check_circle,
            size: 16,
            color: colorScheme.primary,
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

  /// Card de solicitud pendiente con información de aprobación
  Widget _buildPendingRequestCard(
    List<QueryDocumentSnapshot> requests,
    ColorScheme colorScheme,
  ) {
    if (requests.isEmpty) return SizedBox();

    final currentUserId = _auth.currentUser?.uid;
    final firstRequest = requests.first.data() as Map<String, dynamic>;
    final childId = firstRequest['childId'] as String;
    final contactId = firstRequest['contactId'] as String;

    // Determinar quién es el "otro usuario" y obtener su nombre
    final otherUserId = (childId == currentUserId) ? contactId : childId;
    final otherUserName = (childId == currentUserId)
        ? (firstRequest['contactName'] ?? 'Usuario')
        : (firstRequest['childName'] ?? 'Usuario');

    // Obtener todos los parent IDs que deben aprobar
    final parentIds = requests
        .map((r) => (r.data() as Map<String, dynamic>)['parentId'] as String)
        .toList();

    return FutureBuilder<DocumentSnapshot>(
      // Obtener datos actualizados del otro usuario
      future: _firestore.collection('users').doc(otherUserId).get(),
      builder: (context, otherUserSnapshot) {
        String displayName = otherUserName;
        if (otherUserSnapshot.hasData) {
          final userData = otherUserSnapshot.data!.data() as Map<String, dynamic>?;
          displayName = userData?['name'] ?? otherUserName;
        }

        return FutureBuilder<List<DocumentSnapshot>>(
          future: Future.wait(
            parentIds.map((id) => _firestore.collection('users').doc(id).get()),
          ),
          builder: (context, parentsSnapshot) {
            final parentNames = parentsSnapshot.hasData
                ? parentsSnapshot.data!
                    .map((doc) => (doc.data() as Map<String, dynamic>?)?['name'] ?? 'Padre/Madre')
                    .toList()
                : ['Cargando...'];

            // Determinar el texto según quién debe aprobar
            final bool isMyParent = (childId == currentUserId);
            final int parentCount = parentNames.length;

            String approvalText;
            if (isMyParent) {
              // Mis padres deben aprobar
              approvalText = parentCount > 1
                  ? 'Esperando aprobación de mis padres'
                  : 'Esperando aprobación de mi padre/madre';
            } else {
              // Los padres del otro usuario deben aprobar
              approvalText = parentCount > 1
                  ? 'Esperando aprobación de sus padres'
                  : 'Esperando aprobación de su padre/madre';
            }

            return Container(
              margin: EdgeInsets.only(bottom: 12),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: colorScheme.tertiary.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: colorScheme.tertiaryContainer,
                    child: Icon(
                      Icons.schedule,
                      color: colorScheme.tertiary,
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
                        Row(
                          children: [
                            Icon(
                              Icons.family_restroom,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                approvalText,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Card de contacto aprobado con estado en línea y navegación a chat
  Widget _buildContactCard({
    required String contactId,
    required String name,
    required String status,
    required bool isOnline,
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
          Stack(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: colorScheme.primaryContainer,
                backgroundImage: photoURL != null && photoURL.isNotEmpty
                    ? NetworkImage(photoURL)
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
                        color: colorScheme.surface,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 14,
                    color: isOnline ? Colors.green : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              final chatId = _getChatId(_auth.currentUser!.uid, contactId);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChatDetailScreen(
                    chatId: chatId,
                    contactId: contactId,
                    contactName: name,
                  ),
                ),
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

  /// Generar ID único de chat entre dos usuarios
  String _getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }
}
