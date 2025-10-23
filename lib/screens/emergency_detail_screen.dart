import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import '../services/emergency_service.dart';
import 'dart:async';

class EmergencyDetailScreen extends StatefulWidget {
  final String emergencyId;
  final Map<String, dynamic> emergencyData;

  const EmergencyDetailScreen({
    super.key,
    required this.emergencyId,
    required this.emergencyData,
  });

  @override
  State<EmergencyDetailScreen> createState() => _EmergencyDetailScreenState();
}

class _EmergencyDetailScreenState extends State<EmergencyDetailScreen> {
  final EmergencyService _emergencyService = EmergencyService();
  GoogleMapController? _mapController;
  List<LatLng> _locationPoints = []; // Solo para el punto inicial
  bool _isResolving = false;

  @override
  void initState() {
    super.initState();
    print('🆘 [EmergencyDetailScreen] initState - emergencyId: ${widget.emergencyId}');
    print('🆘 [EmergencyDetailScreen] emergencyData: ${widget.emergencyData}');
    _loadLocationTracking();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _loadLocationTracking() async {
    try {
      print('🆘 [EmergencyDetailScreen] _loadLocationTracking iniciado');
      // La ubicación inicial está en los datos de emergencia
      final initialLocation = widget.emergencyData['location'];
      print('🆘 [EmergencyDetailScreen] initialLocation: $initialLocation');

      if (initialLocation != null) {
        final lat = initialLocation['latitude'];
        final lng = initialLocation['longitude'];
        print('🆘 [EmergencyDetailScreen] lat: $lat, lng: $lng');

        if (lat != null && lng != null) {
          final initialLatLng = LatLng(
            lat is double ? lat : (lat as num).toDouble(),
            lng is double ? lng : (lng as num).toDouble(),
          );

          setState(() {
            _locationPoints.add(initialLatLng);
          });
          print('✅ [EmergencyDetailScreen] Ubicación inicial agregada: $initialLatLng');
        } else {
          print('⚠️ Ubicación inicial sin coordenadas válidas');
        }
      } else {
        print('⚠️ [EmergencyDetailScreen] No hay ubicación inicial');
      }
    } catch (e, stackTrace) {
      print('❌ Error cargando ubicación inicial: $e');
      print('❌ Stack trace: $stackTrace');
    }
  }

  List<LatLng> _buildLocationPoints(List<QueryDocumentSnapshot> trackingDocs) {
    if (trackingDocs.isEmpty) return _locationPoints;

    // ⚡ Firestore ya limita a 10 documentos en orden descendente (más recientes primero)
    // Los invertimos para mostrarlos cronológicamente (del más antiguo al más reciente)
    final newPoints = trackingDocs.reversed.map((doc) {
      try {
        final data = doc.data() as Map<String, dynamic>;
        final lat = data['latitude'];
        final lng = data['longitude'];

        if (lat == null || lng == null) {
          print('⚠️ Documento de tracking sin coordenadas: ${doc.id}');
          return null;
        }

        return LatLng(
          lat is double ? lat : (lat as num).toDouble(),
          lng is double ? lng : (lng as num).toDouble(),
        );
      } catch (e) {
        print('❌ Error procesando punto de tracking ${doc.id}: $e');
        return null;
      }
    }).whereType<LatLng>().toList(); // Filtrar nulos

    print('⚡ [EmergencyDetailScreen] Mostrando ${newPoints.length} puntos de tracking (máx 10)');

    // Combinar con punto inicial si existe (para contexto de dónde empezó)
    final allPoints = List<LatLng>.from(_locationPoints.take(1)); // Solo el primer punto (inicial)
    allPoints.addAll(newPoints);

    return allPoints;
  }

  Set<Polyline> _buildPolylines(List<LatLng> points) {
    final polylines = <Polyline>{};

    if (points.length > 1) {
      polylines.add(
        Polyline(
          polylineId: PolylineId('emergency_path'),
          points: points,
          color: Colors.red,
          width: 5,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
        ),
        );
    }

    return polylines;
  }

  Set<Marker> _buildMarkers(List<LatLng> points) {
    final markers = <Marker>{};

    // Marcador inicial (si existe)
    if (_locationPoints.isNotEmpty) {
      markers.add(
        Marker(
          markerId: MarkerId('start'),
          position: _locationPoints.first,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Inicio de emergencia',
            snippet: _formatTime(widget.emergencyData['dateTime']),
          ),
        ),
      );
    }

    // Marcador actual (último punto del tracking)
    if (points.length > 1) {
      markers.add(
        Marker(
          markerId: MarkerId('current'),
          position: points.last,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(
            title: 'Posición actual',
            snippet: 'Última actualización',
          ),
        ),
      );
    }

    return markers;
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return 'Desconocido';

    try {
      DateTime dateTime;
      if (timestamp is Timestamp) {
        dateTime = timestamp.toDate();
      } else if (timestamp is String) {
        dateTime = DateTime.parse(timestamp);
      } else {
        return 'Desconocido';
      }

      return DateFormat('HH:mm:ss - dd/MM/yyyy').format(dateTime);
    } catch (e) {
      return 'Desconocido';
    }
  }

