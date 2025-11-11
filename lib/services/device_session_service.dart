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
    }

    return {
      'platform': 'Unknown',
      'model': 'Unknown',
      'manufacturer': 'Unknown',
      'version': 'Unknown',
    };
  }

  /// Registrar sesión del dispositivo actual en Firestore
  Future<void> registerDeviceSession(String userId) async {
    try {
      final deviceId = await getDeviceId();
      final deviceInfo = await getDeviceInfo();

      await _firestore.collection('users').doc(userId).set({
        'activeDeviceId': deviceId,
        'activeDeviceInfo': deviceInfo,
        'lastLoginAt': FieldValue.serverTimestamp(),
        'lastLoginDeviceId': deviceId,
      }, SetOptions(merge: true));

    } catch (e) {
      rethrow;
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

      // Si hay un dispositivo activo diferente al actual, cerrar sesión
      if (activeDeviceId != null && activeDeviceId != currentDeviceId) {

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

        // Navegar a login
        if (context.mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
        }
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
