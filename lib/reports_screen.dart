import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'utils/release_logger.dart';
import 'services/ad_service.dart';
import 'services/app_config_service.dart';
import 'services/subscription_service.dart';
import 'services/usage_limits_service.dart';
import 'widgets/premium_paywall_dialog.dart';
import 'screens/settings/subscription_screen.dart';

class ReportsScreen extends StatefulWidget {
  /// Opcional: si se proporciona, filtra alertas y reportes solo de este hijo
  final String? childId;
  final FirebaseAuth? auth;
  final FirebaseFirestore? firestore;

  const ReportsScreen({super.key, this.childId, this.auth, this.firestore});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late final FirebaseAuth _auth;
  late final FirebaseFirestore _firestore;
  final AdService _adService = AdService();
  final UsageLimitsService _usageLimitsService = UsageLimitsService();

  @override
  void initState() {
    super.initState();
    _auth = widget.auth ?? FirebaseAuth.instance;
    _firestore = widget.firestore ?? FirebaseFirestore.instance;
    // Pre-cargar Rewarded Ad para cuando el usuario quiera generar un reporte
    _adService.loadRewardedAd();
  }

  /// Obtener alertas no leídas para un padre
  /// Si widget.childId está presente, filtra solo alertas de ese hijo
  Stream<QuerySnapshot> _getUnreadAlerts(String parentId) {
    ReleaseLogger.log('Consultando alertas - parentId: $parentId, childId: ${widget.childId}', tag: 'ReportsScreen');

    var query = _firestore
        .collection('alerts')
        .where('parentId', isEqualTo: parentId)
        .where('isRead', isEqualTo: false);

    // ✅ Si hay childId, filtrar solo alertas de ese hijo
    if (widget.childId != null) {
      query = query.where('childId', isEqualTo: widget.childId);
      ReleaseLogger.log('Filtrando por childId: ${widget.childId}', tag: 'ReportsScreen');
    }

    return query.orderBy('createdAt', descending: true).snapshots().map((snapshot) {
      ReleaseLogger.log('Encontradas ${snapshot.docs.length} alertas', tag: 'ReportsScreen');
      if (snapshot.docs.isNotEmpty) {
        ReleaseLogger.log('Primera alerta: ${snapshot.docs.first.data()}', tag: 'ReportsScreen');
      }
      return snapshot;
    });
  }

