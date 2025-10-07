import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

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

        // 🔒 SEGURIDAD: Usar Cloud Function para crear vínculo validado
        try {
          // Obtener el código del link_codes doc para pasarlo a la función
          final linkCodeDoc = await _firestore.collection('link_codes').doc(linkCodeDocId).get();
          final linkCodeData = linkCodeDoc.data();
          final code = linkCodeData?['code'] as String?;

          final functions = FirebaseFunctions.instance;
          final result = await functions.httpsCallable('createParentChildLink').call({
            'parentId': newParentId,
            'childId': childId,
            'code': code, // La Cloud Function marcará el código como usado
          });

          if (result.data['success'] != true) {
            throw Exception(result.data['message'] ?? 'Error creating parent-child link');
          }

          print('✅ Vínculo aprobado y creado: ${result.data['linkId']}');
        } catch (e) {
          print('❌ Error al crear vínculo aprobado: $e');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Error al aprobar vinculación: $e'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }

        // Verificar contactos existentes del niño
        print('🔄 Verificando contactos existentes del niño...');
        final existingContacts = await _firestore
            .collection('contacts')
            .where('users', arrayContains: childId)
            .where('status', isEqualTo: 'approved')
            .get();

        final contactCount = existingContacts.docs.length;

        if (contactCount > 0) {
          // Notificar al nuevo padre sobre los contactos existentes
          await _firestore.collection('notifications').add({
            'userId': newParentId,
            'title': 'Contactos Existentes',
            'body': 'El niño ya tiene $contactCount contacto${contactCount > 1 ? 's' : ''} aprobado${contactCount > 1 ? 's' : ''}. Puedes revisarlos en Control Parental.',
            'type': 'contacts_migrated',
            'priority': 'normal',
            'read': false,
            'createdAt': FieldValue.serverTimestamp(),
            'data': {
              'childId': childId,
              'contactCount': contactCount,
            },
          });
          print('✅ Notificación enviada al nuevo padre sobre $contactCount contactos existentes');
        }

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
    final colorScheme = Theme.of(context).colorScheme;
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Solicitudes Pendientes'),
        ),
        body: Center(child: Text('Usuario no autenticado')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Solicitudes Pendientes'),
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
                    color: colorScheme.outlineVariant,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No se pueden cargar las solicitudes',
                    style: TextStyle(
                      fontSize: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Es posible que no tengas permisos',
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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
                    color: colorScheme.outlineVariant,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No hay solicitudes pendientes',
                    style: TextStyle(
                      fontSize: 18,
                      color: colorScheme.onSurfaceVariant,
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
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                SizedBox(height: 4),
                                if (createdAt != null)
                                  Text(
                                    _formatDate(createdAt.toDate()),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colorScheme.onSurfaceVariant,
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
                            color: colorScheme.onSurface,
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
