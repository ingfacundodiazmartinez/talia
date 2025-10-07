import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../notification_service.dart';
import 'location_service.dart';
import 'video_call_service.dart';

class EmergencyService {
  static final EmergencyService _instance = EmergencyService._internal();
  factory EmergencyService() => _instance;
  EmergencyService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final LocationService _locationService = LocationService();
  final NotificationService _notificationService = NotificationService();
  final VideoCallService _videoCallService = VideoCallService();

  // Tiempo de cooldown entre emergencias (en minutos)
  static const int _cooldownMinutes = 2;

  // Tiempo máximo de tracking de emergencia (1 hora)
  static const int _maxTrackingMinutes = 60;

  // Timer para tracking continuo de ubicación
  Timer? _locationTrackingTimer;
  String? _currentEmergencyId;

  // Verificar si el botón de emergencia está en cooldown
  Future<bool> isInCooldown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastEmergencyTime = prefs.getInt('last_emergency_time');

      if (lastEmergencyTime == null) return false;

      final lastEmergency = DateTime.fromMillisecondsSinceEpoch(lastEmergencyTime);
      final now = DateTime.now();
      final difference = now.difference(lastEmergency);

      return difference.inMinutes < _cooldownMinutes;
    } catch (e) {
      print('❌ Error verificando cooldown: $e');
      return false;
    }
  }

  // Activar emergencia completa
  Future<Map<String, dynamic>?> activateEmergency({
    String? customMessage,
    BuildContext? context,
  }) async {
    try {
      print('🆘 Activando emergencia...');

      // Verificar cooldown
      if (await isInCooldown()) {
        print('⏰ Emergencia en cooldown');
        if (context != null) {
          _showCooldownMessage(context);
        }
        return null;
      }

      final user = _auth.currentUser;
      if (user == null) {
        print('❌ Usuario no autenticado');
        return null;
      }

      // Vibración de emergencia
      await _triggerEmergencyVibration();

      // Obtener ubicación actual
      final position = await _getCurrentLocation();

      // Obtener información del niño
      final childData = await _getChildData(user.uid);
      if (childData == null) {
        print('❌ No se pudo obtener datos del niño');
        return null;
      }

      // Crear registro de emergencia
      final emergencyId = await _createEmergencyRecord(
        childId: user.uid,
        childName: childData['name'] ?? 'Desconocido',
        position: position,
        customMessage: customMessage,
      );

      if (emergencyId == null) {
        print('❌ Error creando registro de emergencia');
        return null;
      }

      // Obtener padres/tutores
      final parents = await _getParents(user.uid);

      // Enviar notificaciones a padres
      await _notifyParents(
        parents: parents,
        childName: childData['name'] ?? 'Tu hijo',
        emergencyId: emergencyId,
        position: position,
        customMessage: customMessage,
      );

      // Iniciar llamada de emergencia con Agora al primer padre
      await _makeEmergencyVideoCall(parents, emergencyId);

      // Iniciar tracking continuo de ubicación
      await _startLocationTracking(emergencyId);

      // Guardar timestamp del último uso
      await _saveLastEmergencyTime();

      print('✅ Emergencia activada exitosamente');

      if (context != null) {
        _showEmergencyConfirmation(context);
      }

      // Retornar información de la emergencia para que el hijo pueda unirse a la llamada
      return {
        'emergencyId': emergencyId,
        'channelName': 'emergency_$emergencyId',
        'success': true,
      };
    } catch (e) {
      print('❌ Error activando emergencia: $e');
      if (context != null) {
        _showErrorMessage(context, e.toString());
      }
      return null;
    }
  }

  // Obtener ubicación actual rápidamente
  Future<Position?> _getCurrentLocation() async {
    try {
      print('📍 Obteniendo ubicación de emergencia...');

      // Verificar permisos
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('❌ Sin permisos de ubicación para emergencia');
        return null;
      }

      // Obtener ubicación con timeout corto para emergencias
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10), // Timeout corto para emergencias
      );

      print('✅ Ubicación de emergencia obtenida: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      print('❌ Error obteniendo ubicación de emergencia: $e');
      return null;
    }
  }

  // Obtener datos del niño
  Future<Map<String, dynamic>?> _getChildData(String childId) async {
    try {
      final doc = await _firestore.collection('users').doc(childId).get();
      if (doc.exists) {
        return doc.data();
      }
      return null;
    } catch (e) {
      print('❌ Error obteniendo datos del niño: $e');
      return null;
    }
  }

  // Crear registro de emergencia en Firebase
  Future<String?> _createEmergencyRecord({
    required String childId,
    required String childName,
    Position? position,
    String? customMessage,
  }) async {
    try {
      final emergencyData = {
        'childId': childId,
        'childName': childName,
        'timestamp': FieldValue.serverTimestamp(),
        'dateTime': DateTime.now().toIso8601String(),
        'status': 'active',
        'message': customMessage ?? 'Emergencia activada',
        'resolved': false,
        'resolvedAt': null,
        'resolvedBy': null,
      };

      // Agregar ubicación si está disponible
      if (position != null) {
        emergencyData.addAll({
          'location': {
            'latitude': position.latitude,
            'longitude': position.longitude,
            'accuracy': position.accuracy,
            'timestamp': DateTime.now().toIso8601String(),
          }
        });
      }

      final docRef = await _firestore.collection('emergencies').add(emergencyData);
      print('✅ Registro de emergencia creado: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('❌ Error creando registro de emergencia: $e');
      return null;
    }
  }

  // Obtener lista de padres/tutores
  Future<List<Map<String, dynamic>>> _getParents(String childId) async {
    try {
      // Buscar relaciones padre-hijo
      final querySnapshot = await _firestore
          .collection('parent_child_links')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'approved')
          .get();

      List<Map<String, dynamic>> parents = [];

      for (var doc in querySnapshot.docs) {
        final linkData = doc.data();
        final parentId = linkData['parentId'];

        // Obtener datos del padre
        final parentDoc = await _firestore.collection('users').doc(parentId).get();
        if (parentDoc.exists) {
          final parentData = parentDoc.data()!;
          parentData['id'] = parentId;
          parents.add(parentData);
        }
      }

      print('✅ Encontrados ${parents.length} padres para notificar');
      return parents;
    } catch (e) {
      print('❌ Error obteniendo padres: $e');
      return [];
    }
  }

  // Notificar a todos los padres
  Future<void> _notifyParents({
    required List<Map<String, dynamic>> parents,
    required String childName,
    required String emergencyId,
    Position? position,
    String? customMessage,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      for (var parent in parents) {
        final parentId = parent['id'];
        final parentName = parent['name'] ?? 'Padre';

        // Crear notificación en Firebase
        await _firestore.collection('notifications').add({
          'userId': parentId,
          'senderId': user.uid, // ⚠️ IMPORTANTE: Para validación de seguridad
          'type': 'emergency',
          'title': '🆘 EMERGENCIA - $childName',
          'body': customMessage ?? '$childName ha activado el botón de emergencia',
          'data': {
            'emergencyId': emergencyId,
            'childName': childName,
            'senderId': user.uid,
            'location': position != null ? {
              'latitude': position.latitude,
              'longitude': position.longitude,
            } : null,
          },
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
          'priority': 'high',
        });

        print('✅ Notificación de emergencia enviada a $parentName');
      }
    } catch (e) {
      print('❌ Error enviando notificaciones: $e');
    }
  }

  // Realizar llamada de emergencia con Agora
  Future<void> _makeEmergencyVideoCall(List<Map<String, dynamic>> parents, String emergencyId) async {
    try {
      if (parents.isEmpty) {
        print('❌ No hay padres para llamar');
        return;
      }

      final user = _auth.currentUser;
      if (user == null) return;

      // Usar emergencyId como channel name para la llamada
      final channelName = 'emergency_$emergencyId';

      // Crear registro de llamada en Firestore
      for (var parent in parents) {
        final parentId = parent['id'];
        final parentName = parent['name'] ?? 'Padre';

        await _firestore.collection('video_calls').add({
          'callId': emergencyId,
          'callerId': user.uid,
          'callerName': await _getUserName(user.uid),
          'receiverId': parentId,
          'receiverName': parentName,
          'channelName': channelName,
          'status': 'ringing',
          'timestamp': FieldValue.serverTimestamp(),
          'isEmergency': true,
          'type': 'video_call', // Videollamada para que el padre pueda ver al niño
        });

        print('✅ Llamada de emergencia creada para $parentName');
      }
    } catch (e) {
      print('❌ Error creando llamada de emergencia: $e');
    }
  }

  // Obtener nombre de usuario
  Future<String> _getUserName(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.data()?['name'] ?? 'Usuario';
    } catch (e) {
      return 'Usuario';
    }
  }

  // Iniciar tracking continuo de ubicación
  Future<void> _startLocationTracking(String emergencyId) async {
    try {
      print('📍 Iniciando tracking de ubicación de emergencia...');

      _currentEmergencyId = emergencyId;

      // Actualizar ubicación cada 30 segundos
      _locationTrackingTimer?.cancel();
      _locationTrackingTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
        final position = await _getCurrentLocation();
        if (position != null && _currentEmergencyId != null) {
          await _saveLocationPoint(_currentEmergencyId!, position);
        }
      });

      // Auto-detener después de 1 hora
      Future.delayed(Duration(minutes: _maxTrackingMinutes), () {
        if (_locationTrackingTimer?.isActive ?? false) {
          print('⏰ Deteniendo tracking automáticamente después de 1 hora');
          stopLocationTracking();
        }
      });

      print('✅ Tracking de ubicación iniciado');
    } catch (e) {
      print('❌ Error iniciando tracking de ubicación: $e');
    }
  }

  // Guardar punto de ubicación en subcollection
  Future<void> _saveLocationPoint(String emergencyId, Position position) async {
    try {
      await _firestore
          .collection('emergencies')
          .doc(emergencyId)
          .collection('location_tracking')
          .add({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'heading': position.heading,
        'speed': position.speed,
        'timestamp': FieldValue.serverTimestamp(),
        'dateTime': DateTime.now().toIso8601String(),
      });

      print('📍 Ubicación guardada: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      print('❌ Error guardando punto de ubicación: $e');
    }
  }

  // Detener tracking de ubicación
  void stopLocationTracking() {
    _locationTrackingTimer?.cancel();
    _locationTrackingTimer = null;
    _currentEmergencyId = null;
    print('⏹️ Tracking de ubicación detenido');
  }

  // Vibración de emergencia
  Future<void> _triggerEmergencyVibration() async {
    try {
      // Patrón de vibración de emergencia: largo-corto-largo-corto
      await HapticFeedback.heavyImpact();
      await Future.delayed(Duration(milliseconds: 100));
      await HapticFeedback.mediumImpact();
      await Future.delayed(Duration(milliseconds: 100));
      await HapticFeedback.heavyImpact();
      await Future.delayed(Duration(milliseconds: 100));
      await HapticFeedback.mediumImpact();
    } catch (e) {
      print('❌ Error en vibración de emergencia: $e');
    }
  }

  // Guardar timestamp de último uso
  Future<void> _saveLastEmergencyTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_emergency_time', DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      print('❌ Error guardando timestamp de emergencia: $e');
    }
  }

  // Resolver emergencia (para padres)
  Future<bool> resolveEmergency(String emergencyId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      // Actualizar emergencia como resuelta
      await _firestore.collection('emergencies').doc(emergencyId).update({
        'resolved': true,
        'resolvedAt': FieldValue.serverTimestamp(),
        'resolvedBy': user.uid,
        'status': 'resolved',
      });

      // Detener tracking de ubicación si es la emergencia actual
      if (_currentEmergencyId == emergencyId) {
        stopLocationTracking();
      }

      // Eliminar el historial de ubicaciones de la emergencia
      print('🗑️ Eliminando historial de ubicaciones de emergencia...');
      final trackingDocs = await _firestore
          .collection('emergencies')
          .doc(emergencyId)
          .collection('location_tracking')
          .get();

      // Eliminar todos los documentos del historial en lote
      final batch = _firestore.batch();
      for (var doc in trackingDocs.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      print('✅ Emergencia resuelta y historial eliminado: $emergencyId (${trackingDocs.docs.length} ubicaciones)');
      return true;
    } catch (e) {
      print('❌ Error resolviendo emergencia: $e');
      return false;
    }
  }

  // Obtener emergencias activas para TODOS los hijos de un padre
  Stream<QuerySnapshot> getActiveEmergenciesForParent(String parentId) async* {
    try {
      // Obtener IDs de todos los hijos del padre
      final linksSnapshot = await _firestore
          .collection('parent_child_links')
          .where('parentId', isEqualTo: parentId)
          .where('status', isEqualTo: 'approved')
          .get();

      final childrenIds = linksSnapshot.docs
          .map((doc) => doc.data()['childId'] as String)
          .toList();

      if (childrenIds.isEmpty) {
        // Si no tiene hijos, emitir stream vacío
        yield* Stream.value(
          await _firestore.collection('emergencies').where('childId', isEqualTo: 'no_children').get(),
        );
        return;
      }

      // Escuchar emergencias activas de todos los hijos
      yield* _firestore
          .collection('emergencies')
          .where('childId', whereIn: childrenIds)
          .where('resolved', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .snapshots();
    } catch (e) {
      print('❌ Error obteniendo emergencias del padre: $e');
      // Emitir stream vacío en caso de error
      yield* Stream.value(
        await _firestore.collection('emergencies').where('childId', isEqualTo: 'error').get(),
      );
    }
  }

  // Obtener emergencias activas para un niño
  Stream<QuerySnapshot> getActiveEmergencies(String childId) {
    return _firestore
        .collection('emergencies')
        .where('childId', isEqualTo: childId)
        .where('resolved', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  // Obtener historial de emergencias
  Future<List<Map<String, dynamic>>> getEmergencyHistory(String childId, {int limit = 20}) async {
    try {
      final querySnapshot = await _firestore
          .collection('emergencies')
          .where('childId', isEqualTo: childId)
          .orderBy('timestamp', descending: true)
          .limit(limit)
          .get();

      return querySnapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      print('❌ Error obteniendo historial de emergencias: $e');
      return [];
    }
  }

  // Mensajes de UI
  void _showCooldownMessage(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Botón de emergencia en espera. Intenta en $_cooldownMinutes minutos.',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _showEmergencyConfirmation(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🆘 Emergencia activada. Tus padres han sido notificados.',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 5),
      ),
    );
  }

  void _showErrorMessage(BuildContext context, String error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Error activando emergencia. Intenta de nuevo.',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.red[800],
        duration: Duration(seconds: 3),
      ),
    );
  }
}