import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Logger que funciona tanto en debug como en release builds
/// En release, envía logs a Firebase Crashlytics para debugging remoto
class ReleaseLogger {
  static void log(String message, {String? tag}) {
    final fullMessage = tag != null ? '[$tag] $message' : message;

    // En debug, usar print normal
    if (kDebugMode) {
      print(fullMessage);
    }

    // En release, enviar a Crashlytics como evento no fatal
    // Esto nos permite ver logs en la consola de Firebase
    try {
      FirebaseCrashlytics.instance.log(fullMessage);
    } catch (e) {
      // Si Crashlytics no está disponible, ignorar silenciosamente
    }
  }

  static void error(String message, {dynamic error, StackTrace? stackTrace, String? tag}) {
    final fullMessage = tag != null ? '[$tag] $message' : message;

    if (kDebugMode) {
      print('❌ $fullMessage');
      if (error != null) print('Error: $error');
    }

    try {
      FirebaseCrashlytics.instance.log(fullMessage);
      if (error != null) {
        FirebaseCrashlytics.instance.recordError(
          error,
          stackTrace,
          reason: fullMessage,
          fatal: false,
        );
      }
    } catch (e) {
      // Ignorar
    }
  }

  static void info(String message, {String? tag}) {
    log('ℹ️ $message', tag: tag);
  }

  static void success(String message, {String? tag}) {
    log('✅ $message', tag: tag);
  }

  static void warning(String message, {String? tag}) {
    log('⚠️ $message', tag: tag);
  }
}
