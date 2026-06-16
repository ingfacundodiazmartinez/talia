import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'release_logger.dart';

/// Entrada individual del registro de inicialización.
class InitEntry {
  final String name;
  final Duration duration;
  final bool failed;
  final bool timedOut;
  final String? errorMessage;

  const InitEntry({
    required this.name,
    required this.duration,
    required this.failed,
    required this.timedOut,
    this.errorMessage,
  });

  bool get isSlow => duration.inMilliseconds > 2000;
  bool get isProblem => failed || timedOut || isSlow;
}

/// Registro centralizado de la performance/outcome de cada `.initialize()` del
/// arranque. Pensado para diagnosticar "cuál init es el que rompe / es lento"
/// cuando el primer send tras cold start tarda y tira error.
///
/// Uso desde main.dart:
///   await InitDiagnostics.track('MyService', () => MyService().initialize());
///
/// El registro expone `entries` como ValueListenable para que un banner en
/// MaterialApp.builder muestre los problemas detectados (slow / failed).
class InitDiagnostics {
  InitDiagnostics._();
  static final InitDiagnostics instance = InitDiagnostics._();

  final ValueNotifier<List<InitEntry>> entries = ValueNotifier(const []);
  bool _bannerDismissed = false;
  bool get bannerDismissed => _bannerDismissed;
  void dismissBanner() {
    _bannerDismissed = true;
    // Trigger un rebuild por si el banner está montado.
    entries.value = List<InitEntry>.from(entries.value);
  }

  /// Wrapper que ejecuta un init y reporta timing + resultado.
  /// Si el init falla, NO re-lanza la excepción (la mayoría de los callers
  /// originales swallowean con .catchError; mantenemos compat). Esto evita
  /// romper cadenas `Future.wait` con un solo init roto.
  static Future<void> track(String name, Future<void> Function() runInit, {
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final effectiveTimeout = timeout ?? const Duration(seconds: 15);
    bool failed = false;
    bool timedOut = false;
    String? errorMessage;
    try {
      await runInit().timeout(effectiveTimeout);
    } on TimeoutException catch (e, st) {
      timedOut = true;
      failed = true;
      errorMessage = 'Timeout (${effectiveTimeout.inSeconds}s)';
      ReleaseLogger.error('⏱️ Init "$name" timeoutó a los ${effectiveTimeout.inSeconds}s', tag: 'InitDiagnostics');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'Init timeout: $name',
        information: ['init=$name', 'timeout=${effectiveTimeout.inSeconds}s'],
        fatal: false,
      );
    } catch (e, st) {
      failed = true;
      errorMessage = e.toString();
      ReleaseLogger.error('❌ Init "$name" falló: $e', tag: 'InitDiagnostics');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'Init failed: $name',
        information: ['init=$name'],
        fatal: false,
      );
    } finally {
      stopwatch.stop();
      final entry = InitEntry(
        name: name,
        duration: stopwatch.elapsed,
        failed: failed,
        timedOut: timedOut,
        errorMessage: errorMessage,
      );
      instance._add(entry);

      if (entry.isSlow && !failed) {
        // ✅ Solo log local. Antes esto reportaba un non-fatal "Slow init" a
        // Crashlytics que generaba ruido de "warning" en producción. El init
        // lento no es un error: se queda como diagnóstico local únicamente.
        ReleaseLogger.warning(
          '🐢 Init "$name" tardó ${stopwatch.elapsed.inMilliseconds}ms (>3s)',
          tag: 'InitDiagnostics',
        );
      } else if (!failed) {
        ReleaseLogger.log(
          '✅ Init "$name" listo en ${stopwatch.elapsed.inMilliseconds}ms',
          tag: 'InitDiagnostics',
        );
      }
    }
  }

  void _add(InitEntry entry) {
    final updated = List<InitEntry>.from(entries.value)..add(entry);
    entries.value = updated;
  }

  /// Devuelve solo las entradas que vale la pena mostrar (failed/timeout/slow).
  List<InitEntry> get problems =>
      entries.value.where((e) => e.isProblem).toList();

  /// Registra un evento del send-path (no es init, pero queremos que el banner
  /// lo muestre igual). Por ejemplo: "first batch.commit retry needed",
  /// "_resolveSendContext timeout". Reportar también a Crashlytics.
  void recordEvent({
    required String name,
    required Duration duration,
    bool failed = false,
    String? errorMessage,
  }) {
    final entry = InitEntry(
      name: name,
      duration: duration,
      failed: failed,
      timedOut: false,
      errorMessage: errorMessage,
    );
    _add(entry);
    if (entry.isProblem) {
      FirebaseCrashlytics.instance.recordError(
        '$name (${duration.inMilliseconds}ms)${errorMessage != null ? ": $errorMessage" : ""}',
        StackTrace.current,
        reason: 'Diagnostic event: $name',
        information: ['durationMs=${duration.inMilliseconds}', if (errorMessage != null) 'error=$errorMessage'],
        fatal: false,
      );
    }
  }
}
