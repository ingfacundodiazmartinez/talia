import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'ai_analysis_service.dart';
import 'package:cloud_functions/cloud_functions.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AIAnalysisService _aiService = AIAnalysisService();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Reportes y Alertas'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('parent_child_links')
            .where('parentId', isEqualTo: _auth.currentUser?.uid)
            .where('status', isEqualTo: 'approved')
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
                  Icon(Icons.assignment, size: 80, color: colorScheme.outlineVariant),
                  SizedBox(height: 16),
                  Text(
                    'No tienes hijos vinculados',
                    style: TextStyle(fontSize: 18, color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            );
          }

          return ListView(
            padding: EdgeInsets.all(16),
            children: [
              _buildAlertsSection(),
              SizedBox(height: 24),
              ...snapshot.data!.docs.map((doc) {
                final childId = doc['childId'];
                return FutureBuilder<DocumentSnapshot>(
                  future: _firestore.collection('users').doc(childId).get(),
                  builder: (context, userSnapshot) {
                    if (!userSnapshot.hasData) return SizedBox();

                    final userData =
                        userSnapshot.data!.data() as Map<String, dynamic>?;
                    final childName = userData?['name'] ?? 'Hijo';

                    return _buildChildReportCard(childId, childName);
                  },
                );
              }),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAlertsSection() {
    return StreamBuilder<QuerySnapshot>(
      stream: _aiService.getUnreadAlerts(_auth.currentUser!.uid),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '⚠️ Alertas Importantes',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
            SizedBox(height: 12),
            ...snapshot.data!.docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return _buildAlertCard(doc.id, data);
            }),
            SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Widget _buildAlertCard(String alertId, Map<String, dynamic> data) {
    // final type = data['type'] ?? 'unknown';
    final severity = (data['severity'] ?? 0.0) as double;
    final keywords = List<String>.from(data['keywords'] ?? []);

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.3), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning, color: Colors.red, size: 24),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Posible Bullying Detectado',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.red[800],
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            'Severidad: ${(severity * 100).toInt()}%',
            style: TextStyle(fontSize: 14, color: Colors.grey[700]),
          ),
          if (keywords.isNotEmpty) ...[
            SizedBox(height: 8),
            Text(
              'Palabras detectadas: ${keywords.take(3).join(", ")}${keywords.length > 3 ? "..." : ""}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
          SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () async {
                  await _aiService.markAlertAsRead(alertId);
                },
                child: Text('Marcar como leída'),
              ),
              SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  // Ver detalles del mensaje
                  _showAlertDetails(data);
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: Text('Ver detalles'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChildReportCard(String childId, String childName) {
    final colorScheme = Theme.of(context).colorScheme;

    return FutureBuilder<DocumentSnapshot>(
      future: _firestore.collection('users').doc(childId).get(),
      builder: (context, userSnapshot) {
        String? photoUrl;
        if (userSnapshot.hasData && userSnapshot.data != null) {
          final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
          photoUrl = userData?['photoUrl'];
        }

        return Container(
          margin: EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('weekly_reports')
                .where('childId', isEqualTo: childId)
                .where('parentId', isEqualTo: _auth.currentUser!.uid)
                .orderBy('generatedAt', descending: true)
                .limit(1)
                .snapshots(),
            builder: (context, snapshot) {

              if (snapshot.connectionState == ConnectionState.waiting) {
                return Padding(
                  padding: EdgeInsets.all(20),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
                        child: photoUrl == null
                            ? Text(
                                childName.isNotEmpty ? childName[0].toUpperCase() : 'H',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                              )
                            : null,
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          childName,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                      ),
                      CircularProgressIndicator(),
                    ],
                  ),
                );
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return Padding(
                  padding: EdgeInsets.all(20),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
                        child: photoUrl == null
                            ? Text(
                                childName.isNotEmpty ? childName[0].toUpperCase() : 'H',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                              )
                            : null,
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              childName,
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'No hay reportes disponibles',
                              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _generateReport(childId, childName),
                        icon: Icon(Icons.add, size: 18),
                        label: Text('Generar'),
                        style: TextButton.styleFrom(
                          foregroundColor: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                );
              }

              final report =
                  snapshot.data!.docs.first.data() as Map<String, dynamic>;
              return _buildReportContent(childId, childName, report, photoUrl);
            },
          ),
        );
      },
    );
  }

  Widget _buildReportContent(
    String childId,
    String childName,
    Map<String, dynamic> report,
    String? photoUrl,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final moodIcon = report['moodIcon'] ?? '😐';
    final avgSentiment = (report['avgSentiment'] ?? 0.5) as num;
    final bullyingIncidents = report['bullyingIncidents'] ?? 0;
    final generatedAt = report['generatedAt'] as dynamic;

    // Generar título corto basado en sentimiento
    String shortTitle;
    if (bullyingIncidents > 0) {
      shortTitle = 'Alerta detectada';
    } else if (avgSentiment >= 0.7) {
      shortTitle = 'Período excelente';
    } else if (avgSentiment >= 0.5) {
      shortTitle = 'Período positivo';
    } else if (avgSentiment >= 0.3) {
      shortTitle = 'Período neutral';
    } else {
      shortTitle = 'Período preocupante';
    }

    String dateText = 'Fecha desconocida';
    if (generatedAt != null) {
      try {
        DateTime date;
        if (generatedAt is String) {
          date = DateTime.parse(generatedAt);
        } else {
          date = (generatedAt as Timestamp).toDate();
        }
        final now = DateTime.now();
        final diff = now.difference(date);
        if (diff.inDays == 0) {
          dateText = 'Hoy';
        } else if (diff.inDays == 1) {
          dateText = 'Ayer';
        } else if (diff.inDays < 7) {
          dateText = 'Hace ${diff.inDays} días';
        } else {
          dateText = '${date.day}/${date.month}/${date.year}';
        }
      } catch (e) {
        dateText = 'Fecha desconocida';
      }
    }

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DetailedReportScreen(
              childId: childId,
              childName: childName,
              report: report,
            ),
          ),
        );
      },
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            // Foto del niño
            CircleAvatar(
              radius: 28,
              backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
              child: photoUrl == null
                  ? Text(
                      childName.isNotEmpty ? childName[0].toUpperCase() : 'H',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    )
                  : null,
            ),
            SizedBox(width: 12),
            // Info del reporte
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    childName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: 2),
                  Row(
                    children: [
                      Text(moodIcon, style: TextStyle(fontSize: 16)),
                      SizedBox(width: 6),
                      Text(
                        shortTitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 2),
                  Text(
                    dateText,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            // Botón actualizar
            IconButton(
              onPressed: () => _generateReport(childId, childName),
              icon: Icon(Icons.refresh),
              color: colorScheme.primary,
              tooltip: 'Actualizar reporte',
            ),
            // Flecha para ver más
            Icon(Icons.chevron_right, color: colorScheme.outlineVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildStatBox({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Future<void> _generateReport(String childId, String childName) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Generando reporte con IA...'),
            Text('Esto puede tardar 30-60 segundos', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );

    try {
      print('📊 Llamando a Cloud Function generateChildReport');
      
      // Llamar a la Cloud Function
      final callable = FirebaseFunctions.instance.httpsCallable('generateChildReport');
      final result = await callable.call({
        'childId': childId,
        'daysBack': 7,
      });

      Navigator.pop(context); // Cerrar diálogo de loading

      if (result.data['success'] == true) {
        print('✅ Reporte generado exitosamente');
        
        // Mostrar mensaje de éxito
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Reporte generado exitosamente'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );

        // Esperar un momento y recargar datos
        await Future.delayed(Duration(seconds: 1));
        setState(() {}); // Recargar la pantalla
      } else {
        throw Exception(result.data['message'] ?? 'Error desconocido');
      }
    } catch (e) {
      print('❌ Error generando reporte: $e');
      Navigator.pop(context); // Cerrar diálogo si está abierto
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error generando reporte: ${e.toString()}'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  void _showAlertDetails(Map<String, dynamic> alertData) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.red),
            SizedBox(width: 8),
            Text('Alerta de Bullying'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Se detectó posible bullying en un mensaje.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              'Severidad: ${((alertData['severity'] ?? 0.0) * 100).toInt()}%',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 12),
            Text(
              'Palabras detectadas:',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 4),
            ...List<String>.from(alertData['keywords'] ?? []).map(
              (keyword) =>
                  Text('• $keyword', style: TextStyle(color: Colors.red)),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Te recomendamos hablar con tu hijo sobre esta situación.',
                      style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _aiService.markAlertAsRead(alertData['messageId'] ?? '');
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Color(0xFF9D7FE8)),
            child: Text('Marcar como leída'),
          ),
        ],
      ),
    );
  }
}

// Pantalla de reporte detallado
class DetailedReportScreen extends StatelessWidget {
  final String childId;
  final String childName;
  final Map<String, dynamic> report;

  const DetailedReportScreen({
    super.key,
    required this.childId,
    required this.childName,
    required this.report,
  });

  @override
  Widget build(BuildContext context) {
    final totalMessages = report['totalMessages'] ?? 0;
    final positiveCount = report['positiveCount'] ?? 0;
    final negativeCount = report['negativeCount'] ?? 0;
    final neutralCount = report['neutralCount'] ?? 0;
    final bullyingIncidents = report['bullyingIncidents'] ?? 0;
    final percentageChange = report['percentageChange'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('Reporte de $childName'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Título y periodo
          Text(
            'Reporte Semanal',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 8),
          Text(
            report['period'] != null
                ? 'Últimos ${report['period']} días'
                : 'Última semana',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),

          SizedBox(height: 32),

          // Resumen ejecutivo
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  report['moodIcon'] ?? '😐',
                  style: TextStyle(fontSize: 80),
                ),
                SizedBox(height: 16),
                Text(
                  'Estado de ánimo general',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white.withOpacity(0.9),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  report['moodStatus'] ?? 'neutral',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 24),

          // Estadísticas detalladas
          Text(
            'Estadísticas Detalladas',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildDetailRow('Total de mensajes', '$totalMessages', Icons.message),
          _buildDetailRow(
            'Mensajes positivos',
            '$positiveCount (${_getPercentage(positiveCount, totalMessages)}%)',
            Icons.sentiment_satisfied,
            Colors.green,
          ),
          _buildDetailRow(
            'Mensajes negativos',
            '$negativeCount (${_getPercentage(negativeCount, totalMessages)}%)',
            Icons.sentiment_dissatisfied,
            Colors.orange,
          ),
          _buildDetailRow(
            'Mensajes neutrales',
            '$neutralCount (${_getPercentage(neutralCount, totalMessages)}%)',
            Icons.sentiment_neutral,
            Colors.grey,
          ),

          SizedBox(height: 24),

          // Alerta de bullying
          if (bullyingIncidents > 0) ...[
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning, color: Colors.red, size: 32),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Incidentes de Bullying',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.red[800],
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Se detectaron $bullyingIncidents posibles casos de bullying',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 24),
          ],

          // Comparación con semana anterior
          Text(
            'Comparación',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  percentageChange > 0
                      ? Icons.trending_up
                      : Icons.trending_down,
                  color: percentageChange > 0
                      ? Colors.green
                      : Colors.orange,
                  size: 32,
                ),
                SizedBox(width: 12),
                Text(
                  '${percentageChange > 0 ? '+' : ''}$percentageChange%',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: percentageChange > 0
                        ? Colors.green
                        : Colors.orange,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'vs semana\nanterior',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          SizedBox(height: 32),

          // Recomendaciones
          Text(
            'Recomendaciones',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildRecommendation(report),

          SizedBox(height: 32),

          // Disclaimer
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.grey[600], size: 20),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Este reporte es una guía basada en análisis automático. Te recomendamos mantener comunicación abierta con tu hijo.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
    String label,
    String value,
    IconData icon, [
    Color? color,
  ]) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color ?? Color(0xFF9D7FE8)),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 16, color: Color(0xFF2D3142)),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: color ?? Color(0xFF2D3142),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendation(Map<String, dynamic> report) {
    final moodStatus = report['moodStatus'] ?? 'neutral';
    final bullyingIncidents = report['bullyingIncidents'] ?? 0;
    final percentageChange = report['percentageChange'] ?? 0;

    String recommendation;
    IconData icon;
    Color color;

    if (bullyingIncidents > 0) {
      recommendation =
          '⚠️ Se detectaron incidentes de bullying. Te recomendamos hablar con tu hijo sobre sus conversaciones y brindarle apoyo emocional.';
      icon = Icons.warning;
      color = Colors.red;
    } else if (moodStatus == 'muy negativo' || percentageChange < -30) {
      recommendation =
          '😔 El estado de ánimo de tu hijo es negativo. Considera tener una conversación para conocer cómo se siente.';
      icon = Icons.sentiment_dissatisfied;
      color = Colors.orange;
    } else if (moodStatus == 'muy positivo' || percentageChange > 30) {
      recommendation =
          '😊 ¡Excelente! Tu hijo mantiene un estado de ánimo positivo. Continúa fomentando una comunicación sana.';
      icon = Icons.sentiment_satisfied;
      color = Colors.green;
    } else {
      recommendation =
          '👍 Todo parece estar bien. Mantén la comunicación abierta con tu hijo y sigue monitoreando su bienestar.';
      icon = Icons.check_circle;
      color = Colors.blue;
    }

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              recommendation,
              style: TextStyle(
                fontSize: 15,
                color: Color(0xFF2D3142),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  int _getPercentage(int count, int total) {
    if (total == 0) return 0;
    return ((count / total) * 100).round();
  }
}
