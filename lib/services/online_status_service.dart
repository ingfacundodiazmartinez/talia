import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Servicio para gestionar el estado en línea del usuario
/// Actualiza automáticamente isOnline según el ciclo de vida de la app
class OnlineStatusService with WidgetsBindingObserver {
  // Singleton pattern
  static final OnlineStatusService _instance = OnlineStatusService._internal();
  factory OnlineStatusService() => _instance;
  OnlineStatusService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _isInitialized = false;
  Timer? _heartbeatTimer;
  DateTime? _lastOnlineUpdate;

  /// Inicializar el servicio
  void initialize() {
    if (_isInitialized) return;

    WidgetsBinding.instance.addObserver(this);
    _isInitialized = true;

    // Actualizar estado a online al inicializar
    _setOnlineStatus(true);

    // Iniciar heartbeat cada 30 segundos para mantener estado online
    _startHeartbeat();

    print('✅ OnlineStatusService inicializado');
  }

  /// Iniciar heartbeat para mantener estado online mientras la app está activa
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      // Solo actualizar si el usuario está autenticado
      if (_auth.currentUser != null) {
        _updateLastSeen();
      }
    });
  }

  /// Detener heartbeat
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Actualizar estado en línea
  Future<void> _setOnlineStatus(bool isOnline) async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Verificar si el usuario permite mostrar estado online
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();
      final showOnlineStatus = userData?['showOnlineStatus'] ?? true;

      await _firestore.collection('users').doc(user.uid).set({
        'isOnline': isOnline && showOnlineStatus,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _lastOnlineUpdate = DateTime.now();

      print('${isOnline ? '🟢' : '⚫'} Estado online actualizado: $isOnline');
    } catch (e) {
      print('❌ Error actualizando estado online: $e');
    }
  }

  /// Actualizar solo lastSeen sin cambiar isOnline (para heartbeat)
  Future<void> _updateLastSeen() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Solo actualizar si han pasado al menos 25 segundos desde la última actualización
      if (_lastOnlineUpdate != null &&
          DateTime.now().difference(_lastOnlineUpdate!).inSeconds < 25) {
        return;
      }

      await _firestore.collection('users').doc(user.uid).update({
        'lastSeen': FieldValue.serverTimestamp(),
      });

      _lastOnlineUpdate = DateTime.now();
    } catch (e) {
      // No imprimir error para evitar spam en logs
      // print('⚠️ Error actualizando lastSeen: $e');
    }
  }

  /// Callback cuando cambia el estado de la app
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('📱 App lifecycle cambió: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        // App volvió a primer plano
        _setOnlineStatus(true);
        _startHeartbeat();
        break;

      case AppLifecycleState.inactive:
        // App está inactiva (transición temporal)
        // Marcar como offline inmediatamente para evitar estado "online" falso
        // cuando el usuario cierra/mata la app
        _setOnlineStatus(false);
        break;

      case AppLifecycleState.paused:
        // App fue a segundo plano
        _setOnlineStatus(false);
        _stopHeartbeat();
        break;

      case AppLifecycleState.detached:
        // App está siendo terminada
        _setOnlineStatus(false);
        _stopHeartbeat();
        break;

      case AppLifecycleState.hidden:
        // App está oculta (Android)
        _setOnlineStatus(false);
        break;
    }
  }

  /// Establecer usuario como online manualmente
  Future<void> setOnline() async {
    await _setOnlineStatus(true);
  }

  /// Establecer usuario como offline manualmente
  Future<void> setOffline() async {
    await _setOnlineStatus(false);
  }

  /// Limpiar y disponer recursos
  void dispose() {
    if (!_isInitialized) return;

    _stopHeartbeat();
    WidgetsBinding.instance.removeObserver(this);
    _setOnlineStatus(false);
    _isInitialized = false;

    print('🛑 OnlineStatusService disposed');
  }
}