  String _getElapsedTime() {
    // Usar timestamp en lugar de dateTime para evitar problemas de zona horaria
    final startTime = widget.emergencyData['timestamp'] ?? widget.emergencyData['dateTime'];
    if (startTime == null) return 'Desconocido';

    try {
      DateTime dateTime;
      if (startTime is Timestamp) {
        dateTime = startTime.toDate();
      } else if (startTime is String) {
        dateTime = DateTime.parse(startTime);
      } else {
        return 'Desconocido';
      }

      final elapsed = DateTime.now().difference(dateTime);
      final minutes = elapsed.inMinutes;
      final seconds = elapsed.inSeconds % 60;

      return '$minutes min $seconds seg';
    } catch (e) {
      return 'Desconocido';
    }
  }

  Future<void> _resolveEmergency() async {
    setState(() {
      _isResolving = true;
    });

    final success = await _emergencyService.resolveEmergency(widget.emergencyId);

    if (success && mounted) {
      Navigator.pop(context);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al resolver emergencia'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _isResolving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    print('🆘 [EmergencyDetailScreen] build iniciado');
    final childName = widget.emergencyData['childName'] ?? 'Desconocido';
    final message = widget.emergencyData['message'] ?? 'Emergencia activada';
    final initialLocation = widget.emergencyData['location'];
    print('🆘 [EmergencyDetailScreen] childName: $childName, message: $message');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        title: Text('🆘 EMERGENCIA ACTIVA'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Información de la emergencia
          Container(
            color: Colors.red.withValues(alpha: 0.1),
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.red,
                      radius: 24,
                      child: Icon(Icons.warning, color: Colors.white, size: 28),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            childName,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.red[900],
                            ),
                          ),
                          Text(
                            message,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.red[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _buildInfoItem(
                        Icons.access_time,
                        'Hora de activación',
                        _formatTime(widget.emergencyData['dateTime']),
                      ),
                    ),
                    Expanded(
                      child: StreamBuilder<int>(
                        stream: Stream.periodic(Duration(seconds: 1), (tick) => tick),
                        builder: (context, snapshot) {
                          return _buildInfoItem(
                            Icons.timer,
                            'Tiempo transcurrido',
                            _getElapsedTime(),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Mapa con tracking
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('emergencies')
                  .doc(widget.emergencyId)
                  .collection('location_tracking')
                  .orderBy('timestamp', descending: true) // Más recientes primero
                  .limit(10) // ⚡ LIMITAR A 10 DOCUMENTOS DESDE FIRESTORE
                  .snapshots()
                  .handleError((error) {
                    print('❌ Error en stream de location_tracking: $error');
                    return null;
                  }),
              builder: (context, snapshot) {
                print('🆘 [EmergencyDetailScreen] StreamBuilder rebuild');
                print('🆘 [EmergencyDetailScreen] connectionState: ${snapshot.connectionState}');
                print('🆘 [EmergencyDetailScreen] hasData: ${snapshot.hasData}');
                print('🆘 [EmergencyDetailScreen] hasError: ${snapshot.hasError}');

                // Manejo de errores
                if (snapshot.hasError) {
                  print('❌ Error en StreamBuilder de location_tracking: ${snapshot.error}');
                }

                // Construir puntos sin setState
                final trackingDocs = snapshot.hasData ? snapshot.data!.docs : <QueryDocumentSnapshot>[];
                print('🆘 [EmergencyDetailScreen] trackingDocs count: ${trackingDocs.length}');

                final locationPoints = _buildLocationPoints(trackingDocs);
                print('🆘 [EmergencyDetailScreen] locationPoints count: ${locationPoints.length}');

                final polylines = _buildPolylines(locationPoints);
                print('🆘 [EmergencyDetailScreen] polylines count: ${polylines.length}');

                final markers = _buildMarkers(locationPoints);
                print('🆘 [EmergencyDetailScreen] markers count: ${markers.length}');

                return Stack(
                  children: [
                    if (initialLocation != null)
                      GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: LatLng(
                            initialLocation['latitude'] as double,
                            initialLocation['longitude'] as double,
                          ),
                          zoom: 15,
                        ),
                        markers: markers,
                        polylines: polylines,
                        myLocationEnabled: false,
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: true,
                        mapType: MapType.normal,
                        onMapCreated: (controller) {
                          _mapController = controller;
                        },
                      )
                    else
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.location_off, size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'Sin ubicación disponible',
                              style: TextStyle(fontSize: 16, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),

                    // Información de puntos de tracking
                    if (snapshot.hasData && snapshot.data!.docs.isNotEmpty)
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.route, color: Colors.red, size: 20),
                              SizedBox(width: 8),
                              Text(
                                // Mostrar solo los puntos recientes (máx 10 + inicial)
                                '${trackingDocs.length + 1} puntos recientes',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red[900],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),

          // Botón de resolver
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 10,
                  offset: Offset(0, -5),
                ),
              ],
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isResolving ? null : _resolveEmergency,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isResolving
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'TODO ESTÁ BIEN - RESOLVER EMERGENCIA',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: Colors.red[700]),
            SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.red[900],
          ),
        ),
      ],
    );
  }
}
