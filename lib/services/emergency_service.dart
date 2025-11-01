import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmergencyService {
  static final EmergencyService _instance = EmergencyService._internal();
  factory EmergencyService() => _instance;
  EmergencyService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

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

      final user = _auth.currentUser;
      if (user == null) {
        print('❌ Usuario no autenticado');
        return null;
      }

      // ✅ NUEVO: Verificar si ya existe una emergencia activa (sin resolver)
      final existingEmergency = await _getActiveEmergency(user.uid);

      if (existingEmergency != null) {
        final emergencyId = existingEmergency['id'] as String;
        print('⚠️ Ya existe emergencia activa: $emergencyId');
        print('📞 Reactivando llamada sin crear nueva emergencia...');

        // Vibración de emergencia
        await _triggerEmergencyVibration();

        // Obtener padres para reiniciar llamada
        final parents = await _getParents(user.uid);

        // Reiniciar llamada de emergencia
        await _makeEmergencyVideoCall(parents, emergencyId);

        if (context != null) {
          _showEmergencyConfirmation(context);
        }

        // Retornar información de la emergencia existente
        return {
          'emergencyId': emergencyId,
          'channelName': 'emergency_$emergencyId',
          'success': true,
          'isReactivation': true,
        };
      }

      // Verificar cooldown solo si no hay emergencia activa
      if (await isInCooldown()) {
        print('⏰ Emergencia en cooldown');
        if (context != null) {
          _showCooldownMessage(context);
        }
        return null;
      }

      // Vibración de emergencia
      await _triggerEmergencyVibration();

      // ✅ OPTIMIZACIÓN: Ejecutar operaciones en paralelo (en background)
      final results = await Future.wait([
        _getCurrentLocation(),
        _getChildData(user.uid),
        _getParents(user.uid),
      ]);

      final position = results[0] as Position?;
      final childData = results[1] as Map<String, dynamic>?;
      final parents = results[2] as List<Map<String, dynamic>>;

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

      // ✅ Las notificaciones ya fueron enviadas por la Cloud Function 'createEmergency'
      // No necesitamos enviarlas de nuevo desde el cliente

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
        'isReactivation': false,
      };
    } catch (e) {
      print('❌ Error activando emergencia: $e');
      if (context != null) {
        _showErrorMessage(context, e.toString());
      }
      return null;
    }
  }

  // Obtener emergencia activa (sin resolver) del niño
  Future<Map<String, dynamic>?> _getActiveEmergency(String childId) async {
    try {
      final snapshot = await _firestore
          .collection('emergencies')
          .where('childId', isEqualTo: childId)
          .where('resolved', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final doc = snapshot.docs.first;
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }

      return null;
    } catch (e) {
      print('❌ Error obteniendo emergencia activa: $e');
      return null;
    }
  }

  // Obtener ubicación actual (se ejecuta en background)
  Future<Position?> _getCurrentLocation() async {
    try {
      print('📍 Obteniendo ubicación de emergencia en background...');

      // Verificar permisos
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('❌ Sin permisos de ubicación para emergencia');
        return null;
      }

      // Obtener ubicación actual con alta precisión
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
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

  // Crear registro de emergencia usando Cloud Function segura con rate limiting
  Future<String?> _createEmergencyRecord({
    required String childId,
    required String childName,
    Position? position,
    String? customMessage,
  }) async {
    try {
      print('🔐 Creando emergencia usando Cloud Function segura...');

      // Preparar datos de ubicación
      Map<String, dynamic>? locationData;
      if (position != null) {
        locationData = {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'timestamp': DateTime.now().toIso8601String(),
        };
      }

      // Llamar a Cloud Function con rate limiting integrado
      final callable = _functions.httpsCallable('createEmergency');
      final result = await callable.call({
        'customMessage': customMessage,
        'location': locationData,
      });

      final data = result.data as Map<String, dynamic>;

      if (data['success'] == true) {
        final emergencyId = data['emergencyId'] as String;
        print('✅ Emergencia creada via Cloud Function: $emergencyId');
        print('📧 ${data['notifiedParents']} padres notificados');
        return emergencyId;
      } else {
        print('❌ Error: Cloud Function no retornó success');
        return null;
      }
    } on FirebaseFunctionsException catch (e) {
      print('❌ Error de Cloud Function: ${e.code} - ${e.message}');

      // Mostrar mensaje específico según el error
      if (e.code == 'resource-exhausted') {
        print('⚠️ Rate limit excedido: ${e.message}');
      } else if (e.code == 'failed-precondition') {
        print('⚠️ Sin padres vinculados: ${e.message}');
      }

      return null;
    } catch (e) {
      print('❌ Error creando emergencia: $e');
      return null;
    }
  }

  // Obtener lista de padres/tutores
  // ⚠️ CORREGIDO: Busca padres en TODOS los documentos users que tengan al childId en linkedChildrenIds
  Future<List<Map<String, dynamic>>> _getParents(String childId) async {
    try {
      // Buscar todos los usuarios que tengan este childId en su array linkedChildrenIds
      final usersSnapshot = await _firestore
          .collection('users')
          .where('linkedChildrenIds', arrayContains: childId)
          .get();

      List<Map<String, dynamic>> parents = [];

      for (var userDoc in usersSnapshot.docs) {
        final parentData = userDoc.data();
        parentData['id'] = userDoc.id;
        parents.add(parentData);
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

  // Realizar llamada de emergencia grupal con Agora
  Future<void> _makeEmergencyVideoCall(List<Map<String, dynamic>> parents, String emergencyId) async {
    try {
      if (parents.isEmpty) {
        print('❌ No hay padres para llamar');
        return;
      }

      final user = _auth.currentUser;
      if (user == null) return;

      // Obtener nombre del niño
      final childName = await _getUserName(user.uid);

      // Extraer IDs y nombres de los padres
      List<String> parentIds = [];
      Map<String, String> parentNames = {};

      for (var parent in parents) {
        final parentId = parent['id'] as String;
        final parentName = parent['name'] ?? 'Padre';

        parentIds.add(parentId);
        parentNames[parentId] = parentName;
      }

      print('🆘 Creando videollamada de emergencia grupal para ${parentIds.length} padres...');

      // ✅ El documento de video_calls ya fue creado por la Cloud Function
      // No necesitamos crearlo de nuevo aquí para evitar race conditions
      // La Cloud Function ya incluye:
      // - callId, callerId, callerName, channelName
      // - isGroupCall, isEmergency, participants, participantIds
      // - status: 'ringing', createdAt, callType

      // ✅ La Cloud Function también ya envió las notificaciones a los padres
      // incluyendo los datos de la llamada (callId, channelName, etc.)

      print('✅ Videollamada de emergencia creada por Cloud Function: $emergencyId');
      print('✅ Padres notificados por Cloud Function');
    } catch (e) {
      print('❌ Error creando llamada de emergencia grupal: $e');
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

      print('🗑️ Resolviendo emergencia: eliminando documento y subcollección...');

      // Detener tracking de ubicación si es la emergencia actual
      if (_currentEmergencyId == emergencyId) {
        stopLocationTracking();
      }

      // 1. Eliminar el historial de ubicaciones (subcollection)
      final trackingDocs = await _firestore
          .collection('emergencies')
          .doc(emergencyId)
          .collection('location_tracking')
          .get();

      final batch = _firestore.batch();
      for (var doc in trackingDocs.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      print('✅ Eliminados ${trackingDocs.docs.length} registros de ubicación');

      // 2. Eliminar el documento principal de emergencia
      await _firestore.collection('emergencies').doc(emergencyId).delete();
      print('✅ Emergencia eliminada completamente: $emergencyId');

      return true;
    } catch (e) {
      print('❌ Error resolviendo emergencia: $e');
      return false;
    }
  }

  // Obtener emergencias activas para TODOS los hijos de un padre
  // ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds por seguridad
  Stream<QuerySnapshot> getActiveEmergenciesForParent(String parentId) async* {
    try {
      print('🚨 [EmergencyService] Buscando emergencias para padre: $parentId');

      // Obtener IDs de todos los hijos del padre desde linkedChildrenIds
      final parentDoc = await _firestore.collection('users').doc(parentId).get();

      if (!parentDoc.exists) {
        print('⚠️ [EmergencyService] Usuario padre $parentId no existe');
        yield* Stream.value(
          await _firestore.collection('emergencies').where('childId', isEqualTo: 'no_parent').get(),
        );
        return;
      }

      final parentData = parentDoc.data() as Map<String, dynamic>?;
      final childrenIds = List<String>.from(parentData?['linkedChildrenIds'] ?? []);

      print('🔍 [EmergencyService] linkedChildrenIds: ${childrenIds.length} hijos');

      if (childrenIds.isEmpty) {
        // Si no tiene hijos, emitir stream vacío
        print('⚠️ [EmergencyService] No se encontraron hijos para el padre $parentId');
        yield* Stream.value(
          await _firestore.collection('emergencies').where('childId', isEqualTo: 'no_children').get(),
        );
        return;
      }

      print('📡 [EmergencyService] Escuchando emergencias de ${childrenIds.length} hijos: $childrenIds');

      // Escuchar emergencias activas de todos los hijos
      final stream = _firestore
          .collection('emergencies')
          .where('childId', whereIn: childrenIds)
          .where('resolved', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .snapshots();

      await for (final snapshot in stream) {
        print('📡 [EmergencyService] Recibido snapshot con ${snapshot.docs.length} emergencias');
        for (final doc in snapshot.docs) {
          final data = doc.data();
          print('🆘 [EmergencyService] Emergencia: ${doc.id} - resolved: ${data['resolved']} - childId: ${data['childId']}');
        }
        yield snapshot;
      }
    } catch (e) {
      print('❌ [EmergencyService] Error obteniendo emergencias del padre: $e');
      print('❌ [EmergencyService] Stack trace: ${StackTrace.current}');
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
    // Sin mensaje de cooldown
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