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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Reportes y Alertas'),
        actions: [
          // Botón para generar nuevo reporte
          IconButton(
            icon: Icon(Icons.add_circle_outline),
            tooltip: 'Generar nuevo reporte',
            onPressed: () => _showGenerateReportDialog(context),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _firestore
            .collection('users')
            .doc(_auth.currentUser?.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return _buildEmptyState(colorScheme, isDarkMode);
          }

          final userData = snapshot.data!.data() as Map<String, dynamic>?;
          final linkedChildrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);

          if (linkedChildrenIds.isEmpty) {
            return _buildEmptyState(colorScheme, isDarkMode);
          }

          // Obtener TODOS los reportes de TODOS los hijos, ordenados por fecha
          return StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('weekly_reports')
                .where('parentId', isEqualTo: _auth.currentUser!.uid)
                .orderBy('generatedAt', descending: true)
                .snapshots(),
            builder: (context, reportsSnapshot) {
              // Manejo de errores
              if (reportsSnapshot.hasError) {
                print('❌ [ReportsScreen] Error en StreamBuilder: ${reportsSnapshot.error}');
                return Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 64, color: colorScheme.error),
                        SizedBox(height: 16),
                        Text(
                          'Error cargando reportes',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 8),
                        Text(
                          reportsSnapshot.error.toString(),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                        ),
                        SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {}); // Recargar
                          },
                          child: Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              if (reportsSnapshot.connectionState == ConnectionState.waiting) {
                return Center(child: CircularProgressIndicator());
              }

              // Logging para debug
              if (reportsSnapshot.hasData) {
                print('📊 [ReportsScreen] Reportes cargados: ${reportsSnapshot.data!.docs.length}');
              } else {
                print('⚠️ [ReportsScreen] StreamBuilder sin datos');
              }

              return CustomScrollView(
                slivers: [
                  // Sección de alertas
                  SliverToBoxAdapter(
                    child: _buildAlertsSection(),
                  ),

                  // Reportes
                  if (!reportsSnapshot.hasData || reportsSnapshot.data!.docs.isEmpty)
                    SliverFillRemaining(
                      child: _buildNoReportsState(colorScheme, isDarkMode),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.all(16),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final report = reportsSnapshot.data!.docs[index];
                            final reportData = report.data() as Map<String, dynamic>;
                            return _buildReportCard(reportData, colorScheme, isDarkMode);
                          },
                          childCount: reportsSnapshot.data!.docs.length,
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showGenerateReportDialog(context),
        icon: Icon(Icons.analytics),
        label: Text('Nuevo Reporte'),
        tooltip: 'Generar nuevo reporte',
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme, bool isDarkMode) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.assignment,
            size: 80,
            color: isDarkMode ? colorScheme.outlineVariant : colorScheme.outlineVariant.withOpacity(0.5),
          ),
          SizedBox(height: 16),
          Text(
            'No tienes hijos vinculados',
            style: TextStyle(
              fontSize: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoReportsState(ColorScheme colorScheme, bool isDarkMode) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.insert_chart_outlined,
              size: 80,
              color: isDarkMode ? colorScheme.primary.withOpacity(0.5) : colorScheme.primary.withOpacity(0.3),
            ),
            SizedBox(height: 24),
            Text(
              'No hay reportes generados',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Genera tu primer reporte usando el botón "+" arriba',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Muestra diálogo para seleccionar hijo y generar reporte
  Future<void> _showGenerateReportDialog(BuildContext context) async {
    // Obtener hijos vinculados
    final userDoc = await _firestore.collection('users').doc(_auth.currentUser!.uid).get();
    final userData = userDoc.data();
    final linkedChildrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);

    if (linkedChildrenIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No tienes hijos vinculados'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Obtener datos de los hijos
    final childrenData = <Map<String, dynamic>>[];
    for (final childId in linkedChildrenIds) {
      final childDoc = await _firestore.collection('users').doc(childId).get();
      if (childDoc.exists) {
        final data = childDoc.data() as Map<String, dynamic>;
        data['id'] = childId;
        childrenData.add(data);
      }
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Generar Reporte'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Selecciona el hijo para generar reporte:'),
            SizedBox(height: 16),
            ...childrenData.map((child) {
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: child['photoURL'] != null
                      ? NetworkImage(child['photoURL'])
                      : null,
                  child: child['photoURL'] == null
                      ? Text(
                          (child['name'] ?? 'H')[0].toUpperCase(),
                          style: TextStyle(fontWeight: FontWeight.bold),
                        )
                      : null,
                ),
                title: Text(child['name'] ?? 'Sin nombre'),
                onTap: () {
                  Navigator.pop(context);
                  _generateReport(child['id'], child['name'] ?? 'Hijo');
                },
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
        ],
      ),
    );
  }

  /// Construye una card para un reporte individual
  Widget _buildReportCard(Map<String, dynamic> reportData, ColorScheme colorScheme, bool isDarkMode) {
    final childId = reportData['childId'] as String?;

    if (childId == null) {
      return SizedBox.shrink();
    }

    return FutureBuilder<DocumentSnapshot>(
      future: _firestore.collection('users').doc(childId).get(),
      builder: (context, childSnapshot) {
        // Datos del niño
        String childName = 'Hijo';
        String? photoUrl;

        if (childSnapshot.hasData && childSnapshot.data != null && childSnapshot.data!.exists) {
          final childData = childSnapshot.data!.data() as Map<String, dynamic>?;
          childName = childData?['name'] ?? 'Hijo';
          photoUrl = childData?['photoURL'];
        }

        // Datos del reporte
        final moodIcon = reportData['moodIcon'] ?? '😐';
        final avgSentiment = (reportData['avgSentiment'] ?? 0.5) as num;
        final bullyingIncidents = reportData['bullyingIncidents'] ?? 0;
        final totalMessages = reportData['totalMessages'] ?? 0;
        final generatedAt = reportData['generatedAt'] as dynamic;

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

        // Formatear fecha
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
          margin: EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: isDarkMode ? colorScheme.surface : colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: borderColor.withValues(alpha: isDarkMode ? 0.5 : 0.3),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.08),
                blurRadius: 10,
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
                    report: reportData,
                  ),
                ),
              );
            },
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  // Avatar del niño
                  CircleAvatar(
                    radius: 28,
                    backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
                    backgroundColor: isDarkMode
                        ? colorScheme.primaryContainer
                        : colorScheme.primaryContainer,
                    child: photoUrl == null
                        ? Text(
                            childName.isNotEmpty ? childName[0].toUpperCase() : 'H',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: 16),
                  // Icono de estado de ánimo
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: borderColor.withValues(alpha: isDarkMode ? 0.2 : 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        moodIcon,
                        style: TextStyle(fontSize: 28),
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
                          childName,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          shortTitle,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: isDarkMode
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          dateText,
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                        ),
                        SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.message,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
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
                  // Flecha para indicar que es clickeable
                  Icon(
                    Icons.chevron_right,
                    color: isDarkMode
                        ? colorScheme.outlineVariant.withValues(alpha: 0.7)
                        : colorScheme.outlineVariant,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

  Future<void> _generateReport(String childId, String childName) async {
    // Capturar el contexto del widget antes de mostrar el diálogo
    final scaffoldContext = context;

    // Mostrar diálogo y capturar su contexto
    showDialog(
      context: scaffoldContext,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
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

      // Cerrar diálogo de loading de forma segura usando el contexto del scaffold
      if (mounted) {
        // Intentar cerrar el diálogo usando Navigator de forma más agresiva
        Navigator.of(scaffoldContext, rootNavigator: true).pop();
      }

      // Verificar que result.data no sea null
      final data = result.data as Map<String, dynamic>?;
      if (data == null) {
        throw Exception('No se recibió respuesta de la función');
      }

      if (data['success'] == true) {
        print('✅ Reporte generado exitosamente');

        // Dar tiempo para que Firestore propague el nuevo documento al stream
        // Esto es necesario porque hay latencia entre cuando se escribe el documento
        // y cuando llega al StreamBuilder a través de los listeners
        await Future.delayed(Duration(seconds: 2));

        // Mostrar mensaje de éxito
        if (mounted) {
          ScaffoldMessenger.of(scaffoldContext).showSnackBar(
            SnackBar(
              content: Text('✓ Reporte generado y actualizado'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }

        // El StreamBuilder debería haberse actualizado automáticamente
        // con el nuevo reporte después del delay
      } else {
        throw Exception(data['message'] ?? 'Error desconocido');
      }
    } catch (e) {
      print('❌ Error generando reporte: $e');

      // Cerrar diálogo si todavía está abierto
      if (mounted) {
        try {
          Navigator.of(scaffoldContext, rootNavigator: true).pop();
        } catch (popError) {
          print('⚠️ No se pudo cerrar el diálogo: $popError');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          SnackBar(
            content: Text('Error generando reporte: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
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
