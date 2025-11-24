import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/release_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio para gestionar el estado de la aplicación (foreground/background)
///
/// Este servicio es crítico para manejar correctamente las notificaciones de videollamadas:
/// - Foreground: Usar IncomingCallScreen en lugar de notificaciones VoIP
/// - Background: Permitir VoIP/CallKit normal para que el usuario pueda contestar desde el lock screen
class AppStateService {
  static final AppStateService _instance = AppStateService._internal();
  factory AppStateService() => _instance;
  AppStateService._internal();

  // Estado actual de la app
  AppLifecycleState _currentState = AppLifecycleState.resumed;
  bool get isInForeground => _currentState == AppLifecycleState.resumed;
  bool get isInBackground => _currentState != AppLifecycleState.resumed;

  // Stream controller para notificar cambios de estado
  final StreamController<bool> _foregroundStateController = StreamController<bool>.broadcast();
  Stream<bool> get foregroundStateStream => _foregroundStateController.stream;

  // WidgetsBindingObserver reference para cleanup
  _AppLifecycleObserver? _observer;

  /// Inicializar el servicio de estado de la app
  void initialize() async {
    if (_observer != null) {
      ReleaseLogger.log('🔄 AppStateService ya estaba inicializado', tag: 'AppStateService');
      return;
    }

    _observer = _AppLifecycleObserver._(_onAppLifecycleChanged);
    WidgetsBinding.instance.addObserver(_observer!);

    // ✅ CRITICAL: Guardar estado inicial en SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_in_foreground', isInForeground);
      ReleaseLogger.log(
        '💾 Estado inicial guardado: app_in_foreground = $isInForeground',
        tag: 'AppStateService'
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error guardando estado inicial: $e',
        tag: 'AppStateService'
      );
    }

    ReleaseLogger.log('✅ AppStateService inicializado', tag: 'AppStateService');
    ReleaseLogger.log('📱 Estado inicial: ${_currentState.name} (foreground: $isInForeground)', tag: 'AppStateService');
  }

  /// Limpiar recursos
  void dispose() {
    if (_observer != null) {
      WidgetsBinding.instance.removeObserver(_observer!);
      _observer = null;
    }
    _foregroundStateController.close();
    ReleaseLogger.log('🧹 AppStateService disposed', tag: 'AppStateService');
  }

  /// Callback cuando cambia el estado del ciclo de vida de la app
  void _onAppLifecycleChanged(AppLifecycleState state) async {
    final previousState = _currentState;
    _currentState = state;

    ReleaseLogger.log(
      '📱 Estado de app cambió: ${previousState.name} → ${state.name}',
      tag: 'AppStateService'
    );

    // Notificar el cambio de estado
    if (previousState != state) {
      _foregroundStateController.add(isInForeground);

      // ✅ CRITICAL: Guardar estado en SharedPreferences para el background handler
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('app_in_foreground', isInForeground);
        ReleaseLogger.log(
          '💾 Estado guardado en SharedPreferences: app_in_foreground = $isInForeground',
          tag: 'AppStateService'
        );
      } catch (e) {
        ReleaseLogger.error(
          'Error guardando estado en SharedPreferences: $e',
          tag: 'AppStateService'
        );
      }

      if (isInForeground) {
        ReleaseLogger.log('✅ App pasó a FOREGROUND', tag: 'AppStateService');
      } else {
        ReleaseLogger.log('⬇️ App pasó a BACKGROUND/PAUSED', tag: 'AppStateService');
      }
    }
  }

  /// Obtener el estado actual de manera síncrona
  bool isAppInForeground() {
    return isInForeground;
  }

  /// Obtener el estado actual de manera síncrona (opuesto)
  bool isAppInBackground() {
    return isInBackground;
  }

  /// Debug: Forzar cambio de estado (solo para testing)
  @visibleForTesting
  void debugSetState(AppLifecycleState state) {
    _onAppLifecycleChanged(state);
  }
}

/// Observador privado para el ciclo de vida de la app
class _AppLifecycleObserver with WidgetsBindingObserver {
  final Function(AppLifecycleState) onStateChanged;

  _AppLifecycleObserver._(this.onStateChanged);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onStateChanged(state);
  }
}