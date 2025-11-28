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

        if (isInForeground) {
          ReleaseLogger.log('✅ App pasó a FOREGROUND', tag: 'AppStateService');
          // ✅ Guardar timestamp de cuando la app volvió a foreground
          await prefs.setInt('app_resumed_foreground_at', DateTime.now().millisecondsSinceEpoch);
        } else {
          ReleaseLogger.log('⬇️ App pasó a BACKGROUND/PAUSED', tag: 'AppStateService');
          // ✅ Guardar timestamp de cuando la app entró en background
          // Esto se usa para deduplicar notificaciones en iOS (sin depender de NSE)
          await prefs.setInt('app_went_background_at', DateTime.now().millisecondsSinceEpoch);
        }

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
    }
  }

  /// Verificar si un mensaje llegó mientras la app estaba en background (iOS dedup sin NSE)
  /// Retorna true si el mensaje probablemente ya fue mostrado por iOS como push notification
  Future<bool> wasMessageReceivedInBackground(DateTime messageCreatedAt) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backgroundAt = prefs.getInt('app_went_background_at');
      final resumedAt = prefs.getInt('app_resumed_foreground_at');

      if (backgroundAt == null) return false;

      final backgroundTime = DateTime.fromMillisecondsSinceEpoch(backgroundAt);
      final messageTime = messageCreatedAt;

      // El mensaje llegó después de que la app entró en background
      final arrivedInBackground = messageTime.isAfter(backgroundTime);

      // La app acaba de volver del background (menos de 10 segundos)
      final justResumed = resumedAt != null &&
          (DateTime.now().millisecondsSinceEpoch - resumedAt) < 10000;

      if (arrivedInBackground && justResumed) {
        ReleaseLogger.log(
          '📱 [AppState] Mensaje llegó en background (${messageTime.toIso8601String()}) - iOS ya lo mostró',
          tag: 'AppStateService'
        );
        return true;
      }

      return false;
    } catch (e) {
      ReleaseLogger.error('Error en wasMessageReceivedInBackground: $e', tag: 'AppStateService');
      return false;
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