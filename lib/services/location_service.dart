import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'background_location_service.dart';

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final BackgroundLocationService _backgroundService = BackgroundLocationService();

  StreamSubscription<Position>? _positionStream;
  Timer? _locationUpdateTimer;
  bool _isTracking = false;

  // Configuración de ubicación
  final LocationSettings _locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10, // Actualizar cada 10 metros
  );

  // Verificar y solicitar permisos de ubicación
  Future<bool> requestLocationPermission() async {
    // Verificar si el servicio de ubicación está habilitado
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    // Verificar permisos
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    return true;
  }

  // Obtener ubicación actual
  Future<Position?> getCurrentLocation() async {
    try {
      final hasPermission = await requestLocationPermission();
      if (!hasPermission) return null;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      return position;
    } catch (e) {
      return null;
    }
  }

  // Iniciar tracking de ubicación
  Future<void> startLocationTracking() async {
    if (_isTracking) {
      return;
    }

    final hasPermission = await requestLocationPermission();
    if (!hasPermission) return;

    final user = _auth.currentUser;
    if (user == null) {
      return;
    }

    _isTracking = true;

    // Actualizar ubicación inmediatamente
    final initialPosition = await getCurrentLocation();
    if (initialPosition != null) {
      await _updateLocationInFirestore(initialPosition);
    }

    // Configurar actualizaciones periódicas cada 30 segundos
    _locationUpdateTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      if (!_isTracking) {
        timer.cancel();
        return;
      }

      final position = await getCurrentLocation();
      if (position != null) {
        await _updateLocationInFirestore(position);
      }
    });

    // También escuchar cambios de posición basados en distancia
    _positionStream = Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).listen(
      (Position position) {
        _updateLocationInFirestore(position);
      },
      onError: (error) {
      },
    );
  }

  // Detener tracking de ubicación
  void stopLocationTracking() {
    _isTracking = false;
    _positionStream?.cancel();
    _locationUpdateTimer?.cancel();
  }

  // Actualizar ubicación en Firestore
  Future<void> _updateLocationInFirestore(Position position) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // SIEMPRE guardar la última ubicación (se reemplaza automáticamente)
      await _firestore.collection('user_locations').doc(user.uid).set({
        'userId': user.uid,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'speed': position.speed,
        'heading': position.heading,
        'timestamp': FieldValue.serverTimestamp(),
        'lastUpdate': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));


      // Solo guardar historial si hay una emergencia ACTIVA
      final activeEmergency = await _firestore
          .collection('emergencies')
          .where('childId', isEqualTo: user.uid)
          .where('resolved', isEqualTo: false)
          .limit(1)
          .get();

      if (activeEmergency.docs.isNotEmpty) {
        final emergencyId = activeEmergency.docs.first.id;

        // Guardar en la subcolección de tracking de la emergencia
        await _firestore
            .collection('emergencies')
            .doc(emergencyId)
            .collection('location_tracking')
            .add({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'timestamp': FieldValue.serverTimestamp(),
          'date': DateTime.now().toIso8601String(),
        });

      }
    } catch (e) {
    }
  }

  // Obtener ubicación de un usuario específico (para padres)
  Stream<DocumentSnapshot> getUserLocationStream(String userId) {
    return _firestore.collection('user_locations').doc(userId).snapshots();
  }

  // Obtener historial de ubicaciones de emergencia
  Future<List<Map<String, dynamic>>> getEmergencyLocationTracking(String emergencyId) async {
    try {
      final query = await _firestore
          .collection('emergencies')
          .doc(emergencyId)
          .collection('location_tracking')
          .orderBy('timestamp', descending: true)
          .get();

      return query.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          ...data,
        };
      }).toList();
    } catch (e) {
      return [];
    }
  }

  // Calcular distancia entre dos puntos
  double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2);
  }

  // Habilitar tracking en background
  Future<void> enableBackgroundTracking() async {
    try {
      await _backgroundService.initialize();
    } catch (e) {
    }
  }

  // Iniciar tracking en background
  Future<void> startBackgroundTracking() async {
    try {
      await _backgroundService.startBackgroundTracking();
    } catch (e) {
    }
  }

  // Detener tracking en background
  Future<void> stopBackgroundTracking() async {
    try {
      await _backgroundService.stopBackgroundTracking();
    } catch (e) {
    }
  }

  // Verificar si el tracking está activo
  bool get isTracking => _isTracking;

  // Verificar si el background tracking está activo
  bool get isBackgroundTracking => _backgroundService.isTracking;

  // Limpiar recursos
  void dispose() {
    stopLocationTracking();
    _backgroundService.dispose();
  }
}