  /// Marcar alerta como leída
  Future<void> _markAlertAsRead(String alertId) async {
    try {
      await _firestore.collection('alerts').doc(alertId).update({
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error('Error marking alert as read: $e', tag: 'ReportsScreen');
    }
  }

  /// Eliminar un reporte
  Future<void> _deleteReport(String reportId, String childName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_outline, size: 48, color: Colors.red),
        title: Text('Eliminar reporte'),
        content: Text(
          '¿Estás seguro de que quieres eliminar este reporte de $childName? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _firestore.collection('weekly_reports').doc(reportId).delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Reporte eliminado'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        ReleaseLogger.error('Error eliminando reporte: $e', tag: 'ReportsScreen');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al eliminar el reporte'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  /// Mostrar opciones del reporte (eliminar, etc.)
  void _showReportOptions(String reportId, String childName) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red),
              title: Text('Eliminar reporte', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteReport(reportId, childName);
              },
            ),
            ListTile(
              leading: Icon(Icons.close),
              title: Text('Cancelar'),
              onTap: () => Navigator.pop(sheetContext),
            ),
          ],
        ),
      ),
    );
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

          // Obtener reportes del padre (filtrados por hijo si se especifica)
          var reportsQuery = _firestore
              .collection('weekly_reports')
              .where('parentId', isEqualTo: _auth.currentUser!.uid);

          // ✅ Si hay childId, filtrar solo reportes de ese hijo
          if (widget.childId != null) {
            reportsQuery = reportsQuery.where('childId', isEqualTo: widget.childId);
          }

          return StreamBuilder<QuerySnapshot>(
            // ✅ Limitar a 50 reportes más recientes para evitar problemas de rendimiento
            stream: reportsQuery.orderBy('generatedAt', descending: true).limit(50).snapshots(),
            builder: (context, reportsSnapshot) {
              // Manejo de errores
              if (reportsSnapshot.hasError) {
                ReleaseLogger.error('Error en StreamBuilder: ${reportsSnapshot.error}', tag: 'ReportsScreen');
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
                ReleaseLogger.log('Reportes cargados: ${reportsSnapshot.data!.docs.length}', tag: 'ReportsScreen');
              } else {
                ReleaseLogger.log('StreamBuilder sin datos', tag: 'ReportsScreen');
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
                            return _buildReportCard(report.id, reportData, colorScheme, isDarkMode);
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
            color: isDarkMode ? colorScheme.outlineVariant : colorScheme.outlineVariant.withValues(alpha: 0.5),
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
              color: isDarkMode ? colorScheme.primary.withValues(alpha: 0.5) : colorScheme.primary.withValues(alpha: 0.3),
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
      if (mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No tienes hijos vinculados'),
            backgroundColor: Colors.orange,
          ),
        );
      }
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
      // ignore: use_build_context_synchronously
      context: context,
      builder: (dialogContext) {
        final dialogColorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
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
                  radius: 20,
                  backgroundColor: dialogColorScheme.primaryContainer,
                  child: child['photoURL'] != null
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: child['photoURL'],
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Icon(Icons.person),
                            errorWidget: (context, url, error) => Icon(Icons.person),
                          ),
                        )
                      : Text(
                          (child['name'] ?? 'H')[0].toUpperCase(),
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
                title: Text(child['name'] ?? 'Sin nombre'),
                onTap: () async {
                  final childId = child['id'] as String;
                  final childName = child['name'] as String? ?? 'Hijo';
                  ReleaseLogger.log('Seleccionado hijo: $childName ($childId)', tag: 'ReportsScreen');
                  Navigator.pop(dialogContext);
                  // Pequeño delay para asegurar que el dialog se cerró completamente
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (mounted) {
                    _generateReport(childId, childName);
                  }
                },
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancelar'),
          ),
        ],
      );
      },
    );
  }

  /// Construye una card para un reporte individual
  Widget _buildReportCard(String reportId, Map<String, dynamic> reportData, ColorScheme colorScheme, bool isDarkMode) {
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

        // Diseño limpio sin borde
        return Container(
          margin: EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isDarkMode ? colorScheme.surfaceContainerHighest : colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDarkMode ? 0.2 : 0.06),
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
                    report: reportData,
                  ),
                ),
              );
            },
            onLongPress: () => _showReportOptions(reportId, childName),
            borderRadius: BorderRadius.circular(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Row(
                children: [
                  // Indicador de estado (barra lateral sutil)
                  Container(
                    width: 4,
                    height: 90,
                    color: borderColor,
                  ),
                  // Contenido principal
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          // Avatar del niño con emoji superpuesto
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              CircleAvatar(
                                radius: 26,
                                backgroundColor: colorScheme.primaryContainer,
                                child: photoUrl != null
                                    ? ClipOval(
                                        child: CachedNetworkImage(
                                          imageUrl: photoUrl,
                                          width: 52,
                                          height: 52,
                                          fit: BoxFit.cover,
                                          placeholder: (context, url) => Icon(Icons.person, size: 26, color: colorScheme.onPrimaryContainer),
                                          errorWidget: (context, url, error) => Icon(Icons.person, size: 26, color: colorScheme.onPrimaryContainer),
                                        ),
                                      )
                                    : Text(
                                        childName.isNotEmpty ? childName[0].toUpperCase() : 'H',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: colorScheme.onPrimaryContainer,
                                        ),
                                      ),
                              ),
                              // Emoji de estado de ánimo como badge
                              Positioned(
                                right: -6,
                                bottom: -4,
                                child: Container(
                                  padding: EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: isDarkMode ? colorScheme.surfaceContainerHighest : colorScheme.surface,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(moodIcon, style: TextStyle(fontSize: 18)),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(width: 14),
                          // Información del reporte
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        childName,
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: colorScheme.onSurface,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      dateText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 4),
                                Text(
                                  shortTitle,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: borderColor,
                                  ),
                                ),
                                SizedBox(height: 6),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.message_outlined,
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
                                      SizedBox(width: 10),
                                      Container(
                                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.red.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.warning_rounded, size: 12, color: Colors.red),
                                            SizedBox(width: 3),
                                            Text(
                                              '$bullyingIncidents',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.red,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 8),
                          // Flecha
                          Icon(
                            Icons.chevron_right,
                            color: colorScheme.outlineVariant,
                            size: 24,
                          ),
                        ],
                      ),
                    ),
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
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return StreamBuilder<QuerySnapshot>(
      stream: _getUnreadAlerts(_auth.currentUser!.uid),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return SizedBox.shrink();
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.warning_rounded, color: Colors.red, size: 20),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Alertas Importantes',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(width: 8),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${snapshot.data!.docs.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12),
              ...snapshot.data!.docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return _buildAlertCard(doc.id, data, colorScheme, isDarkMode);
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAlertCard(String alertId, Map<String, dynamic> data, ColorScheme colorScheme, bool isDarkMode) {
    final severity = (data['severity'] ?? 0.0) as double;
    final createdAt = data['createdAt'] as dynamic;

    // Formatear fecha
    String timeText = '';
    if (createdAt != null) {
      try {
        DateTime date;
        if (createdAt is String) {
          date = DateTime.parse(createdAt);
        } else {
          date = (createdAt as Timestamp).toDate();
        }
        final now = DateTime.now();
        final diff = now.difference(date);
        if (diff.inMinutes < 60) {
          timeText = 'Hace ${diff.inMinutes} min';
        } else if (diff.inHours < 24) {
          timeText = 'Hace ${diff.inHours}h';
        } else if (diff.inDays == 1) {
          timeText = 'Ayer';
        } else {
          timeText = 'Hace ${diff.inDays} días';
        }
      } catch (e) {
        timeText = '';
      }
    }

    // Color según severidad
    final severityColor = severity > 0.7 ? Colors.red : (severity > 0.4 ? Colors.orange : Colors.amber);

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDarkMode ? colorScheme.surfaceContainerHighest : colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.2 : 0.06),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Row(
          children: [
            // Indicador lateral rojo
            Container(
              width: 4,
              height: 100,
              color: Colors.red,
            ),
            // Contenido
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Posible Bullying Detectado',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (timeText.isNotEmpty)
                          Text(
                            timeText,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Se detectó lenguaje inapropiado en la conversación',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        // Indicador de severidad
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: severityColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                severity > 0.7 ? Icons.error : (severity > 0.4 ? Icons.warning : Icons.info),
                                size: 14,
                                color: severityColor,
                              ),
                              SizedBox(width: 4),
                              Text(
                                '${(severity * 100).toInt()}%',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: severityColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Spacer(),
                        // Botones de acción
                        TextButton(
                          onPressed: () async {
                            await _markAlertAsRead(alertId);
                          },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text('Ignorar', style: TextStyle(fontSize: 13)),
                        ),
                        SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            _showAlertDetails(data);
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text('Ver más', style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateReport(String childId, String childName) async {
    ReleaseLogger.log('_generateReport llamado para $childName ($childId)', tag: 'ReportsScreen');
    final scaffoldContext = context;

    // ✅ PASO 1: Verificar status Premium y límites de uso
    ReleaseLogger.log('Verificando status Premium y límites...', tag: 'ReportsScreen');
    final premiumStatus = await SubscriptionService().checkPremiumStatus();
    final usageData = await _usageLimitsService.getReportsMonthlyUsage();
    final remaining = usageData['remaining'] as int;
    final limit = usageData['limit'] as int;
    final tier = usageData['tier'] as String;

    ReleaseLogger.log('isPremium=${premiumStatus.isPremium}, tier=$tier, remaining=$remaining/$limit', tag: 'ReportsScreen');

    // ✅ PASO 2: Si es Premium/Premium+ pero llegó al límite mensual, mostrar paywall
    if (premiumStatus.isPremium && remaining <= 0) {
      if (mounted) {
        ReleaseLogger.log('Usuario $tier alcanzó límite de reportes ($limit/mes)', tag: 'ReportsScreen');
        PremiumPaywallDialog.show(
          context,
          feature: PremiumFeature(
            id: 'reports_limit',
            name: 'Reportes mensuales',
            description: 'Has alcanzado el límite de $limit reportes este mes. Actualiza a Premium+ para obtener más reportes mensuales.',
            iconName: '📊',
            requiredTier: SubscriptionTier.premiumPlus,
          ),
        );
      }
      return;
    }

    final needsRewardedAd = !premiumStatus.isPremium;

    // ✅ PASO 3: Si no es Premium, mostrar dialog de Rewarded Video con opción Premium
    if (needsRewardedAd && mounted) {
      ReleaseLogger.log('Usuario FREE, mostrando dialog de Rewarded Ad...', tag: 'ReportsScreen');
      // ignore: use_build_context_synchronously
      final shouldProceed = await _showRewardedAdDialog(scaffoldContext, childName);
      ReleaseLogger.log('_showRewardedAdDialog retornó: $shouldProceed', tag: 'ReportsScreen');
      if (!shouldProceed) {
        ReleaseLogger.log('Usuario canceló o no completó el video, abortando', tag: 'ReportsScreen');
        return; // Usuario canceló o no completó el video
      }
    }

    // ✅ PASO 3: Mostrar dialog de "en proceso" (después de ver el video)
    if (mounted) {
      // ignore: use_build_context_synchronously
      showDialog(
        // ignore: use_build_context_synchronously
        context: scaffoldContext,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(Icons.access_time, size: 48, color: Colors.blue),
          title: Text('Reporte en proceso'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Estamos generando el reporte de $childName. Te notificaremos cuando esté listo.',
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.notifications_active, color: Colors.blue, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Recibirás una notificación cuando esté listo',
                        style: TextStyle(fontSize: 13, color: Colors.blue[800]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Entendido'),
            ),
          ],
        ),
      );
    }

    // Llamar a la Cloud Function en background (no bloquea la UI)
    // ignore: use_build_context_synchronously
    _callGenerateReportInBackground(childId, childName, scaffoldContext);
  }

  /// Muestra el dialog de Rewarded Video para usuarios FREE
  /// Retorna true si el usuario completó el video, false si canceló o eligió premium
  Future<bool> _showRewardedAdDialog(BuildContext scaffoldContext, String childName) async {
    ReleaseLogger.log('Iniciando _showRewardedAdDialog para $childName', tag: 'ReportsScreen');

    // Mostrar dialog inicial con opción Premium
    final dialogResult = await showDialog<String>(
      context: scaffoldContext,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: BoxConstraints(maxWidth: 340),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1E1E2E),
                Color(0xFF2D2D44),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header con icono
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: 28),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF6A1B9A),
                      Color(0xFF9C27B0),
                    ],
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(24),
                    topRight: Radius.circular(24),
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 40,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Generar Reporte',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),

              // Contenido
              Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(
                      'Ve un breve video para generar el reporte de $childName',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.9),
                        height: 1.4,
                      ),
                    ),
                    SizedBox(height: 20),

                    // Info de duración
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.timer_outlined, color: Colors.white70, size: 18),
                          SizedBox(width: 8),
                          Text(
                            '15-30 segundos',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 24),

                    // Botón Ver Video (Principal)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(dialogContext, 'watch'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Color(0xFF4CAF50),
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.play_circle_filled, size: 22),
                            SizedBox(width: 10),
                            Text(
                              'Ver Video',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 12),

                    // Sección Premium (solo si el sistema premium está habilitado)
                    if (AppConfigService().premiumEnabled) ...[
                      // Divider con "o"
                      Row(
                        children: [
                          Expanded(child: Divider(color: Colors.white24)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'o',
                              style: TextStyle(color: Colors.white54, fontSize: 13),
                            ),
                          ),
                          Expanded(child: Divider(color: Colors.white24)),
                        ],
                      ),
                      SizedBox(height: 12),

                      // Botón Premium
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(dialogContext, 'premium'),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: Color(0xFFFFD700),
                              width: 1.5,
                            ),
                            padding: EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.workspace_premium, color: Color(0xFFFFD700), size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Obtener Premium',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFFFD700),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 8),

                      // Texto Premium benefit
                      Text(
                        'Sin anuncios + créditos mensuales para reportes',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFFFD700).withValues(alpha: 0.7),
                        ),
                      ),
                      SizedBox(height: 16),
                    ],

                    // Botón Cancelar
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                      child: Text(
                        'Cancelar',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Si el usuario canceló, retornar false
    ReleaseLogger.log('dialogResult=$dialogResult', tag: 'ReportsScreen');
    if (dialogResult == 'cancel' || dialogResult == null) {
      ReleaseLogger.log('Usuario canceló, retornando false', tag: 'ReportsScreen');
      return false;
    }

    // Si eligió Premium, ir directamente a la pantalla de suscripción
    if (dialogResult == 'premium') {
      ReleaseLogger.log('Usuario eligió Premium, navegando a SubscriptionScreen', tag: 'ReportsScreen');
      if (scaffoldContext.mounted) {
        Navigator.of(scaffoldContext).push(
          MaterialPageRoute(builder: (context) => const SubscriptionScreen()),
        );
      }
      return false;
    }

    ReleaseLogger.log('Usuario SÍ quiere ver video, verificando mounted...', tag: 'ReportsScreen');
    // Mostrar indicador de carga mientras se prepara el ad
    if (!scaffoldContext.mounted) {
      ReleaseLogger.log('scaffoldContext no está mounted, retornando false', tag: 'ReportsScreen');
      return false;
    }
    ReleaseLogger.log('scaffoldContext está mounted, mostrando indicador de carga...', tag: 'ReportsScreen');

    showDialog(
      context: scaffoldContext,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Cargando video...'),
            ],
          ),
        ),
      ),
    );

    // Mostrar el Rewarded Ad
    ReleaseLogger.log('Mostrando Rewarded Ad...', tag: 'ReportsScreen');
    final rewarded = await _adService.showRewardedAd();
    ReleaseLogger.log('Rewarded Ad resultado: $rewarded', tag: 'ReportsScreen');

    // Cerrar indicador de carga
    if (scaffoldContext.mounted) {
      Navigator.of(scaffoldContext, rootNavigator: true).pop();
    }

    if (!rewarded && scaffoldContext.mounted) {
      // Usuario no completó el video
      ReleaseLogger.log('Usuario no completó el video, mostrando SnackBar', tag: 'ReportsScreen');
      ScaffoldMessenger.of(scaffoldContext).showSnackBar(
        SnackBar(
          content: Text('Debes ver el video completo para generar el reporte'),
          backgroundColor: Colors.orange,
        ),
      );
    }

    ReleaseLogger.log('Retornando rewarded=$rewarded desde _showRewardedAdDialog', tag: 'ReportsScreen');
    return rewarded;
  }

  /// Llama a la Cloud Function en background sin bloquear la UI
  void _callGenerateReportInBackground(String childId, String childName, BuildContext scaffoldContext) {
    ReleaseLogger.log('Solicitando reporte async para $childId', tag: 'ReportsScreen');

    final callable = FirebaseFunctions.instance.httpsCallable('generateChildReport');
    callable.call({
      'childId': childId,
      'daysBack': 7,
    }).then((result) {
      final data = result.data as Map<String, dynamic>?;
      if (data == null) {
        throw Exception('No se recibió respuesta de la función');
      }

      // Límite semanal ELIMINADO - ahora con ads el usuario puede generar reportes ilimitados

      if (data['success'] == true && data['pending'] == true) {
        ReleaseLogger.log('Reporte en proceso: ${data['pendingReportId']}', tag: 'ReportsScreen');

        // ✅ Incrementar contador de reportes mensuales
        _usageLimitsService.incrementReportsUsage();

        // Escuchar el pending_report para mostrar progreso
        _listenToPendingReport(data['pendingReportId'] as String, childName);
      } else {
        throw Exception(data['message'] ?? 'Error desconocido');
      }
    }).catchError((e) {
      ReleaseLogger.error('Error solicitando reporte: $e', tag: 'ReportsScreen');

      if (mounted) {
        // Cerrar el diálogo de "en proceso" si está abierto
        // ignore: use_build_context_synchronously
        Navigator.of(scaffoldContext, rootNavigator: true).pop();
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          SnackBar(
            content: Text('Error generando reporte: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    });
  }

  /// Escuchar cambios en el pending_report para notificar cuando esté listo
  void _listenToPendingReport(String pendingReportId, String childName) {
    _firestore
        .collection('pending_reports')
        .doc(pendingReportId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || !mounted) return;

      final data = snapshot.data();
      if (data == null) return;

      final status = data['status'] as String?;
      final progress = data['progress'] as int? ?? 0;
      final progressMessage = data['progressMessage'] as String? ?? '';

      ReleaseLogger.log('Pending report $pendingReportId: $status ($progress%) - $progressMessage', tag: 'ReportsScreen');

      if (status == 'completed') {
        final noData = data['noData'] == true;
        if (noData) {
          // El reporte terminó pero no había actividad suficiente. Avisar para
          // que el padre no quede esperando indefinidamente.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'No hubo suficiente actividad de $childName esta semana para un reporte',
              ),
              duration: Duration(seconds: 4),
            ),
          );
        }
        // Refresh UI to show the new report (si lo hay)
        setState(() {});
      } else if (status == 'failed') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generando reporte de $childName'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    });
  }

  // Límite semanal ELIMINADO - ahora con ads el usuario puede generar reportes ilimitados

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
                color: Colors.blue.withValues(alpha: 0.1),
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
              // ignore: use_build_context_synchronously
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
    // ✅ Mensajes analizados desde el último reporte
    final messagesAnalyzed = report['messagesAnalyzed'] ?? report['messages_analyzed'] ?? totalMessages;
    final bool fewMessages = messagesAnalyzed < 20;

    return Scaffold(
      appBar: AppBar(
        title: Text('Reporte de $childName'),
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // ⚠️ Advertencia si pocos mensajes analizados
          if (fewMessages) ...[
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Este reporte se basó en $messagesAnalyzed mensajes. Con pocos mensajes, el análisis puede ser menos preciso.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
          ],

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
            // El backend (functions/reports.js) y el generador local
            // (gemini_ai_service.dart) ya envían `period` con formato
            // user-friendly ("Últimos 7 días"). Si vino solo un número (legacy),
            // lo formateamos acá.
            (() {
              final period = report['period'];
              if (period == null) return 'Última semana';
              final asString = period.toString();
              if (RegExp(r'^\d+$').hasMatch(asString)) {
                return 'Últimos $asString días';
              }
              return asString;
            })(),
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
                    fontSize: 14,
                    color: colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                ),
                SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final moodText = (report['moodStatus'] ?? 'neutral') as String;
                    // Ajustar tamaño de fuente según longitud del texto
                    final fontSize = moodText.length > 30 ? 16.0 : (moodText.length > 15 ? 18.0 : 20.0);
                    // Si el texto es largo, mostramos 3 líneas + tap-to-expand.
                    // Antes quedaba truncado con "..." y no había forma de
                    // ver el resto.
                    final isLong = moodText.length > 120;
                    final textWidget = Text(
                      moodText,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onPrimaryContainer,
                        height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: isLong ? 3 : null,
                      overflow: isLong ? TextOverflow.ellipsis : TextOverflow.visible,
                    );
                    if (!isLong) return textWidget;
                    return Column(
                      children: [
                        textWidget,
                        SizedBox(height: 8),
                        GestureDetector(
                          onTap: () => _showMoodDetailsDialog(context, moodText),
                          child: Text(
                            'Ver más',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onPrimaryContainer,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
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
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
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
              color: Colors.blue.withValues(alpha: 0.1),
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

          // Mood Poll Stats (si existen)
          if (report['moodPollStats'] != null) ...[
            _buildMoodPollSection(report, colorScheme),
            SizedBox(height: 24),
          ],

          // Momento de Conexión
          if (report['connectionMoment'] != null) ...[
            _buildConnectionMomentSection(report, colorScheme),
            SizedBox(height: 24),
          ],

          // Preguntas Sugeridas
          if (report['suggestedQuestions'] != null &&
              (report['suggestedQuestions'] as List).isNotEmpty) ...[
            _buildSuggestedQuestionsSection(report, colorScheme),
            SizedBox(height: 24),
          ],

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
              color: Colors.grey.withValues(alpha: 0.1),
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
        color: Colors.grey.withValues(alpha: 0.05),
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
        color: color.withValues(alpha: 0.1),
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

  Widget _buildMoodPollSection(Map<String, dynamic> report, ColorScheme colorScheme) {
    final stats = report['moodPollStats'] as Map<String, dynamic>?;
    final responses = report['moodPollResponses'] as List?;

    if (stats == null) return SizedBox.shrink();

    final moodEmoji = stats['moodEmoji'] ?? '😐';
    final moodDescription = stats['moodDescription'] ?? 'Sin datos';
    final totalPolls = stats['totalPolls'] ?? 0;
    // averageSentiment available in stats['averageSentiment'] if needed

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.poll, color: colorScheme.primary),
            SizedBox(width: 8),
            Text(
              'Estado de ánimo directo',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        Text(
          'Basado en $totalPolls encuestas respondidas',
          style: TextStyle(
            fontSize: 14,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        SizedBox(height: 16),

        // Mood summary card
        Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.primaryContainer,
                colorScheme.primaryContainer.withValues(alpha: 0.7),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Text(moodEmoji, style: TextStyle(fontSize: 48)),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      moodDescription,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Tu hijo expresó sentirse así en las encuestas',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Recent responses
        if (responses != null && responses.isNotEmpty) ...[
          SizedBox(height: 16),
          Text(
            'Respuestas recientes',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 12),
          ...responses.take(3).map((response) {
            final r = response as Map<String, dynamic>;
            return Container(
              margin: EdgeInsets.only(bottom: 8),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Text(r['selectedEmoji'] ?? '😐', style: TextStyle(fontSize: 24)),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r['questionText'] ?? '',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2),
                        Text(
                          r['selectedOptionText'] ?? '',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _buildConnectionMomentSection(Map<String, dynamic> report, ColorScheme colorScheme) {
    final moment = report['connectionMoment'] as Map<String, dynamic>?;
    if (moment == null) return SizedBox.shrink();

    final emoji = moment['emoji'] ?? '💬';
    final suggestion = moment['suggestion'] ?? '';
    final activity = moment['activity'] ?? '';
    final reason = moment['reason'] ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(emoji, style: TextStyle(fontSize: 24)),
            SizedBox(width: 8),
            Text(
              'Momento de Conexión',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
        SizedBox(height: 16),

        Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                suggestion,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                  height: 1.4,
                ),
              ),
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lightbulb_outline, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        activity,
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (reason.isNotEmpty) ...[
                SizedBox(height: 8),
                Text(
                  reason,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestedQuestionsSection(Map<String, dynamic> report, ColorScheme colorScheme) {
    final questions = (report['suggestedQuestions'] as List?)?.cast<String>() ?? [];
    if (questions.isEmpty) return SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.chat_bubble_outline, color: colorScheme.primary),
            SizedBox(width: 8),
            Text(
              'Preguntas para conversar',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        Text(
          'Sugerencias basadas en el análisis de la semana',
          style: TextStyle(
            fontSize: 14,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        SizedBox(height: 16),

        ...questions.asMap().entries.map((entry) {
          final index = entry.key;
          final question = entry.value;
          return Container(
            margin: EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    question,
                    style: TextStyle(
                      fontSize: 15,
                      color: colorScheme.onSurface,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  /// Modal que muestra el texto completo del estado de ánimo cuando el
  /// resumen del header viene truncado.
  void _showMoodDetailsDialog(BuildContext context, String fullText) {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.mood, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Estado de ánimo',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: SelectableText(
                    fullText,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cerrar'),
                ),
              ),
            ],
          ),
        ),
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
  final FirebaseAuth? auth;
  final FirebaseFirestore? firestore;

  const ReportHistoryScreen({
    super.key,
    required this.childId,
    required this.childName,
    this.photoUrl,
    this.auth,
    this.firestore,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Historial de $childName'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: (firestore ?? FirebaseFirestore.instance)
            .collection('weekly_reports')
            .where('childId', isEqualTo: childId)
            .where('parentId', isEqualTo: (auth ?? FirebaseAuth.instance).currentUser!.uid)
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
