import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../models/parent.dart';
import '../../../../parent_approval_requests_screen.dart';

/// Badge con contador de solicitudes de aprobación pendientes
///
/// Responsabilidades:
/// - Mostrar número de solicitudes pendientes
/// - Navegar a pantalla de solicitudes al tocar
class ApprovalRequestsBadge extends StatelessWidget {
  final String parentId;

  const ApprovalRequestsBadge({
    super.key,
    required this.parentId,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: Parent(id: parentId, name: '').getApprovalRequestsStream(),
      builder: (context, snapshot) {
        // Manejar error de permisos gracefully
        if (snapshot.hasError) {
          print('⚠️ Error leyendo solicitudes de aprobación: ${snapshot.error}');
        }

        final pendingCount = snapshot.hasData ? snapshot.data!.docs.length : 0;

        return Stack(
          children: [
            IconButton(
              icon: Icon(Icons.notification_important),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ParentApprovalRequestsScreen(),
                  ),
                );
              },
            ),
            if (pendingCount > 0)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  child: Text(
                    '$pendingCount',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
