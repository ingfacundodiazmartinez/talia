import 'package:flutter/material.dart';
import '../../../../reports_screen.dart';

/// Widget de acceso rápido a reportes con IA
///
/// Responsabilidades:
/// - Mostrar información sobre reportes disponibles
/// - Navegar a la pantalla de reportes
///
/// Contenido:
/// - Análisis de sentimientos
/// - Detección de bullying
/// - Reportes semanales automáticos
class WeeklyReportWidget extends StatelessWidget {
  const WeeklyReportWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Reportes con IA',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          Text(
            'Análisis de sentimientos, detección de bullying y reportes semanales automáticos.',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.9),
            ),
          ),
          SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => ReportsScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Color(0xFF9D7FE8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text('Ver Reportes y Alertas'),
          ),
        ],
      ),
    );
  }
}
