import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:workmanager/workmanager.dart' as wm;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Servicio de ubicación en background optimizado para Android
// Usa WorkManager para tareas periódicas y notificaciones persistentes
class BackgroundLocationService {
  static final BackgroundLocationService _instance = BackgroundLocationService._internal();
  factory BackgroundLocationService() => _instance;
  BackgroundLocationService._internal();

  static const String _backgroundTaskName = 'location_update_task';

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _isTracking = false;

  // Cache para optimizar actualizaciones
  static Position? _lastKnownPosition;
  static DateTime? _lastUpdateTime;

  // Inicializar el servicio de background
  Future<void> initialize() async {
    if (_isInitialized) return;

    print('🚀 Inicializando Background Location Service...');

    // Inicializar notificaciones
    await _initializeNotifications();

    // Inicializar WorkManager para Android
    await _initializeWorkManager();

    _isInitialized = true;
    print('✅ Background Location Service inicializado');
  }

  // Inicializar notificaciones persistentes (Android)
  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
    );

    await _notifications.initialize(settings);
    print('✅ Notificaciones inicializadas para Android');
  }

  // Inicializar WorkManager (Android)
  Future<void> _initializeWorkManager() async {
    try {
      await wm.Workmanager().initialize(
        callbackDispatcher,
        isInDebugMode: false, // Cambiar a true para debug
      );
      print('✅ WorkManager inicializado');
    } catch (e) {
      print('❌ Error inicializando WorkManager: $e');
    }
  }


  // Iniciar tracking en background
  Future<void> startBackgroundTracking() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_isTracking) {
      print('⚠️ Background tracking ya está activo');
      return;
    }

    _isTracking = true;
    print('🚀 Iniciando background tracking...');

    // Guardar userId para uso en background
    await saveCurrentUserId();

    // Mostrar notificación persistente
    await _showPersistentNotification();

    // Programar tareas de background
    await _scheduleBackgroundTasks();

    print('✅ Background tracking iniciado');
  }

  // Detener tracking en background
  Future<void> stopBackgroundTracking() async {
    _isTracking = false;

    // Cancelar tareas programadas de WorkManager
    await wm.Workmanager().cancelAll();

    // Ocultar notificación
    await _notifications.cancel(1);

    print('⏹️ Background tracking detenido');
  }

  // Programar tareas de background usando WorkManager (Android)
  Future<void> _scheduleBackgroundTasks() async {
    try {
      await wm.Workmanager().registerPeriodicTask(
        _backgroundTaskName,
        _backgroundTaskName,
        frequency: Duration(minutes: 15), // Mínimo para tareas periódicas
        constraints: wm.Constraints(
          networkType: wm.NetworkType.connected,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
          requiresStorageNotLow: false,
        ),
      );

      print('📅 Tareas de background programadas con WorkManager');
    } catch (e) {
      print('❌ Error programando tareas de background: $e');
    }
  }

  // Mostrar notificación persistente (Android)
  Future<void> _showPersistentNotification() async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'location_tracking',
      'Ubicación en Tiempo Real',
      channelDescription: 'Seguimiento de ubicación para seguridad',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      icon: '@mipmap/ic_launcher',
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      1,
      'Ubicación Activa',
      'Tus padres pueden ver tu ubicación para tu seguridad',
      details,
    );
  }

  // Actualizar ubicación en background (método estático para isolates)
  static Future<void> _updateLocationInBackground() async {
    try {
      print('📍 Actualizando ubicación en background...');

      // Verificar permisos
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('❌ Sin permisos de ubicación');
        return;
      }

      // Obtener ubicación actual con configuración optimizada
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 30), // Timeout para evitar bloqueos
      );

      // Filtrar ubicaciones para evitar actualizaciones innecesarias
      if (_shouldUpdateLocation(position)) {
        await _updateFirestoreLocation(position);
        _lastKnownPosition = position;
        _lastUpdateTime = DateTime.now();
      } else {
        print('📍 Ubicación sin cambios significativos, omitiendo actualización');
      }

      print('✅ Ubicación actualizada en background');
    } catch (e) {
      print('❌ Error actualizando ubicación en background: $e');
    }
  }

  // Actualizar ubicación en Firestore (método estático)
  static Future<void> _updateFirestoreLocation(Position position) async {
    try {
      // Obtener userId desde SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final String? userId = prefs.getString('current_user_id');

      if (userId == null) {
        print('❌ No se encontró userId en SharedPreferences');
        return;
      }

      await FirebaseFirestore.instance
          .collection('user_locations')
          .doc(userId)
          .set({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'timestamp': FieldValue.serverTimestamp(),
        'lastUpdate': DateTime.now().toIso8601String(),
        'source': 'background',
      }, SetOptions(merge: true));

      print('💾 Ubicación guardada en Firestore desde background');
    } catch (e) {
      print('❌ Error guardando en Firestore desde background: $e');
    }
  }

  // Guardar userId para uso en background
  Future<void> saveCurrentUserId() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('current_user_id', user.uid);
        print('💾 UserId guardado para background: ${user.uid}');
      }
    } catch (e) {
      print('❌ Error guardando userId: $e');
    }
  }

  // Determinar si se debe actualizar la ubicación
  static bool _shouldUpdateLocation(Position newPosition) {
    // Si no hay posición previa, siempre actualizar
    if (_lastKnownPosition == null || _lastUpdateTime == null) {
      return true;
    }

    // Calcular distancia desde la última posición
    double distanceInMeters = Geolocator.distanceBetween(
      _lastKnownPosition!.latitude,
      _lastKnownPosition!.longitude,
      newPosition.latitude,
      newPosition.longitude,
    );

    // Tiempo desde la última actualización
    Duration timeSinceLastUpdate = DateTime.now().difference(_lastUpdateTime!);

    // Actualizar si:
    // 1. Se movió más de 50 metros
    // 2. Ha pasado más de 5 minutos (para heartbeat)
    // 3. La precisión mejoró significativamente
    bool significantMovement = distanceInMeters > 50;
    bool timeThreshold = timeSinceLastUpdate.inMinutes > 5;
    bool accuracyImproved = newPosition.accuracy < (_lastKnownPosition!.accuracy * 0.7);

    return significantMovement || timeThreshold || accuracyImproved;
  }

  // Obtener estado del tracking
  bool get isTracking => _isTracking;

  // Limpiar recursos
  void dispose() {
    stopBackgroundTracking();
  }
}

