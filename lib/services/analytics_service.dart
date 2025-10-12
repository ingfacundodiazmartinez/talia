import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Servicio centralizado para Firebase Analytics
///
/// Maneja el tracking de eventos, conversiones y propiedades de usuario
class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  late final FirebaseAnalytics _analytics;
  late final FirebaseAnalyticsObserver _observer;

  bool _initialized = false;

  /// Inicializa Firebase Analytics
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _analytics = FirebaseAnalytics.instance;
      _observer = FirebaseAnalyticsObserver(analytics: _analytics);

      // Configurar propiedades por defecto
      await _analytics.setAnalyticsCollectionEnabled(!kDebugMode);

      _initialized = true;

      if (kDebugMode) {
        print('📊 [Analytics] Inicializado (deshabilitado en debug)');
      } else {
        print('📊 [Analytics] Inicializado y habilitado');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Analytics] Error inicializando: $e');
      }
    }
  }

  /// Observer para navegación automática
  FirebaseAnalyticsObserver get observer => _observer;

  /// Configura el ID y propiedades del usuario
  Future<void> setUserProperties(String userId, Map<String, String> properties) async {
    if (!_initialized) return;

    try {
      await _analytics.setUserId(id: userId);

      for (final entry in properties.entries) {
        await _analytics.setUserProperty(
          name: entry.key,
          value: entry.value,
        );
      }

      if (kDebugMode) {
        print('👤 [Analytics] Usuario configurado: $userId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Analytics] Error configurando usuario: $e');
      }
    }
  }

  /// Limpia los datos del usuario (al hacer logout)
  Future<void> clearUserData() async {
    if (!_initialized) return;

    try {
      await _analytics.setUserId(id: null);
      if (kDebugMode) {
        print('🗑️ [Analytics] Datos de usuario limpiados');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Analytics] Error limpiando datos: $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE AUTENTICACIÓN
  // ═══════════════════════════════════════════════════════════════

  Future<void> logSignUp(String method) async {
    await _logEvent('sign_up', {'method': method});
  }

  Future<void> logLogin(String method) async {
    await _logEvent('login', {'method': method});
  }

  Future<void> logLogout() async {
    await _logEvent('logout');
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE MENSAJERÍA
  // ═══════════════════════════════════════════════════════════════

  Future<void> logMessageSent(String messageType) async {
    await _logEvent('message_sent', {
      'message_type': messageType, // text, image, video, audio
    });
  }

  Future<void> logMessageReceived(String messageType) async {
    await _logEvent('message_received', {
      'message_type': messageType,
    });
  }

  Future<void> logMessageModerated(String severity, String reason) async {
    await _logEvent('message_moderated', {
      'severity': severity, // low, medium, high
      'reason': reason,
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE CONTACTOS
  // ═══════════════════════════════════════════════════════════════

  Future<void> logContactAdded(String method) async {
    await _logEvent('contact_added', {
      'method': method, // qr_code, phone, username
    });
  }

  Future<void> logContactBlocked() async {
    await _logEvent('contact_blocked');
  }

  Future<void> logContactUnblocked() async {
    await _logEvent('contact_unblocked');
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE VIDEOLLAMADAS
  // ═══════════════════════════════════════════════════════════════

  Future<void> logCallStarted(String callType, bool isEmergency) async {
    await _logEvent('call_started', {
      'call_type': callType, // audio, video
      'is_emergency': isEmergency.toString(),
    });
  }

  Future<void> logCallEnded(String callType, int durationSeconds) async {
    await _logEvent('call_ended', {
      'call_type': callType,
      'duration': durationSeconds.toString(),
    });
  }

  Future<void> logCallMissed(String callType) async {
    await _logEvent('call_missed', {
      'call_type': callType,
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE EMERGENCIA
  // ═══════════════════════════════════════════════════════════════

  Future<void> logEmergencyActivated(bool hasLocation) async {
    await _logEvent('emergency_activated', {
      'has_location': hasLocation.toString(),
    });
  }

  Future<void> logEmergencyResolved(int durationMinutes) async {
    await _logEvent('emergency_resolved', {
      'duration_minutes': durationMinutes.toString(),
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE GRUPOS
  // ═══════════════════════════════════════════════════════════════

  Future<void> logGroupCreated(int memberCount) async {
    await _logEvent('group_created', {
      'member_count': memberCount.toString(),
    });
  }

  Future<void> logGroupJoined() async {
    await _logEvent('group_joined');
  }

  Future<void> logGroupLeft() async {
    await _logEvent('group_left');
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE CONFIGURACIÓN
  // ═══════════════════════════════════════════════════════════════

  Future<void> logModerationEnabled(String level) async {
    await _logEvent('moderation_enabled', {
      'level': level, // high, low
    });
  }

  Future<void> logModerationDisabled() async {
    await _logEvent('moderation_disabled');
  }

  Future<void> log2FAEnabled() async {
    await _logEvent('two_factor_enabled');
  }

  Future<void> log2FADisabled() async {
    await _logEvent('two_factor_disabled');
  }

  // ═══════════════════════════════════════════════════════════════
  // EVENTOS DE APP
  // ═══════════════════════════════════════════════════════════════

  Future<void> logAppOpened() async {
    await _logEvent('app_opened');
  }

  Future<void> logScreenView(String screenName) async {
    await _analytics.logScreenView(
      screenName: screenName,
    );
  }

  Future<void> logFeatureUsed(String featureName) async {
    await _logEvent('feature_used', {
      'feature_name': featureName,
    });
  }

  Future<void> logErrorOccurred(String errorType, String errorMessage) async {
    await _logEvent('error_occurred', {
      'error_type': errorType,
      'error_message': errorMessage.length > 100
          ? errorMessage.substring(0, 100)
          : errorMessage,
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODO GENÉRICO PARA EVENTOS PERSONALIZADOS
  // ═══════════════════════════════════════════════════════════════

  Future<void> logCustomEvent(String eventName, Map<String, dynamic>? parameters) async {
    await _logEvent(eventName, parameters);
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODO PRIVADO PARA LOGGING
  // ═══════════════════════════════════════════════════════════════

  Future<void> _logEvent(String name, [Map<String, dynamic>? parameters]) async {
    if (!_initialized) {
      if (kDebugMode) {
        print('⚠️ [Analytics] No inicializado, omitiendo evento: $name');
      }
      return;
    }

    try {
      // Convertir todos los valores a String para Analytics
      final Map<String, Object>? analyticsParams = parameters?.map(
        (key, value) => MapEntry(key, value.toString()),
      );

      await _analytics.logEvent(
        name: name,
        parameters: analyticsParams,
      );

      if (kDebugMode) {
        print('📊 [Analytics] Evento: $name ${parameters != null ? parameters.toString() : ""}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Analytics] Error logging evento $name: $e');
      }
    }
  }
}
