import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Obtener alertas no leídas para un padre
  Stream<QuerySnapshot> _getUnreadAlerts(String parentId) {
    return _firestore
        .collection('alerts')
        .where('parentId', isEqualTo: parentId)
        .where('isRead', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  /// Marcar alerta como leída
  Future<void> _markAlertAsRead(String alertId) async {
    try {
      await _firestore.collection('alerts').doc(alertId).update({
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error marking alert as read: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Reportes y Alertas'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('parent_children')
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
      stream: _getUnreadAlerts(_auth.currentUser!.uid),
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
    // NO mostramos keywords para proteger privacidad

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
          SizedBox(height: 8),
          Text(
            'Se detectó lenguaje inapropiado en la conversación',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () async {
                  await _markAlertAsRead(alertId);
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
            // Botón ver historial
            IconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ReportHistoryScreen(
                      childId: childId,
                      childName: childName,
                      photoUrl: photoUrl,
                    ),
                  ),
                );
              },
              icon: Icon(Icons.history),
              color: colorScheme.primary,
              tooltip: 'Ver historial',
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
    final colorScheme = Theme.of(context).colorScheme;
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
              'El sistema detectó lenguaje inapropiado o potencialmente dañino en las conversaciones.',
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
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
              await _markAlertAsRead(alertData['messageId'] ?? '');
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: colorScheme.primary),
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
    final colorScheme = Theme.of(context).colorScheme;

    final totalMessages = report['totalMessages'] ?? 0;
    final positiveCount = report['positiveCount'] ?? 0;
    final negativeCount = report['negativeCount'] ?? 0;
    final neutralCount = report['neutralCount'] ?? 0;
    final bullyingIncidents = report['bullyingIncidents'] ?? 0;
    final percentageChange = report['percentageChange'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('Reporte de $childName'),
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
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 8),
          Text(
            report['period'] != null
                ? 'Últimos ${report['period']} días'
                : 'Última semana',
            style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
          ),

          SizedBox(height: 32),

          // Resumen ejecutivo
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
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
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  report['moodStatus'] ?? 'neutral',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
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
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),

          _buildDetailRow('Total de mensajes', '$totalMessages', Icons.message, colorScheme),
          _buildDetailRow(
            'Mensajes positivos',
            '$positiveCount (${_getPercentage(positiveCount, totalMessages)}%)',
            Icons.sentiment_satisfied,
            colorScheme,
            Colors.green,
          ),
          _buildDetailRow(
            'Mensajes negativos',
            '$negativeCount (${_getPercentage(negativeCount, totalMessages)}%)',
            Icons.sentiment_dissatisfied,
            colorScheme,
            Colors.orange,
          ),
          _buildDetailRow(
            'Mensajes neutrales',
            '$neutralCount (${_getPercentage(neutralCount, totalMessages)}%)',
            Icons.sentiment_neutral,
            colorScheme,
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
              color: colorScheme.onSurface,
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
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),

          _buildRecommendation(report, colorScheme),

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
    IconData icon,
    ColorScheme colorScheme, [
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
          Icon(icon, color: color ?? colorScheme.primary),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 16, color: colorScheme.onSurface),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: color ?? colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendation(Map<String, dynamic> report, ColorScheme colorScheme) {
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
                color: colorScheme.onSurface,
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

// Pantalla de historial de reportes
class ReportHistoryScreen extends StatelessWidget {
  final String childId;
  final String childName;
  final String? photoUrl;

  const ReportHistoryScreen({
    super.key,
    required this.childId,
    required this.childName,
    this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Historial de $childName'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('weekly_reports')
            .where('childId', isEqualTo: childId)
            .where('parentId', isEqualTo: FirebaseAuth.instance.currentUser!.uid)
            .orderBy('generatedAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64, color: colorScheme.error),
                  SizedBox(height: 16),
                  Text(
                    'Error cargando reportes',
                    style: TextStyle(fontSize: 16, color: colorScheme.error),
                  ),
                  SizedBox(height: 8),
                  Text(
                    snapshot.error.toString(),
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 80, color: colorScheme.outlineVariant),
                  SizedBox(height: 16),
                  Text(
                    'No hay reportes disponibles',
                    style: TextStyle(fontSize: 18, color: colorScheme.onSurfaceVariant),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Los reportes generados aparecerán aquí',
                    style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            );
          }

          final reports = snapshot.data!.docs;

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: reports.length,
            itemBuilder: (context, index) {
              final reportDoc = reports[index];
              final report = reportDoc.data() as Map<String, dynamic>;

              return _buildReportCard(context, report, colorScheme);
            },
          );
        },
      ),
    );
  }

  Widget _buildReportCard(
    BuildContext context,
    Map<String, dynamic> report,
    ColorScheme colorScheme,
  ) {
    final moodIcon = report['moodIcon'] ?? '😐';
    final avgSentiment = (report['avgSentiment'] ?? 0.5) as num;
    final bullyingIncidents = report['bullyingIncidents'] ?? 0;
    final totalMessages = report['totalMessages'] ?? 0;
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
        } else if (diff.inDays < 30) {
          dateText = 'Hace ${(diff.inDays / 7).floor()} semanas';
        } else {
          dateText = '${date.day}/${date.month}/${date.year}';
        }
      } catch (e) {
        dateText = 'Fecha desconocida';
      }
    }

    // Color del borde según estado
    Color borderColor;
    if (bullyingIncidents > 0) {
      borderColor = Colors.red;
    } else if (avgSentiment >= 0.7) {
      borderColor = Colors.green;
    } else if (avgSentiment >= 0.5) {
      borderColor = Colors.blue;
    } else if (avgSentiment >= 0.3) {
      borderColor = Colors.orange;
    } else {
      borderColor = Colors.red.shade300;
    }

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor.withValues(alpha: 0.3), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
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
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              // Icono de estado de ánimo
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: borderColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    moodIcon,
                    style: TextStyle(fontSize: 32),
                  ),
                ),
              ),
              SizedBox(width: 16),
              // Información del reporte
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      dateText,
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.message, size: 14, color: colorScheme.onSurfaceVariant),
                        SizedBox(width: 4),
                        Text(
                          '$totalMessages mensajes',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (bullyingIncidents > 0) ...[
                          SizedBox(width: 12),
                          Icon(Icons.warning, size: 14, color: Colors.red),
                          SizedBox(width: 4),
                          Text(
                            '$bullyingIncidents alertas',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Flecha
              Icon(Icons.chevron_right, color: colorScheme.outlineVariant),
            ],
          ),
        ),
      ),
    );
  }
}
