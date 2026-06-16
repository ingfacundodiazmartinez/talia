import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Logger que funciona tanto en debug como en release builds
/// En release, usa dart:developer.log para mostrar en consola de Xcode/Android Studio
/// También envía logs a Firebase Crashlytics para debugging remoto
/// Y escribe en archivo separado por emulador
class ReleaseLogger {
  // ✅ Singleton para mantener estado
  static ReleaseLogger? _instance;
  static ReleaseLogger get instance {
    _instance ??= ReleaseLogger._();
    return _instance!;
  }

  // ✅ Archivo de logs de ESTE emulador (no compartido)
  File? _logFile;

  // ✅ Constructor privado
  ReleaseLogger._() {
    _initializeLogger();
  }

  /// Inicializar logger con deviceId y archivo propio
  Future<void> _initializeLogger() async {
    try {
      debugPrint('📝 [ReleaseLogger] Logs escribiendo a: ${_logFile!.path}');
    } catch (e) {
      debugPrint('❌ [ReleaseLogger] Error inicializando logger: $e');
    }
  }

  static void log(String message, {String? tag}) {
    var fullMessage = tag != null ? '[$tag] $message' : message;
    final time = DateTime.now().toIso8601String();

    // ✅ Formato para consola (mismo que antes)
    final consoleMessage = '$time = $fullMessage';

    // ✅ MÉTODO 2: stdout directo - más confiable en release
    stdout.writeln('🔷 $consoleMessage');
    debugPrint('🔷 $consoleMessage');
  }

  static void error(
    String message, {
    dynamic error,
    StackTrace? stackTrace,
    String? tag,
  }) {
    final fullMessage = tag != null ? '[$tag] $message' : message;
    final time = DateTime.now().toIso8601String();

    // ✅ Formato para consola
    final consoleMessage = '❌ $fullMessage';
    final consoleWithTime = '$time = $consoleMessage';

    // ✅ MÉTODO 2: stderr directo - más confiable en release para errores
    stderr.writeln('🔴 $consoleWithTime');
    if (error != null) {
      stderr.writeln('🔴    Error: $error');
    }
    // ✅ MÉTODO 3: debugPrint → llega al os_log/syslog del device (stderr solo
    // no aparece en idevicesyslog). Necesario para diagnosticar en release.
    debugPrint('🔴 $consoleWithTime');
    if (error != null) {
      debugPrint('🔴    Error: $error');
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
