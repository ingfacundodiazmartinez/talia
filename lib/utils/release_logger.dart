import 'dart:async';
import 'dart:io';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:path_provider/path_provider.dart';

/// Logger que funciona tanto en debug como en release builds
/// En release, envía logs a Firebase Crashlytics para debugging remoto
/// También escribe en archivo separado por emulador
class ReleaseLogger {
  // ✅ Singleton para mantener estado
  static ReleaseLogger? _instance;
  static ReleaseLogger get instance {
    _instance ??= ReleaseLogger._();
    return _instance!;
  }

  // ✅ Device identifier único para este emulador
  String _deviceId = 'EMU-INIT';

  // ✅ Archivo de logs de ESTE emulador (no compartido)
  File? _logFile;

  // ✅ Constructor privado
  ReleaseLogger._() {
    _initializeLogger();
  }

  /// Inicializar logger con deviceId y archivo propio
  Future<void> _initializeLogger() async {
    try {
      // ✅ Generar device ID único
      _deviceId = _generateDeviceId();

      // ✅ Obtener directorio apropiado según plataforma
      Directory logDir;
      if (Platform.isAndroid || Platform.isIOS) {
        // Mobile: usar app documents directory
        logDir = await getApplicationDocumentsDirectory();
      } else {
        // Desktop: usar tmp/ en project root
        logDir = Directory('tmp');
        if (!await logDir.exists()) {
          await logDir.create(recursive: true);
        }
      }

      // ✅ Crear archivo ÚNICO para este emulador
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')[0];
      final logFileName = '$_deviceId-$timestamp.txt';
      _logFile = File('${logDir.path}/$logFileName');

      // ✅ Escribir header
      await _logFile!.writeAsString(
        '═══════════════════════════════════════════════════════════\n'
        '📱 LOGS - Device: $_deviceId\n'
        '📅 Timestamp: ${DateTime.now().toIso8601String()}\n'
        '═══════════════════════════════════════════════════════════\n\n',
        flush: true,
      );

      print('📝 [ReleaseLogger] Logs escribiendo a: ${_logFile!.path}');
    } catch (e) {
      print('❌ [ReleaseLogger] Error inicializando logger: $e');
    }
  }

  /// Generar device ID único basado en PID
  String _generateDeviceId() {
    try {
      // ✅ Usar PID del proceso para identificar el emulador
      final processId = pid;
      final shortId = processId.toString().padLeft(6, '0').substring(0, 6);
      return 'EMU-$shortId';
    } catch (e) {
      // Fallback a timestamp
      return 'EMU-${DateTime.now().millisecondsSinceEpoch % 1000000}';
    }
  }

  /// Escribir al archivo (sin locks, archivo propio)
  Future<void> _writeToFile(String line) async {
    if (_logFile == null) return;

    try {
      // ✅ Simple append - no hay concurrencia porque es archivo propio
      await _logFile!.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      // Ignorar errores silenciosamente
    }
  }

  static void log(String message, {String? tag}) {
    final inst = instance;
    var fullMessage = tag != null ? '[$tag] $message' : message;
    final time = DateTime.now().toIso8601String();

    // ✅ Formato para archivo: [timestamp] [tag] message
    final fileMessage = '$time $fullMessage';

    // ✅ Formato para consola (mismo que antes)
    final consoleMessage = '$time = $fullMessage';

    // En debug, usar print normal
    print(consoleMessage);

    // ✅ Escribir a archivo propio (async, no bloqueante)
    inst._writeToFile(fileMessage);

    // En release, enviar a Crashlytics como evento no fatal
    try {
      FirebaseCrashlytics.instance.log(consoleMessage);
    } catch (e) {
      // Si Crashlytics no está disponible, ignorar silenciosamente
    }
  }

  static void error(
    String message, {
    dynamic error,
    StackTrace? stackTrace,
    String? tag,
  }) {
    final inst = instance;
    final fullMessage = tag != null ? '[$tag] $message' : message;
    final time = DateTime.now().toIso8601String();

    // ✅ Formato para archivo
    var fileMessage = '$time ❌ $fullMessage';
    if (error != null) {
      fileMessage += '\n$time    Error: $error';
    }

    // ✅ Formato para consola
    final consoleMessage = '❌ $fullMessage';

    print(consoleMessage);
    if (error != null) print('Error: $error');

    // ✅ Escribir a archivo propio
    inst._writeToFile(fileMessage);

    try {
      FirebaseCrashlytics.instance.log(consoleMessage);
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
