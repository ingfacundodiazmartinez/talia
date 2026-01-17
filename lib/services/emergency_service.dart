import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/release_logger.dart';

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
      ReleaseLogger.error('❌ Error verificando cooldown: $e', tag: 'EmergencyService');
      return false;
    }
  }

  // Activar emergencia completa
  Future<Map<String, dynamic>?> activateEmergency({
    String? customMessage,
    BuildContext? context,
  }) async {
    try {
      ReleaseLogger.log('🆘 Activando emergencia...', tag: 'EmergencyService');

      final user = _auth.currentUser;
      if (user == null) {
        ReleaseLogger.error('❌ Usuario no autenticado', tag: 'EmergencyService');
        return null;
      }

      // ✅ NUEVO: Verificar si ya existe una emergencia activa (sin resolver)
      final existingEmergency = await _getActiveEmergency(user.uid);

      if (existingEmergency != null) {
        final emergencyId = existingEmergency['id'] as String;
        ReleaseLogger.log('⚠️ Ya existe emergencia activa: $emergencyId', tag: 'EmergencyService');
        ReleaseLogger.log('📞 Reactivando llamada sin crear nueva emergencia...', tag: 'EmergencyService');

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
        ReleaseLogger.log('⏰ Emergencia en cooldown', tag: 'EmergencyService');
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
        ReleaseLogger.error('❌ No se pudo obtener datos del niño', tag: 'EmergencyService');
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
        ReleaseLogger.error('❌ Error creando registro de emergencia', tag: 'EmergencyService');
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

      ReleaseLogger.log('✅ Emergencia activada exitosamente', tag: 'EmergencyService');

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
      ReleaseLogger.error('❌ Error activando emergencia: $e', tag: 'EmergencyService');
      if (context != null) {
        _showErrorMessage(context, e.toString());
      }
      return null;
    }
  }

  /// ✅ OPTIMISTIC: Activar emergencia de forma inmediata
  /// NO espera ubicación - la obtiene en background después de crear la emergencia
  Future<Map<String, dynamic>?> activateEmergencyOptimistic({
    String? customMessage,
    BuildContext? context,
  }) async {
    try {
      ReleaseLogger.log('🆘 [OPTIMISTIC] Activando emergencia inmediatamente...', tag: 'EmergencyService');

      final user = _auth.currentUser;
      if (user == null) {
        ReleaseLogger.error('❌ Usuario no autenticado', tag: 'EmergencyService');
        return null;
      }

      // ✅ PASO 1: Verificar si ya existe una emergencia activa (rápido)
      final existingEmergency = await _getActiveEmergency(user.uid);

      if (existingEmergency != null) {
        final emergencyId = existingEmergency['id'] as String;
        ReleaseLogger.log('⚠️ Ya existe emergencia activa: $emergencyId', tag: 'EmergencyService');

        // Vibración de emergencia
        await _triggerEmergencyVibration();

        if (context != null) {
          _showEmergencyConfirmation(context);
        }

        // Retornar información de la emergencia existente para unirse a la llamada
        return {
          'emergencyId': emergencyId,
          'channelName': 'emergency_$emergencyId',
          'success': true,
          'isReactivation': true,
        };
      }

      // ✅ PASO 2: Verificar cooldown (rápido)
      if (await isInCooldown()) {
        ReleaseLogger.log('⏰ Emergencia en cooldown', tag: 'EmergencyService');
        if (context != null) {
          _showCooldownMessage(context);
        }
        return null;
      }

      // ✅ PASO 3: Vibración de emergencia (inmediato)
      await _triggerEmergencyVibration();

      // ✅ PASO 4: Llamar Cloud Function INMEDIATAMENTE (sin ubicación)
      ReleaseLogger.log('🚀 [OPTIMISTIC] Llamando Cloud Function sin esperar ubicación...', tag: 'EmergencyService');

      final emergencyId = await _createEmergencyRecord(
        childId: user.uid,
        childName: '', // Cloud Function obtiene el nombre del usuario
        position: null, // ✅ NO esperamos ubicación
        customMessage: customMessage,
      );

      if (emergencyId == null) {
        ReleaseLogger.error('❌ Error creando registro de emergencia', tag: 'EmergencyService');
        return null;
      }

      // ✅ PASO 5: Guardar timestamp (rápido)
      await _saveLastEmergencyTime();

      ReleaseLogger.log('✅ [OPTIMISTIC] Emergencia creada: $emergencyId', tag: 'EmergencyService');

      if (context != null) {
        _showEmergencyConfirmation(context);
      }

      // ✅ PASO 6: Obtener ubicación y actualizar en BACKGROUND (no bloqueante)
      _updateLocationInBackground(emergencyId);

      // ✅ PASO 7: Iniciar tracking continuo de ubicación en background
      _startLocationTracking(emergencyId);

      // Retornar inmediatamente para que la UI pueda navegar a la llamada
      return {
        'emergencyId': emergencyId,
        'channelName': 'emergency_$emergencyId',
        'success': true,
        'isReactivation': false,
      };
    } catch (e) {
      ReleaseLogger.error('❌ Error activando emergencia optimística: $e', tag: 'EmergencyService');
      if (context != null) {
        _showErrorMessage(context, e.toString());
      }
      return null;
    }
  }

  /// Actualizar ubicación en background (no bloquea la UI)
  void _updateLocationInBackground(String emergencyId) {
    // Ejecutar sin await para no bloquear
    Future(() async {
      try {
        ReleaseLogger.log('📍 [BACKGROUND] Obteniendo ubicación para emergencia $emergencyId...', tag: 'EmergencyService');

        final position = await _getCurrentLocation();

        if (position != null) {
          // Actualizar el documento de emergencia con la ubicación
          await _firestore.collection('emergencies').doc(emergencyId).update({
            'location': {
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracy': position.accuracy,
              'timestamp': DateTime.now().toIso8601String(),
            },
          });

          ReleaseLogger.log('✅ [BACKGROUND] Ubicación actualizada para emergencia $emergencyId', tag: 'EmergencyService');
        } else {
          ReleaseLogger.log('⚠️ [BACKGROUND] No se pudo obtener ubicación para emergencia $emergencyId', tag: 'EmergencyService');
        }
      } catch (e) {
        ReleaseLogger.error('❌ [BACKGROUND] Error actualizando ubicación: $e', tag: 'EmergencyService');
      }
    });
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
      ReleaseLogger.error('❌ Error obteniendo emergencia activa: $e', tag: 'EmergencyService');
      return null;
    }
  }

  // Obtener ubicación actual (se ejecuta en background)
  Future<Position?> _getCurrentLocation() async {
    try {
      ReleaseLogger.log('📍 Obteniendo ubicación de emergencia en background...', tag: 'EmergencyService');

      // Verificar permisos
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        ReleaseLogger.error('❌ Sin permisos de ubicación para emergencia', tag: 'EmergencyService');
        return null;
      }

      // ✅ OPTIMIZACIÓN: Intentar obtener última ubicación conocida primero (instantáneo)
      Position? lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        ReleaseLogger.log('📍 Usando última ubicación conocida: ${lastKnown.latitude}, ${lastKnown.longitude}', tag: 'EmergencyService');

        // Intentar obtener ubicación más precisa en paralelo (sin bloquear)
        _tryGetPreciseLocationInBackground();

        return lastKnown;
      }

      // Si no hay ubicación conocida, obtener una nueva con precisión media (más rápido)
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 5),
      );

      ReleaseLogger.log('✅ Ubicación de emergencia obtenida: ${position.latitude}, ${position.longitude}', tag: 'EmergencyService');
      return position;
    } catch (e) {
      ReleaseLogger.log('⚠️ No se pudo obtener ubicación (no crítico): $e', tag: 'EmergencyService');
      return null;
    }
  }

  // Intentar obtener ubicación precisa en background (no bloquea nada)
  void _tryGetPreciseLocationInBackground() {
    Future(() async {
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        );

        // Actualizar la emergencia actual si existe
        if (_currentEmergencyId != null) {
          await _firestore.collection('emergencies').doc(_currentEmergencyId).update({
            'location': {
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracy': position.accuracy,
              'timestamp': DateTime.now().toIso8601String(),
              'isPrecise': true,
            },
          });
          ReleaseLogger.log('✅ Ubicación precisa actualizada: ${position.latitude}, ${position.longitude}', tag: 'EmergencyService');
        }
      } catch (e) {
        // Silencioso - ya tenemos una ubicación aproximada
      }
    });
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
      ReleaseLogger.error('❌ Error obteniendo datos del niño: $e', tag: 'EmergencyService');
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
      ReleaseLogger.log('🔐 Creando emergencia usando Cloud Function segura...', tag: 'EmergencyService');

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
        ReleaseLogger.log('✅ Emergencia creada via Cloud Function: $emergencyId', tag: 'EmergencyService');
        ReleaseLogger.log('📧 ${data['notifiedParents']} padres notificados', tag: 'EmergencyService');
        return emergencyId;
      } else {
        ReleaseLogger.error('❌ Error: Cloud Function no retornó success', tag: 'EmergencyService');
        return null;
      }
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('❌ Error de Cloud Function: ${e.code} - ${e.message}', tag: 'EmergencyService');

      // Mostrar mensaje específico según el error
      if (e.code == 'resource-exhausted') {
        ReleaseLogger.log('⚠️ Rate limit excedido: ${e.message}', tag: 'EmergencyService');
      } else if (e.code == 'failed-precondition') {
        ReleaseLogger.log('⚠️ Sin padres vinculados: ${e.message}', tag: 'EmergencyService');
      }

      return null;
    } catch (e) {
      ReleaseLogger.error('❌ Error creando emergencia: $e', tag: 'EmergencyService');
      return null;
    }
  }

  // Obtener lista de padres/tutores
  // ✅ CORREGIDO: Usar colección parent_children (misma lógica que Cloud Function)
  Future<List<Map<String, dynamic>>> _getParents(String childId) async {
    try {
      // Buscar padres vinculados en la colección parent_children
      final parentLinks = await _firestore
          .collection('parent_children')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'approved')
          .get();

      List<Map<String, dynamic>> parents = [];

      for (var parentLink in parentLinks.docs) {
        final parentId = parentLink.data()['parentId'] as String;
        final parentDoc = await _firestore.collection('users').doc(parentId).get();

        if (parentDoc.exists) {
          final parentData = parentDoc.data()!;
          parentData['id'] = parentDoc.id;
          parents.add(parentData);
        }
      }

      ReleaseLogger.log('✅ Encontrados ${parents.length} padres vinculados desde parent_children', tag: 'EmergencyService');
      return parents;
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo padres: $e', tag: 'EmergencyService');
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

        ReleaseLogger.log('✅ Notificación de emergencia enviada a $parentName', tag: 'EmergencyService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificaciones: $e', tag: 'EmergencyService');
    }
  }

  // Realizar llamada de emergencia grupal con Agora
  Future<void> _makeEmergencyVideoCall(List<Map<String, dynamic>> parents, String emergencyId) async {
    try {
      if (parents.isEmpty) {
        ReleaseLogger.error('❌ No hay padres para llamar', tag: 'EmergencyService');
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

      ReleaseLogger.log('🆘 Creando videollamada de emergencia grupal para ${parentIds.length} padres...', tag: 'EmergencyService');

      // ✅ El documento de video_calls ya fue creado por la Cloud Function
      // No necesitamos crearlo de nuevo aquí para evitar race conditions
      // La Cloud Function ya incluye:
      // - callId, callerId, callerName, channelName
      // - isGroupCall, isEmergency, participants, participantIds
      // - status: 'ringing', createdAt, callType

      // ✅ La Cloud Function también ya envió las notificaciones a los padres
      // incluyendo los datos de la llamada (callId, channelName, etc.)

      ReleaseLogger.log('✅ Videollamada de emergencia creada por Cloud Function: $emergencyId', tag: 'EmergencyService');
      ReleaseLogger.log('✅ Padres notificados por Cloud Function', tag: 'EmergencyService');
    } catch (e) {
      ReleaseLogger.error('❌ Error creando llamada de emergencia grupal: $e', tag: 'EmergencyService');
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
      ReleaseLogger.log('📍 Iniciando tracking de ubicación de emergencia...', tag: 'EmergencyService');

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
          ReleaseLogger.log('⏰ Deteniendo tracking automáticamente después de 1 hora', tag: 'EmergencyService');
          stopLocationTracking();
        }
      });

      ReleaseLogger.log('✅ Tracking de ubicación iniciado', tag: 'EmergencyService');
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando tracking de ubicación: $e', tag: 'EmergencyService');
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

      ReleaseLogger.log('📍 Ubicación guardada: ${position.latitude}, ${position.longitude}', tag: 'EmergencyService');
    } catch (e) {
      ReleaseLogger.error('❌ Error guardando punto de ubicación: $e', tag: 'EmergencyService');
    }
  }

  // Detener tracking de ubicación
  void stopLocationTracking() {
    _locationTrackingTimer?.cancel();
    _locationTrackingTimer = null;
    _currentEmergencyId = null;
    ReleaseLogger.log('⏹️ Tracking de ubicación detenido', tag: 'EmergencyService');
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
      ReleaseLogger.error('❌ Error en vibración de emergencia: $e', tag: 'EmergencyService');
    }
  }

  // Guardar timestamp de último uso
  Future<void> _saveLastEmergencyTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_emergency_time', DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      ReleaseLogger.error('❌ Error guardando timestamp de emergencia: $e', tag: 'EmergencyService');
    }
  }

  // Resolver emergencia (para padres)
  Future<bool> resolveEmergency(String emergencyId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      ReleaseLogger.log('🗑️ Resolviendo emergencia: eliminando documento y subcollección...', tag: 'EmergencyService');

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
      ReleaseLogger.log('✅ Eliminados ${trackingDocs.docs.length} registros de ubicación', tag: 'EmergencyService');

      // 2. Eliminar el documento principal de emergencia
      await _firestore.collection('emergencies').doc(emergencyId).delete();
      ReleaseLogger.log('✅ Emergencia eliminada completamente: $emergencyId', tag: 'EmergencyService');

      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error resolviendo emergencia: $e', tag: 'EmergencyService');
      return false;
    }
  }

  // Cached streams por parentId para evitar crear nuevos streams en cada call
  final Map<String, Stream<QuerySnapshot>> _cachedEmergencyStreams = {};

  // Limpiar cache de streams para forzar recreación con nueva lógica
  void clearEmergencyStreamsCache() {
    _cachedEmergencyStreams.clear();
    ReleaseLogger.log('🗑️ [EmergencyService] Cache de streams limpiado - se recrearán con nueva lógica', tag: 'EmergencyService');
  }

  // Obtener emergencias activas para TODOS los hijos de un padre
  // ✅ CORREGIDO: Retorna el mismo stream object para evitar infinite rebuilds
  Stream<QuerySnapshot> getActiveEmergenciesForParent(String parentId) {
    // ✅ Usar cache para retornar el mismo stream object
    if (_cachedEmergencyStreams.containsKey(parentId)) {
      ReleaseLogger.log('📋 [EmergencyService] Usando stream cacheado para padre: $parentId', tag: 'EmergencyService');
      return _cachedEmergencyStreams[parentId]!;
    }

    ReleaseLogger.log('🚨 [EmergencyService] Creando nuevo stream para padre: $parentId', tag: 'EmergencyService');

    // ✅ CORREGIDO: Convertir Future<Stream> en Stream usando asyncExpand y hacer broadcast
    final stream = Stream.fromFuture(_createEmergencyStreamForParent(parentId))
        .asyncExpand((innerStream) => innerStream)
        .asBroadcastStream();

    // ✅ Cachear el stream
    _cachedEmergencyStreams[parentId] = stream;

    return stream;
  }

  // Helper method para crear el stream real
  Future<Stream<QuerySnapshot>> _createEmergencyStreamForParent(String parentId) async {
    ReleaseLogger.log('🚨 [EmergencyService] Creando stream estable para padre: $parentId', tag: 'EmergencyService');

    try {
      // ✅ CORREGIDO: Usar colección parent_children (misma lógica que Cloud Function)
      // Buscar hijos vinculados en la colección parent_children
      final parentLinks = await _firestore
          .collection('parent_children')
          .where('parentId', isEqualTo: parentId)
          .where('status', isEqualTo: 'approved')
          .get();

      if (parentLinks.docs.isEmpty) {
        ReleaseLogger.log('⚠️ [EmergencyService] No se encontraron hijos vinculados para el padre $parentId', tag: 'EmergencyService');
        // Retornar stream vacío estable
        return _firestore.collection('emergencies').where('childId', isEqualTo: 'no_children').snapshots();
      }

      // Extraer los childIds de los documentos parent_children
      final childrenIds = parentLinks.docs
          .map((doc) => doc.data()['childId'] as String)
          .toList();

      ReleaseLogger.log('🔍 [EmergencyService] Hijos vinculados desde parent_children: ${childrenIds.length} hijos', tag: 'EmergencyService');
      ReleaseLogger.log('🔍 [EmergencyService] ChildIds: $childrenIds', tag: 'EmergencyService');

      ReleaseLogger.log('📡 [EmergencyService] Escuchando emergencias de ${childrenIds.length} hijos: $childrenIds', tag: 'EmergencyService');

      // ✅ CORREGIDO: Retornar stream fijo que NO cambia nunca - completamente estable
      return _firestore
          .collection('emergencies')
          .where('childId', whereIn: childrenIds)
          .where('resolved', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .snapshots()
          .map((snapshot) {
        ReleaseLogger.log('📡 [EmergencyService] Recibido snapshot con ${snapshot.docs.length} emergencias', tag: 'EmergencyService');
        for (final doc in snapshot.docs) {
          final data = doc.data();
          ReleaseLogger.log('🆘 [EmergencyService] Emergencia: ${doc.id} - resolved: ${data['resolved']} - childId: ${data['childId']}', tag: 'EmergencyService');
        }
        return snapshot;
      });
    } catch (e) {
      ReleaseLogger.error('❌ [EmergencyService] Error obteniendo emergencias del padre: $e', tag: 'EmergencyService');
      // Retornar stream vacío estable
      return _firestore.collection('emergencies').where('childId', isEqualTo: 'error').snapshots();
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
      ReleaseLogger.error('❌ Error obteniendo historial de emergencias: $e', tag: 'EmergencyService');
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