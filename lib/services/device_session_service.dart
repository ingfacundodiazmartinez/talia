import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import '../utils/release_logger.dart';

/// Servicio para gestionar sesiones únicas por dispositivo
/// Solo permite que un usuario esté logueado en un dispositivo a la vez
class DeviceSessionService {
  // Singleton pattern
  static final DeviceSessionService _instance = DeviceSessionService._internal();
  factory DeviceSessionService() => _instance;
  DeviceSessionService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  StreamSubscription<DocumentSnapshot>? _sessionListener;
  String? _currentDeviceId;
  bool _isCheckingSession = false;

  /// 🔒 LIFECYCLE MANAGEMENT para prevenir memory leaks
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Flag para ignorar el primer snapshot después de registrar sesión
  /// Esto previene que el dispositivo nuevo se cierre a sí mismo
  bool _justRegisteredSession = false;
  DateTime? _sessionRegisteredAt;

  /// Obtener ID único del dispositivo actual
  Future<String> getDeviceId() async {
    if (_currentDeviceId != null) return _currentDeviceId!;

    try {
      String deviceId;

      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        // Usar una combinación de ID único del dispositivo Android
        deviceId = '${androidInfo.id}_${androidInfo.device}_${androidInfo.model}';
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfo.iosInfo;
        // Usar identifierForVendor en iOS
        deviceId = iosInfo.identifierForVendor ?? 'ios_unknown';
      } else {
        deviceId = 'unknown_device';
      }

      _currentDeviceId = deviceId;
      return deviceId;
    } catch (e) {
      _currentDeviceId = 'fallback_${DateTime.now().millisecondsSinceEpoch}';
      return _currentDeviceId!;
    }
  }

  /// Obtener información del dispositivo para mostrar al usuario
  Future<Map<String, String>> getDeviceInfo() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        return {
          'platform': 'Android',
          'model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'version': androidInfo.version.release,
        };
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfo.iosInfo;
        return {
          'platform': 'iOS',
          'model': iosInfo.utsname.machine,
          'name': iosInfo.name,
          'version': iosInfo.systemVersion,
        };
      }
    } catch (e) {
      ReleaseLogger.error('Error obteniendo info de dispositivo: $e', tag: 'DeviceSessionService');
    }

    return {
      'platform': 'Unknown',
      'model': 'Unknown',
      'manufacturer': 'Unknown',
      'version': 'Unknown',
    };
  }

  /// Registrar sesión del dispositivo actual en Firestore
  /// IMPORTANTE: Solo actualiza si el documento ya existe para no interferir
  /// con el flujo de ProfileCompletionScreen
  ///
  /// Retorna true si la sesión fue registrada exitosamente
  Future<bool> registerDeviceSession(String userId) async {
    try {
      final deviceId = await getDeviceId();
      final deviceInfo = await getDeviceInfo();

      // Primero verificar si el usuario existe en Firestore
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) {
        // Usuario nuevo - no registrar sesión aún, esperar a que complete perfil
        ReleaseLogger.log('📱 Usuario nuevo, esperando completar perfil antes de registrar sesión', tag: 'DeviceSessionService');
        return false;
      }

      // Marcar que acabamos de registrar sesión (para ignorar primer snapshot del listener)
      _justRegisteredSession = true;
      _sessionRegisteredAt = DateTime.now();

      // Usuario existente - actualizar datos de sesión
      await _firestore.collection('users').doc(userId).update({
        'activeDeviceId': deviceId,
        'activeDeviceInfo': deviceInfo,
        'lastLoginAt': FieldValue.serverTimestamp(),
        'lastLoginDeviceId': deviceId,
      });

      ReleaseLogger.log('✅ Sesión registrada para dispositivo: $deviceId', tag: 'DeviceSessionService');
      return true;

    } catch (e) {
      // Si falla porque el documento no existe, simplemente ignorar
      // El usuario necesita completar su perfil primero
      ReleaseLogger.log('⚠️ Error registrando sesión (puede ser usuario nuevo): $e', tag: 'DeviceSessionService');
      return false;
    }
  }

  /// Iniciar escucha de cambios de sesión
  /// Si otro dispositivo inicia sesión, cierra sesión automáticamente en este
  void startSessionListener(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) return;

    // Cancelar listener anterior si existe
    stopSessionListener();

    _sessionListener = _firestore
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snapshot) async {
      if (!snapshot.exists || _isCheckingSession) return;

      final data = snapshot.data();
      if (data == null) return;

      final activeDeviceId = data['activeDeviceId'] as String?;
      final currentDeviceId = await getDeviceId();

      // ✅ FIX: Si acabamos de registrar sesión, ignorar los primeros 5 segundos
      // Esto previene que el dispositivo nuevo se cierre a sí mismo debido a
      // latencia en la propagación del update a Firestore
      if (_justRegisteredSession && _sessionRegisteredAt != null) {
        final timeSinceRegistration = DateTime.now().difference(_sessionRegisteredAt!);
        if (timeSinceRegistration.inSeconds < 5) {
          ReleaseLogger.log(
            '⏳ Ignorando snapshot (sesión recién registrada, ${timeSinceRegistration.inMilliseconds}ms)',
            tag: 'DeviceSessionService',
          );
          return;
        } else {
          // Ya pasaron 5 segundos, desactivar el flag
          _justRegisteredSession = false;
          _sessionRegisteredAt = null;
        }
      }

      // Si hay un dispositivo activo diferente al actual, cerrar sesión
      if (activeDeviceId != null && activeDeviceId != currentDeviceId) {
        ReleaseLogger.log(
          '🔄 Detectado otro dispositivo activo: $activeDeviceId (actual: $currentDeviceId)',
          tag: 'DeviceSessionService',
        );

        _isCheckingSession = true;

        // Mostrar diálogo al usuario antes de cerrar sesión
        if (context.mounted) {
          final deviceInfo = data['activeDeviceInfo'] as Map<String, dynamic>?;
          final platform = deviceInfo?['platform'] ?? 'Unknown';
          final model = deviceInfo?['model'] ?? 'Unknown';

          await _showSessionExpiredDialog(
            context,
            newDevice: '$platform $model',
          );
        }

        // Cerrar sesión en este dispositivo
        await _signOutCurrentDevice();

        _isCheckingSession = false;

        // ✅ FIX: No navegar manualmente - Firebase Auth ya maneja el logout
        // El AuthWrapper detectará el cambio de estado y mostrará la pantalla de login
        // Navegar a una ruta nombrada que no existe causa "Null check operator" error
        ReleaseLogger.log('🔒 Sesión cerrada - AuthWrapper redirigirá a login', tag: 'DeviceSessionService');
      }
    }, onError: (error) {
      ReleaseLogger.error('❌ Error en session listener: $error', tag: 'DeviceSessionService');
    });

    ReleaseLogger.log('👂 Session listener iniciado para usuario: ${user.uid}', tag: 'DeviceSessionService');
  }

  /// Detener escucha de cambios de sesión
  void stopSessionListener() {
    _sessionListener?.cancel();
    _sessionListener = null;
    ReleaseLogger.log('🛑 Session listener detenido', tag: 'DeviceSessionService');
  }

  /// Mostrar diálogo informando que la sesión expiró
  Future<void> _showSessionExpiredDialog(
    BuildContext context, {
    required String newDevice,
  }) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Sesión cerrada'),
        content: Text(
          'Tu cuenta ha iniciado sesión en otro dispositivo:\n\n'
          '$newDevice\n\n'
          'Solo puedes estar conectado en un dispositivo a la vez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  /// Cerrar sesión del dispositivo actual
  Future<void> _signOutCurrentDevice() async {
    try {
      final user = _auth.currentUser;
      if (user != null) {
        // Actualizar estado del usuario
        await _firestore.collection('users').doc(user.uid).set({
          'isOnline': false,
          'lastSeen': FieldValue.serverTimestamp(),
          'fcmToken': null,
          'voipToken': null, // Limpiar también el token VoIP
        }, SetOptions(merge: true));
      }

      // Cerrar sesión de Firebase Auth
      await _auth.signOut();

    } catch (e) {
      ReleaseLogger.error('Error cerrando sesión del dispositivo: $e', tag: 'DeviceSessionService');
    }
  }

  /// Verificar si el dispositivo actual tiene la sesión activa
  Future<bool> isCurrentDeviceActive() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return false;

      final data = userDoc.data();
      final activeDeviceId = data?['activeDeviceId'] as String?;
      final currentDeviceId = await getDeviceId();

      return activeDeviceId == currentDeviceId;
    } catch (e) {
      return false;
    }
  }

  /// Limpiar al hacer dispose
  /// 🔒 LIFECYCLE MANAGEMENT: Limpiar recursos y permitir re-inicialización
  void dispose() {
    ReleaseLogger.log('🗑️ Limpiando recursos DeviceSession Service...', tag: 'DeviceSessionService');

    stopSessionListener();
    _currentDeviceId = null;
    _isCheckingSession = false;
    _isInitialized = false;

    ReleaseLogger.log('✅ DeviceSession Service resources disposed', tag: 'DeviceSessionService');
  }

  /// 🔒 BACKGROUND LIFECYCLE: Limpiar recursos cuando la app va a background
  void onAppPaused() {
    ReleaseLogger.log('⏸️ DeviceSession Service: App pausada, manteniendo sesión activa', tag: 'DeviceSessionService');
    // No detener completamente la sesión en pausa, pero sí limpiar el listener
    stopSessionListener();
  }

  /// 🔒 FOREGROUND LIFECYCLE: Re-conectar cuando la app vuelve de background
  Future<void> onAppResumed() async {
    ReleaseLogger.log('▶️ DeviceSession Service: App resumida', tag: 'DeviceSessionService');

    // Re-inicializar listener de sesión si hay usuario autenticado
    final user = _auth.currentUser;
    if (user != null) {
      _startSessionListenerSilent();
    }
  }

  /// Versión sin UI para uso en background services
  void _startSessionListenerSilent() {
    final user = _auth.currentUser;
    if (user == null) return;

    // Cancelar listener anterior si existe
    stopSessionListener();

    _sessionListener = _firestore
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snapshot) async {
      if (!snapshot.exists || _isCheckingSession) return;

      final data = snapshot.data();
      if (data == null) return;

      final activeDeviceId = data['activeDeviceId'] as String?;
      final currentDeviceId = await getDeviceId();

      // ✅ FIX: Si acabamos de registrar sesión, ignorar los primeros 5 segundos
      if (_justRegisteredSession && _sessionRegisteredAt != null) {
        final timeSinceRegistration = DateTime.now().difference(_sessionRegisteredAt!);
        if (timeSinceRegistration.inSeconds < 5) {
          return;
        } else {
          _justRegisteredSession = false;
          _sessionRegisteredAt = null;
        }
      }

      // Si hay un dispositivo activo diferente al actual, cerrar sesión silenciosamente
      if (activeDeviceId != null && activeDeviceId != currentDeviceId) {
        ReleaseLogger.log('🔒 Sesión detectada en otro dispositivo: $activeDeviceId (actual: $currentDeviceId)', tag: 'DeviceSessionService');

        _isCheckingSession = true;

        // Cerrar sesión silenciosamente
        await _signOutCurrentDevice();

        _isCheckingSession = false;
      }
    });

    ReleaseLogger.log('📱 Session listener iniciado (modo silencioso)', tag: 'DeviceSessionService');
  }
}
