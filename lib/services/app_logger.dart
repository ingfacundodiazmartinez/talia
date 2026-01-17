import 'package:logger/logger.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Servicio centralizado de logging estructurado
///
/// Reemplaza los `print()` con logging estructurado que:
/// - Se envía a Crashlytics en producción
/// - Tiene niveles (debug, info, warning, error)
/// - Incluye context automático
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal() {
    _logger = Logger(
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 5,
        lineLength: 80,
        colors: true,
        printEmojis: true,
        dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
      ),
      level: kDebugMode ? Level.debug : Level.info,
    );
  }

  late final Logger _logger;

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS DE LOGGING
  // ═══════════════════════════════════════════════════════════════

  void debug(String message, {String? tag, dynamic error, StackTrace? stackTrace}) {
    final formattedMessage = _formatMessage(message, tag);
    _logger.d(formattedMessage, error: error, stackTrace: stackTrace);
  }

  void info(String message, {String? tag}) {
    final formattedMessage = _formatMessage(message, tag);
    _logger.i(formattedMessage);
  }

  void warning(String message, {String? tag, dynamic error}) {
    final formattedMessage = _formatMessage(message, tag);
    _logger.w(formattedMessage, error: error);

    // En producción, enviar warnings a Crashlytics
    if (!kDebugMode && error != null) {
      FirebaseCrashlytics.instance.recordError(
        error,
        null,
        reason: formattedMessage,
        fatal: false,
      );
    }
  }

  void error(String message, {String? tag, dynamic error, StackTrace? stackTrace}) {
    final formattedMessage = _formatMessage(message, tag);
    _logger.e(formattedMessage, error: error, stackTrace: stackTrace);

    // Siempre enviar errors a Crashlytics (excepto en debug)
    if (!kDebugMode) {
      FirebaseCrashlytics.instance.recordError(
        error ?? formattedMessage,
        stackTrace,
        reason: formattedMessage,
        fatal: false,
      );
    }
  }

  void fatal(String message, {String? tag, required dynamic error, StackTrace? stackTrace}) {
    final formattedMessage = _formatMessage(message, tag);
    _logger.f(formattedMessage, error: error, stackTrace: stackTrace);

    // Siempre enviar fatales a Crashlytics (excepto en debug)
    if (!kDebugMode) {
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace ?? StackTrace.current,
        reason: formattedMessage,
        fatal: true,
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS DE CONTEXTO PARA CRASHLYTICS
  // ═══════════════════════════════════════════════════════════════

  void setUserContext(String userId, {String? email, String? name}) {
    if (!kDebugMode) {
      FirebaseCrashlytics.instance.setUserIdentifier(userId);
      if (email != null) {
        FirebaseCrashlytics.instance.setCustomKey('user_email', email);
      }
      if (name != null) {
        FirebaseCrashlytics.instance.setCustomKey('user_name', name);
      }
    }
  }

  void clearUserContext() {
    if (!kDebugMode) {
      FirebaseCrashlytics.instance.setUserIdentifier('');
    }
  }

  void setCustomKey(String key, dynamic value) {
    if (!kDebugMode) {
      if (value is String) {
        FirebaseCrashlytics.instance.setCustomKey(key, value);
      } else if (value is int) {
        FirebaseCrashlytics.instance.setCustomKey(key, value);
      } else if (value is double) {
        FirebaseCrashlytics.instance.setCustomKey(key, value);
      } else if (value is bool) {
        FirebaseCrashlytics.instance.setCustomKey(key, value);
      } else {
        FirebaseCrashlytics.instance.setCustomKey(key, value.toString());
      }
    }
  }

  void logBreadcrumb(String message) {
    if (!kDebugMode) {
      FirebaseCrashlytics.instance.log(message);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS PRIVADOS
  // ═══════════════════════════════════════════════════════════════

  String _formatMessage(String message, String? tag) {
    if (tag != null) {
      return '[$tag] $message';
    }
    return message;
  }
}

// ═══════════════════════════════════════════════════════════════
// EXTENSIÓN GLOBAL PARA FACILITAR USO
// ═══════════════════════════════════════════════════════════════

AppLogger get logger => AppLogger();
