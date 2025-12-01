import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

/// Servicio para gestionar el estado en línea del usuario
/// Usa Firebase Realtime Database con onDisconnect() para detección automática
/// de desconexión (incluso cuando la app se cierra abruptamente)
class OnlineStatusService with WidgetsBindingObserver {
  // Singleton pattern
  static final OnlineStatusService _instance = OnlineStatusService._internal();
  factory OnlineStatusService() => _instance;
  OnlineStatusService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseDatabase _rtdb = FirebaseDatabase.instance;

  bool _isInitialized = false;
  StreamSubscription<DatabaseEvent>? _connectedSubscription;

  /// Inicializar el servicio con RTDB Presence System
  void initialize() {
    if (_isInitialized) return;

    WidgetsBinding.instance.addObserver(this);
    _isInitialized = true;

    // Configurar presence system con RTDB
    _setupPresence();
  }

  /// Configurar el sistema de presencia con RTDB
  /// Usa onDisconnect() para detectar desconexiones automáticamente
  Future<void> _setupPresence() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Verificar si el usuario existe en Firestore
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return;

      final userData = userDoc.data();
      final showOnlineStatus = userData?['showOnlineStatus'] ?? true;

      if (!showOnlineStatus) {
        // Si el usuario no quiere mostrar estado online, no configurar presence
        return;
      }

      // Referencia al nodo de status del usuario en RTDB
      final statusRef = _rtdb.ref('status/${user.uid}');

      // Escuchar cambios en la conexión
      final connectedRef = _rtdb.ref('.info/connected');

      _connectedSubscription?.cancel();
      _connectedSubscription = connectedRef.onValue.listen((event) async {
        final isConnected = event.snapshot.value as bool? ?? false;

        if (!isConnected) {
          // No estamos conectados a RTDB, no hacer nada
          return;
        }

        // Cuando nos conectamos, configurar onDisconnect PRIMERO
        // Esto garantiza que si la app se cierra, RTDB ejecutará esto automáticamente
        await statusRef.onDisconnect().set({
          'isOnline': false,
          'lastSeen': ServerValue.timestamp,
        });

        // Ahora marcar como online
        await statusRef.set({
          'isOnline': true,
          'lastSeen': ServerValue.timestamp,
        });
      });
    } catch (e) {
      // Silenciar errores para no spamear logs
    }
  }

  /// Callback cuando cambia el estado de la app
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // App volvió a primer plano - reconectar presence
        _setupPresence();
        break;

      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App va a background - RTDB onDisconnect() se encargará
        // No necesitamos hacer nada, el onDisconnect ya está configurado
        break;
    }
  }

  /// Establecer usuario como online manualmente
  Future<void> setOnline() async {
    await _setupPresence();
  }

  /// Establecer usuario como offline manualmente
  Future<void> setOffline() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final statusRef = _rtdb.ref('status/${user.uid}');
      await statusRef.set({
        'isOnline': false,
        'lastSeen': ServerValue.timestamp,
      });
    } catch (e) {
      // Silenciar errores
    }
  }

  /// Limpiar y disponer recursos
  void dispose() {
    if (!_isInitialized) return;

    _connectedSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    setOffline();
    _isInitialized = false;
  }
}
