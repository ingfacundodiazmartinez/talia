import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../services/emergency_service.dart';
import '../../../../models/user.dart';
import '../../../emergency_detail_screen.dart';
import '../../../../utils/release_logger.dart';

/// Widget que muestra alertas de emergencias activas
///
/// Responsabilidades:
/// - Escuchar emergencias activas del padre
/// - Mostrar badge visual prominente cuando hay emergencias
/// - Navegar a detalle de emergencia al tocar
///
/// Se muestra solo cuando hay emergencias activas, sino retorna SizedBox.shrink()
class EmergencyAlertWidget extends StatefulWidget {
  final String parentId;

  const EmergencyAlertWidget({
    super.key,
    required this.parentId,
  });

  @override
  State<EmergencyAlertWidget> createState() => _EmergencyAlertWidgetState();
}

class _EmergencyAlertWidgetState extends State<EmergencyAlertWidget> {
  List<QueryDocumentSnapshot>? _cachedEmergencies;
  late final EmergencyService _emergencyService;

  @override
  void initState() {
    super.initState();
    _emergencyService = EmergencyService();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _emergencyService.getActiveEmergenciesForParent(widget.parentId),
      builder: (context, snapshot) {
        // ✅ OPTIMIZACIÓN: Usar cache cuando no hay datos nuevos
        if (snapshot.connectionState == ConnectionState.waiting && _cachedEmergencies != null) {
          return _buildEmergencyWidget(_cachedEmergencies!);
        }

        if (snapshot.hasData) {
          // ✅ OPTIMIZACIÓN: Solo actualizar cache si los datos realmente cambiaron
          final newEmergencies = snapshot.data!.docs;
          if (_hasEmergenciesChanged(newEmergencies)) {
            _cachedEmergencies = newEmergencies;
          } else {
            // ✅ OPTIMIZACIÓN: Si los datos no han cambiado, no rebuildeamos
            return _buildEmergencyWidget(_cachedEmergencies!);
          }

          return _buildEmergencyWidget(_cachedEmergencies!);
        }

        if (snapshot.hasError) {
          ReleaseLogger.error('Error in EmergencyAlertWidget: ${snapshot.error}', tag: 'EmergencyAlertWidget');
          return SizedBox.shrink();
        }

        if (!snapshot.hasData) {
          // Si no hay datos y tenemos cache, usar cache
          if (_cachedEmergencies != null) {
            return _buildEmergencyWidget(_cachedEmergencies!);
          }
          // Si no hay datos ni cache, mostrar vacío
          return SizedBox.shrink();
        }

        // Datos vacíos
        if (snapshot.data!.docs.isEmpty) {
          _cachedEmergencies = [];
          return SizedBox.shrink();
        }

        // No debería llegar aquí, pero por seguridad
        return _buildEmergencyWidget(_cachedEmergencies ?? []);
      },
    );
  }

  /// Verificar si las emergencias han cambiado realmente
  bool _hasEmergenciesChanged(List<QueryDocumentSnapshot> newEmergencies) {
    if (_cachedEmergencies == null) return true;
    if (_cachedEmergencies!.length != newEmergencies.length) return true;

    // Comparar IDs de documentos y datos principales
    for (int i = 0; i < _cachedEmergencies!.length; i++) {
      final cachedDoc = _cachedEmergencies![i];
      final newDoc = newEmergencies[i];

      // Comparar ID
      if (cachedDoc.id != newDoc.id) return true;

      // Comparar datos principales que afectan la UI
      final cachedData = cachedDoc.data() as Map<String, dynamic>?;
      final newData = newDoc.data() as Map<String, dynamic>?;

      if (cachedData?['childId'] != newData?['childId']) return true;
      if (cachedData?['status'] != newData?['status']) return true;
      if (cachedData?['timestamp'] != newData?['timestamp']) return true;
    }

    return false;
  }

  /// Construir el widget de emergencias
  Widget _buildEmergencyWidget(List<QueryDocumentSnapshot> emergencies) {
    if (emergencies.isEmpty) {
      return SizedBox.shrink();
    }

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
                final emergencyData = emergency.data() as Map<String, dynamic>;

                try {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) {
                        return EmergencyDetailScreen(
                          emergencyId: emergency.id,
                          emergencyData: emergencyData,
                        );
                      },
                    ),
                  );
                } catch (e, stackTrace) {
                  ReleaseLogger.error('Error navigating to emergency detail: $e\nStack: $stackTrace', tag: 'EmergencyAlertWidget');
                }
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
  }
}
