import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import '../services/emergency_service.dart';
import '../utils/release_logger.dart';

/// Controller para EmergencyDetailScreen
///
/// Responsabilidades:
/// - Gestionar datos de emergencia en tiempo real
/// - Manejar tracking de ubicación vía Firestore
/// - Procesar puntos de ubicación para el mapa
/// - Resolver emergencias
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class EmergencyDetailController {
  final String emergencyId;
  final Map<String, dynamic> emergencyData;

  // Services
  final EmergencyService _emergencyService;

  // State
  List<LatLng> _locationPoints = [];
  bool _isResolving = false;

  // Subscriptions
  StreamSubscription<QuerySnapshot>? _locationTrackingSubscription;

  // Callbacks para actualizar UI
  Function(List<LatLng>)? onLocationPointsChanged;
  Function(bool)? onResolvingStateChanged;
  Function(String)? onError;

  EmergencyDetailController({
    required this.emergencyId,
    required this.emergencyData,
    EmergencyService? emergencyService,
  }) : _emergencyService = emergencyService ?? EmergencyService();

  // Getters
  List<LatLng> get locationPoints => _locationPoints;
  bool get isResolving => _isResolving;
  String get childName => emergencyData['childName'] ?? 'Desconocido';
  String get message => emergencyData['message'] ?? 'Emergencia activada';
  Map<String, dynamic>? get initialLocation => emergencyData['location'];

  /// Inicializar controller y cargar datos iniciales
  Future<void> initialize() async {
    try {
      ReleaseLogger.log('Iniciando EmergencyDetailController - emergencyId: $emergencyId', tag: 'EmergencyDetail');
      ReleaseLogger.log('emergencyData: $emergencyData', tag: 'EmergencyDetail');

      await _loadLocationTracking();
      _startLocationTrackingStream();
    } catch (e) {
      ReleaseLogger.error('Error inicializando EmergencyDetailController: $e', tag: 'EmergencyDetail');
      onError?.call('Error iniciando tracking de emergencia');
    }
  }

  /// Cargar ubicación inicial de tracking
  Future<void> _loadLocationTracking() async {
    try {
      ReleaseLogger.log('_loadLocationTracking iniciado', tag: 'EmergencyDetail');

      // La ubicación inicial está en los datos de emergencia
      final initialLocation = emergencyData['location'];
      ReleaseLogger.log('initialLocation: $initialLocation', tag: 'EmergencyDetail');

      if (initialLocation != null) {
        final lat = initialLocation['latitude'];
        final lng = initialLocation['longitude'];
        ReleaseLogger.log('lat: $lat, lng: $lng', tag: 'EmergencyDetail');

        if (lat != null && lng != null) {
          final initialLatLng = LatLng(
            lat is double ? lat : (lat as num).toDouble(),
            lng is double ? lng : (lng as num).toDouble(),
          );

          _locationPoints.add(initialLatLng);
          onLocationPointsChanged?.call(_locationPoints);
          ReleaseLogger.log('Ubicación inicial agregada: $initialLatLng', tag: 'EmergencyDetail');
        } else {
          ReleaseLogger.warning('Ubicación inicial sin coordenadas válidas', tag: 'EmergencyDetail');
        }
      } else {
        ReleaseLogger.warning('No hay ubicación inicial', tag: 'EmergencyDetail');
      }
    } catch (e, stackTrace) {
      ReleaseLogger.error('Error cargando ubicación inicial: $e', tag: 'EmergencyDetail');
      ReleaseLogger.error('Stack trace: $stackTrace', tag: 'EmergencyDetail');
    }
  }

  /// Iniciar stream de tracking de ubicación en tiempo real
  void _startLocationTrackingStream() {
    try {
      ReleaseLogger.log('Iniciando stream de location tracking', tag: 'EmergencyDetail');

      _locationTrackingSubscription = FirebaseFirestore.instance
          .collection('emergencies')
          .doc(emergencyId)
          .collection('location_tracking')
          .orderBy('timestamp', descending: true) // Más recientes primero
          .limit(10) // LIMITAR A 10 DOCUMENTOS DESDE FIRESTORE
          .snapshots()
          .handleError((error) {
            ReleaseLogger.error('Error en stream de location_tracking: $error', tag: 'EmergencyDetail');
            onError?.call('Error obteniendo ubicaciones en tiempo real');
            return null;
          })
          .listen((snapshot) {
            _handleLocationTrackingSnapshot(snapshot);
          });
    } catch (e) {
      ReleaseLogger.error('Error configurando stream de location tracking: $e', tag: 'EmergencyDetail');
      onError?.call('Error configurando tracking en tiempo real');
    }
  }

  /// Manejar snapshot de tracking de ubicación
  void _handleLocationTrackingSnapshot(QuerySnapshot snapshot) {
    try {
      ReleaseLogger.log('StreamBuilder rebuild', tag: 'EmergencyDetail');
      ReleaseLogger.log('connectionState: ${snapshot.metadata.isFromCache ? "cache" : "server"}', tag: 'EmergencyDetail');
      ReleaseLogger.log('hasData: ${snapshot.docs.isNotEmpty}', tag: 'EmergencyDetail');

      final trackingDocs = snapshot.docs;
      ReleaseLogger.log('trackingDocs count: ${trackingDocs.length}', tag: 'EmergencyDetail');

      final locationPoints = _buildLocationPoints(trackingDocs);
      ReleaseLogger.log('locationPoints count: ${locationPoints.length}', tag: 'EmergencyDetail');

      // Notificar cambios a la UI
      onLocationPointsChanged?.call(locationPoints);
    } catch (e) {
      ReleaseLogger.error('Error procesando snapshot de location tracking: $e', tag: 'EmergencyDetail');
    }
  }

  /// Construir puntos de ubicación desde documentos de tracking
  List<LatLng> _buildLocationPoints(List<QueryDocumentSnapshot> trackingDocs) {
    if (trackingDocs.isEmpty) return _locationPoints;

    // Firestore ya limita a 10 documentos en orden descendente (más recientes primero)
    // Los invertimos para mostrarlos cronológicamente (del más antiguo al más reciente)
    final newPoints = trackingDocs.reversed.map((doc) {
      try {
        final data = doc.data() as Map<String, dynamic>;
        final lat = data['latitude'];
        final lng = data['longitude'];

        if (lat == null || lng == null) {
          ReleaseLogger.warning('Documento de tracking sin coordenadas: ${doc.id}', tag: 'EmergencyDetail');
          return null;
        }

        return LatLng(
          lat is double ? lat : (lat as num).toDouble(),
          lng is double ? lng : (lng as num).toDouble(),
        );
      } catch (e) {
        ReleaseLogger.error('Error procesando punto de tracking ${doc.id}: $e', tag: 'EmergencyDetail');
        return null;
      }
    }).whereType<LatLng>().toList(); // Filtrar nulos

    ReleaseLogger.log('Mostrando ${newPoints.length} puntos de tracking (máx 10)', tag: 'EmergencyDetail');

    // Combinar con punto inicial si existe (para contexto de dónde empezó)
    final allPoints = List<LatLng>.from(_locationPoints.take(1)); // Solo el primer punto (inicial)
    allPoints.addAll(newPoints);

    return allPoints;
  }

  /// Construir polylines para el mapa
  Set<Polyline> buildPolylines(List<LatLng> points) {
    final polylines = <Polyline>{};

    if (points.length > 1) {
      polylines.add(
        Polyline(
          polylineId: PolylineId('emergency_path'),
          points: points,
          color: const Color(0xFFD32F2F), // Colors.red
          width: 5,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
        ),
      );
    }

    return polylines;
  }

  /// Construir markers para el mapa
  Set<Marker> buildMarkers(List<LatLng> points) {
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
            snippet: formatTime(emergencyData['dateTime']),
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

  /// Formatear timestamp para mostrar
  String formatTime(dynamic timestamp) {
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

  /// Obtener tiempo transcurrido desde el inicio de la emergencia
  String getElapsedTime() {
    // Usar timestamp en lugar de dateTime para evitar problemas de zona horaria
    final startTime = emergencyData['timestamp'] ?? emergencyData['dateTime'];
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

  /// Resolver emergencia
  Future<void> resolveEmergency() async {
    if (_isResolving) return;

    try {
      _isResolving = true;
      onResolvingStateChanged?.call(_isResolving);

      ReleaseLogger.log('Resolviendo emergencia: $emergencyId', tag: 'EmergencyDetail');

      final success = await _emergencyService.resolveEmergency(emergencyId);

      if (success) {
        ReleaseLogger.log('Emergencia resuelta exitosamente', tag: 'EmergencyDetail');
      } else {
        ReleaseLogger.error('Error resolviendo emergencia', tag: 'EmergencyDetail');
        onError?.call('Error al resolver emergencia');
      }
    } catch (e) {
      ReleaseLogger.error('Error en resolveEmergency: $e', tag: 'EmergencyDetail');
      onError?.call('Error al resolver emergencia');
    } finally {
      _isResolving = false;
      onResolvingStateChanged?.call(_isResolving);
    }
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing EmergencyDetailController', tag: 'EmergencyDetail');
    _locationTrackingSubscription?.cancel();
  }
}