import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../services/emergency_service.dart';
import '../../../../models/user.dart';
import '../../../emergency_detail_screen.dart';

/// Widget que muestra alertas de emergencias activas
///
/// Responsabilidades:
/// - Escuchar emergencias activas del padre
/// - Mostrar badge visual prominente cuando hay emergencias
/// - Navegar a detalle de emergencia al tocar
///
/// Se muestra solo cuando hay emergencias activas, sino retorna SizedBox.shrink()
class EmergencyAlertWidget extends StatelessWidget {
  final String parentId;

  const EmergencyAlertWidget({
    super.key,
    required this.parentId,
  });

  @override
  Widget build(BuildContext context) {
    final emergencyService = EmergencyService();

    return StreamBuilder<QuerySnapshot>(
      stream: emergencyService.getActiveEmergenciesForParent(parentId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return SizedBox.shrink();
        }

        final emergencies = snapshot.data!.docs;

        return Container(
          margin: EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.red.shade600, Colors.red.shade800],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.red.withOpacity(0.4),
                blurRadius: 12,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                // Si hay múltiples emergencias, navegar a la primera
                final emergency = emergencies.first;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => EmergencyDetailScreen(
                      emergencyId: emergency.id,
                      emergencyData: emergency.data() as Map<String, dynamic>,
                    ),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.warning,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '🆘 EMERGENCIA ACTIVA',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              SizedBox(height: 4),
                              if (emergencies.length == 1)
                                FutureBuilder<DocumentSnapshot?>(
                                  future: User.getByIdSnapshot(
                                    (emergencies.first.data()
                                        as Map<String, dynamic>)['childId'],
                                  ),
                                  builder: (context, childSnapshot) {
                                    final childName =
                                        childSnapshot.data?.data() != null
                                        ? (childSnapshot.data!.data()
                                              as Map<String, dynamic>)['name']
                                        : 'Tu hijo';
                                    return Text(
                                      '$childName necesita ayuda',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: Colors.white.withOpacity(0.95),
                                      ),
                                    );
                                  },
                                )
                              else
                                Text(
                                  '${emergencies.length} emergencias activas',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: Colors.white.withOpacity(0.95),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: Colors.white,
                          size: 28,
                        ),
                      ],
                    ),
                    SizedBox(height: 12),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.touch_app, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Toca para ver detalles y ubicación',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
