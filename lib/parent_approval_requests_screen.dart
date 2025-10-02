import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ParentApprovalRequestsScreen extends StatefulWidget {
  const ParentApprovalRequestsScreen({super.key});

  @override
  State<ParentApprovalRequestsScreen> createState() =>
      _ParentApprovalRequestsScreenState();
}

class _ParentApprovalRequestsScreenState
    extends State<ParentApprovalRequestsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> _handleApproval({
    required String requestId,
    required String childId,
    required String newParentId,
    required String linkCodeDocId,
    required bool approved,
  }) async {
    try {
      final requestDoc =
          _firestore.collection('parent_approval_requests').doc(requestId);

      if (approved) {
        print('✅ Aprobando solicitud de vinculación...');

        // Actualizar el documento del código de vinculación
        await _firestore.collection('link_codes').doc(linkCodeDocId).update({
          'used': true,
          'usedBy': childId,
          'usedAt': FieldValue.serverTimestamp(),
          'isActive': false,
        });

        // Crear relación padre-hijo en AMBAS colecciones
        await _firestore.collection('parent_children').add({
          'parentId': newParentId,
          'childId': childId,
          'status': 'approved',
          'linkedAt': FieldValue.serverTimestamp(),
        });

        await _firestore.collection('parent_child_links').add({
          'parentId': newParentId,
          'childId': childId,
          'status': 'approved',
          'linkedAt': FieldValue.serverTimestamp(),
        });

        // Actualizar usuario hijo para agregar el segundo padre
        // Nota: Mantiene el parentId original, solo agrega relación
        await _firestore.collection('users').doc(childId).update({
          'additionalParentLinkedAt': FieldValue.serverTimestamp(),
        });

        // Actualizar estado de la solicitud
        await requestDoc.update({
          'status': 'approved',
          'approvedAt': FieldValue.serverTimestamp(),
        });

        // Notificar al nuevo padre
        await _firestore.collection('notifications').add({
          'userId': newParentId,
          'title': 'Vinculación Aprobada',
          'body': 'Tu solicitud de vinculación ha sido aprobada',
          'type': 'parent_link_approved',
          'priority': 'high',
          'read': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Solicitud aprobada exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        print('❌ Rechazando solicitud de vinculación...');

        // Actualizar estado de la solicitud
        await requestDoc.update({
          'status': 'rejected',
          'rejectedAt': FieldValue.serverTimestamp(),
        });

        // Notificar al nuevo padre del rechazo
        await _firestore.collection('notifications').add({
          'userId': newParentId,
          'title': 'Vinculación Rechazada',
          'body': 'Tu solicitud de vinculación ha sido rechazada',
          'type': 'parent_link_rejected',
          'priority': 'normal',
          'read': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Solicitud rechazada'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      print('❌ Error procesando solicitud: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Solicitudes Pendientes'),
          backgroundColor: Color(0xFF9D7FE8),
          foregroundColor: Colors.white,
        ),
        body: Center(child: Text('Usuario no autenticado')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Solicitudes Pendientes'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('parent_approval_requests')
            .where('existingParentId', isEqualTo: currentUserId)
            .where('status', isEqualTo: 'pending')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            print('⚠️ Error leyendo solicitudes de aprobación: ${snapshot.error}');
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 80,
                    color: Colors.grey[400],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No se pueden cargar las solicitudes',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Es posible que no tengas permisos',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            );
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 80,
                    color: Colors.grey[400],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No hay solicitudes pendientes',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            );
          }

          final requests = snapshot.data!.docs;

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              final data = request.data() as Map<String, dynamic>;
              final childName = data['childName'] ?? 'Usuario';
              final newParentName = data['newParentName'] ?? 'Usuario';
              final createdAt = data['createdAt'] as Timestamp?;

              return Card(
                margin: EdgeInsets.only(bottom: 16),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.person_add,
                              color: Colors.orange,
                              size: 28,
                            ),
                          ),
                          SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Nueva Solicitud de Vinculación',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2D3142),
                                  ),
                                ),
                                SizedBox(height: 4),
                                if (createdAt != null)
                                  Text(
                                    _formatDate(createdAt.toDate()),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      Divider(),
                      SizedBox(height: 16),
                      RichText(
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 15,
                            color: Color(0xFF2D3142),
                            height: 1.5,
                          ),
                          children: [
                            TextSpan(
                              text: childName,
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            TextSpan(
                              text: ' quiere vincular a ',
                            ),
                            TextSpan(
                              text: newParentName,
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            TextSpan(
                              text: ' como padre/madre adicional.',
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _handleApproval(
                                requestId: request.id,
                                childId: data['childId'],
                                newParentId: data['newParentId'],
                                linkCodeDocId: data['linkCodeDocId'],
                                approved: false,
                              ),
                              icon: Icon(Icons.close),
                              label: Text('Rechazar'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: BorderSide(color: Colors.red),
                                padding: EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _handleApproval(
                                requestId: request.id,
                                childId: data['childId'],
                                newParentId: data['newParentId'],
                                linkCodeDocId: data['linkCodeDocId'],
                                approved: true,
                              ),
                              icon: Icon(Icons.check),
                              label: Text('Aprobar'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inMinutes < 1) {
      return 'Hace un momento';
    } else if (difference.inHours < 1) {
      return 'Hace ${difference.inMinutes} minutos';
    } else if (difference.inDays < 1) {
      return 'Hace ${difference.inHours} horas';
    } else if (difference.inDays == 1) {
      return 'Ayer';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