// Callback dispatcher para WorkManager (debe ser función top-level)
void callbackDispatcher() {
  wm.Workmanager().executeTask((task, inputData) async {
    print('🔄 Ejecutando tarea de background: $task');

    try {
      switch (task) {
        case 'location_update_task':
          await BackgroundLocationService._updateLocationInBackground();
          break;
        default:
          print('⚠️ Tarea desconocida: $task');
      }

      return Future.value(true);
    } catch (e) {
      print('❌ Error en tarea de background: $e');
      return Future.value(false);
    }
  });
}

// Servicio de estado de app
class AppStateService {
  static final AppStateService _instance = AppStateService._internal();
  factory AppStateService() => _instance;
  AppStateService._internal();

  AppLifecycleState? _currentState;
  final BackgroundLocationService _bgLocationService = BackgroundLocationService();

  void initialize() {
    WidgetsBinding.instance.addObserver(_AppLifecycleObserver());
  }

  void _onAppStateChanged(AppLifecycleState state) {
    print('📱 Estado de app cambió: $state');
    _currentState = state;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // App en background - iniciar tracking de background
        _bgLocationService.startBackgroundTracking();
        break;
      case AppLifecycleState.resumed:
        // App en foreground - detener tracking de background
        _bgLocationService.stopBackgroundTracking();
        break;
      case AppLifecycleState.inactive:
        // Estado transitorio - no hacer nada
        break;
      case AppLifecycleState.hidden:
        // App oculta pero corriendo
        break;
    }
  }

  AppLifecycleState? get currentState => _currentState;
}

// Observer para cambios de estado de la app
class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppStateService()._onAppStateChanged(state);
  }
}