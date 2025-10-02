import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'notification_service.dart';
import 'services/chat_block_service.dart';
import 'services/group_chat_service.dart';

class ParentalControlPanel extends StatefulWidget {
  const ParentalControlPanel({super.key});

  @override
  State<ParentalControlPanel> createState() => _ParentalControlPanelState();
}

final FirebaseAuth _auth = FirebaseAuth.instance;

class _ParentalControlPanelState extends State<ParentalControlPanel> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Control Parental'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('parent_children')
            .where('parentId', isEqualTo: _auth.currentUser?.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.family_restroom,
                    size: 80,
                    color: Colors.grey[300],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No tienes hijos vinculados',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Vincula un hijo para gestionar sus contactos',
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final doc = snapshot.data!.docs[index];
              final childId = doc['childId'];

              return FutureBuilder<DocumentSnapshot>(
                future: _firestore.collection('users').doc(childId).get(),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) return SizedBox();

                  final userData =
                      userSnapshot.data!.data() as Map<String, dynamic>?;
                  final childName = userData?['name'] ?? 'Hijo';

                  return _buildChildControlCard(
                    childId: childId,
                    childName: childName,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildChildControlCard({
    required String childId,
    required String childName,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 15,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header del hijo
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.white.withOpacity(0.3),
                  child: Text(
                    childName.isNotEmpty ? childName[0].toUpperCase() : 'H',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        childName,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 4),
                      StreamBuilder<List<int>>(
                        stream: Stream.fromFuture(Future.wait([
                          _firestore
                              .collection('contact_requests')
                              .where('childId', isEqualTo: childId)
                              .where('status', isEqualTo: 'pending')
                              .get()
                              .then((s) => s.docs.length),
                          _firestore
                              .collection('permission_requests')
                              .where('childId', isEqualTo: childId)
                              .where('status', isEqualTo: 'pending')
                              .get()
                              .then((s) => s.docs.length),
                        ])),
                        builder: (context, snapshot) {
                          final contactCount = snapshot.data?[0] ?? 0;
                          final groupCount = snapshot.data?[1] ?? 0;
                          final pendingCount = contactCount + groupCount;
                          return Text(
                            pendingCount > 0
                                ? '$pendingCount solicitud${pendingCount > 1 ? 'es' : ''} pendiente${pendingCount > 1 ? 's' : ''}'
                                : 'Sin solicitudes pendientes',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.9),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, color: Colors.white),
              ],
            ),
          ),

          // Solicitudes de contacto pendientes
          StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('contact_requests')
                .where('childId', isEqualTo: childId)
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return SizedBox.shrink();
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Solicitudes de Contacto',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2D3142),
                      ),
                    ),
                  ),
                  ...snapshot.data!.docs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    return _buildContactRequestItem(
                      requestId: doc.id,
                      childId: childId,
                      contactName: data['contactName'] ?? 'Desconocido',
                      contactPhone: data['contactPhone'] ?? '',
                    );
                  }).toList(),
                ],
              );
            },
          ),

          // Solicitudes de permiso para grupos
          StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('permission_requests')
                .where('childId', isEqualTo: childId)
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    '✓ No hay solicitudes pendientes',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Solicitudes de Grupo',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2D3142),
                      ),
                    ),
                  ),
                  ...snapshot.data!.docs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final groupInfo = data['groupInfo'] as Map<String, dynamic>?;
                    final contactInfo = data['contactToApprove'] as Map<String, dynamic>?;

                    return _buildGroupPermissionRequestItem(
                      requestId: doc.id,
                      childId: childId,
                      groupName: groupInfo?['groupName'] ?? 'Grupo',
                      contactName: contactInfo?['name'] ?? 'Usuario',
                      contactId: contactInfo?['userId'] ?? '',
                    );
                  }).toList(),
                ],
              );
            },
          ),

          // Ver contactos aprobados
          Padding(
            padding: EdgeInsets.all(16),
            child: TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ApprovedContactsScreen(
                      childId: childId,
                      childName: childName,
                    ),
                  ),
                );
              },
              icon: Icon(Icons.people),
              label: Text('Ver contactos aprobados'),
              style: TextButton.styleFrom(foregroundColor: Color(0xFF9D7FE8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactRequestItem({
    required String requestId,
    required String childId,
    required String contactName,
    required String contactPhone,
  }) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.person_add, color: Colors.orange, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contactName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2D3142),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      contactPhone,
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _rejectContact(requestId),
                  icon: Icon(Icons.close, size: 18),
                  label: Text('Rechazar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _approveContact(
                    requestId,
                    childId,
                    contactName,
                    contactPhone,
                  ),
                  icon: Icon(Icons.check, size: 18),
                  label: Text('Aprobar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _approveContact(
    String requestId,
    String childId,
    String contactName,
    String contactPhone,
  ) async {
    try {
      // Mostrar diálogo de confirmación
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Aprobar contacto'),
          content: Text(
            '¿Deseas aprobar a "$contactName" como contacto de tu hijo?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: Text('Aprobar'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      // Buscar o crear el usuario contacto
      String contactId;
      final existingUser = await _firestore
          .collection('users')
          .where(
            'email',
            isEqualTo: contactPhone,
          ) // Usar phone como identificador temporal
          .limit(1)
          .get();

      if (existingUser.docs.isNotEmpty) {
        contactId = existingUser.docs.first.id;
      } else {
        // Crear usuario fantasma (será actualizado cuando se registre)
        final newUserRef = _firestore.collection('users').doc();
        await newUserRef.set({
          'name': contactName,
          'phone': contactPhone,
          'email': contactPhone,
          'isParent': false,
          'isPlaceholder': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
        contactId = newUserRef.id;
      }

      // Actualizar solicitud a aprobada
      await _firestore.collection('contact_requests').doc(requestId).update({
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
        'contactId': contactId,
      });

      // Agregar a la lista blanca
      await _firestore.collection('whitelist').add({
        'childId': childId,
        'contactId': contactId,
        'addedAt': FieldValue.serverTimestamp(),
        'approvedBy': _auth.currentUser!.uid,
      });

      // Procesar invitaciones de grupo pendientes
      final groupChatService = GroupChatService();
      await groupChatService.processGroupInvitationsAfterContactApproval(
        childId,
        contactId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Contacto aprobado exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      }
      await NotificationService().sendContactApprovedNotification(
        childId: childId,
        contactName: contactName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error al aprobar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _rejectContact(String requestId) async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Rechazar solicitud'),
          content: Text('¿Estás seguro de rechazar esta solicitud?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: Text('Rechazar'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      await _firestore.collection('contact_requests').doc(requestId).update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
        'rejectedBy': _auth.currentUser!.uid,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solicitud rechazada'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildGroupPermissionRequestItem({
    required String requestId,
    required String childId,
    required String groupName,
    required String contactName,
    required String contactId,
  }) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.group_add, color: Colors.blue, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Invitación a grupo',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.blue[700],
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      groupName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2D3142),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Aprobar contacto: $contactName',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _rejectGroupPermission(requestId),
                  icon: Icon(Icons.close, size: 18),
                  label: Text('Rechazar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _approveGroupPermission(
                    requestId,
                    childId,
                    contactId,
                    contactName,
                  ),
                  icon: Icon(Icons.check, size: 18),
                  label: Text('Aprobar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _approveGroupPermission(
    String requestId,
    String childId,
    String contactId,
    String contactName,
  ) async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Aprobar contacto para grupo'),
          content: Text(
            '¿Deseas aprobar a "$contactName" para que pueda unirse a grupos con tu hijo?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: Text('Aprobar'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      // Agregar a la lista blanca
      await _firestore.collection('whitelist').add({
        'childId': childId,
        'contactId': contactId,
        'addedAt': FieldValue.serverTimestamp(),
        'approvedBy': _auth.currentUser!.uid,
        'approvedForGroup': true,
      });

      // Actualizar solicitud a aprobada
      await _firestore.collection('permission_requests').doc(requestId).update({
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
      });

      // Procesar invitaciones de grupo pendientes
      final groupChatService = GroupChatService();
      await groupChatService.processGroupInvitationsAfterContactApproval(
        childId,
        contactId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Contacto aprobado para grupo'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error al aprobar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _rejectGroupPermission(String requestId) async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Rechazar solicitud'),
          content: Text('¿Estás seguro de rechazar esta solicitud de grupo?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: Text('Rechazar'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      await _firestore.collection('permission_requests').doc(requestId).update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
        'rejectedBy': _auth.currentUser!.uid,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solicitud de grupo rechazada'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}

// Pantalla de contactos aprobados
class ApprovedContactsScreen extends StatelessWidget {
  final String childId;
  final String childName;

  const ApprovedContactsScreen({
    super.key,
    required this.childId,
    required this.childName,
  });

  @override
  Widget build(BuildContext context) {
    final FirebaseFirestore firestore = FirebaseFirestore.instance;

    return Scaffold(
      appBar: AppBar(
        title: Text('Contactos de $childName'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: firestore
            .collection('whitelist')
            .where('childId', isEqualTo: childId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.people_outline, size: 80, color: Colors.grey[300]),
                  SizedBox(height: 16),
                  Text(
                    'Sin contactos aprobados',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final doc = snapshot.data!.docs[index];
              final contactId = doc['contactId'];

              return FutureBuilder<DocumentSnapshot>(
                future: firestore.collection('users').doc(contactId).get(),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) {
                    return Container(
                      margin: EdgeInsets.only(bottom: 12),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  // Si el documento no existe, no mostrar nada
                  if (!userSnapshot.data!.exists) {
                    print('⚠️ Usuario $contactId en whitelist no existe, ignorando...');
                    return SizedBox.shrink();
                  }

                  final userData =
                      userSnapshot.data!.data() as Map<String, dynamic>?;

                  // Verificar si es un usuario placeholder (temporal)
                  if (userData?['isPlaceholder'] == true) {
                    return SizedBox.shrink();
                  }

                  final name = userData?['name'] ?? 'Usuario';
                  final phone = userData?['phone'] ?? '';

                  return Container(
                    margin: EdgeInsets.only(bottom: 12),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : 'U',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF9D7FE8),
                            ),
                          ),
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
                                ),
                              ),
                              if (phone.isNotEmpty) ...[
                                SizedBox(height: 4),
                                Text(
                                  phone,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => _removeContact(
                            context,
                            doc.id,
                            name,
                            contactId,
                            childId,
                          ),
                          icon: Icon(Icons.delete_outline, color: Colors.red),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _removeContact(
    BuildContext context,
    String whitelistId,
    String contactName,
    String contactId,
    String childId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar contacto'),
        content: Text(
          '¿Deseas eliminar a "$contactName" de los contactos aprobados?\n\nEsto también bloqueará todas sus conversaciones existentes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // 1. Bloquear el chat antes de eliminar de whitelist
      final chatBlockService = ChatBlockService();
      await chatBlockService.blockChat(
        childId: childId,
        contactId: contactId,
        reason: 'Contacto removido de la lista blanca por el padre',
        blockedBy: _auth.currentUser?.uid,
      );

      print('✅ Chat bloqueado entre $childId y $contactId');

      // 2. Eliminar de whitelist
      await FirebaseFirestore.instance
          .collection('whitelist')
          .doc(whitelistId)
          .delete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contacto eliminado y conversaciones bloqueadas'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }

      print('✅ Contacto $contactName removido de whitelist y chat bloqueado');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
