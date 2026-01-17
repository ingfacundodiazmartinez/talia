import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

/// Servicio para Firebase Performance Monitoring
///
/// Monitorea tiempos de carga, latencias de red, y operaciones críticas
class PerformanceService {
  static final PerformanceService _instance = PerformanceService._internal();
  factory PerformanceService() => _instance;
  PerformanceService._internal();

  late final FirebasePerformance _performance;
  bool _initialized = false;

  // Caché de traces activos
  final Map<String, Trace> _activeTraces = {};

  /// Inicializa Firebase Performance
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _performance = FirebasePerformance.instance;

      // Configurar colección de datos
      await _performance.setPerformanceCollectionEnabled(!kDebugMode);

      _initialized = true;
    } catch (e) {
      // Silently handle error
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS DE TRACES (MEDICIÓN DE TIEMPOS)
  // ═══════════════════════════════════════════════════════════════

  /// Inicia un trace personalizado
  Future<void> startTrace(String traceName) async {
    if (!_initialized || kDebugMode) return;

    try {
      if (_activeTraces.containsKey(traceName)) {
        return;
      }

      final trace = _performance.newTrace(traceName);
      await trace.start();
      _activeTraces[traceName] = trace;
    } catch (e) {
      // Silently handle error
    }
  }

  /// Detiene un trace y lo envía a Firebase
  Future<void> stopTrace(String traceName) async {
    if (!_initialized || kDebugMode) return;

    try {
      final trace = _activeTraces[traceName];
      if (trace == null) {
        return;
      }

      await trace.stop();
      _activeTraces.remove(traceName);
    } catch (e) {
      // Silently handle error
    }
  }

  /// Agrega un atributo a un trace activo
  void setTraceAttribute(String traceName, String attribute, String value) {
    if (!_initialized || kDebugMode) return;

    try {
      final trace = _activeTraces[traceName];
      if (trace != null) {
        trace.putAttribute(attribute, value);
      }
    } catch (e) {
      // Silently handle error
    }
  }

  /// Incrementa una métrica en un trace activo
  void incrementTraceMetric(String traceName, String metricName, int value) {
    if (!_initialized || kDebugMode) return;

    try {
      final trace = _activeTraces[traceName];
      if (trace != null) {
        trace.incrementMetric(metricName, value);
      }
    } catch (e) {
      // Silently handle error
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // TRACES PRE-DEFINIDOS PARA OPERACIONES COMUNES
  // ═══════════════════════════════════════════════════════════════

  // Chat Loading
  Future<void> startChatLoadTrace(String chatId) async {
    await startTrace('chat_load');
    setTraceAttribute('chat_load', 'chat_id', chatId);
  }

  Future<void> stopChatLoadTrace() async {
    await stopTrace('chat_load');
  }

  // Message Send
  Future<void> startMessageSendTrace(String messageType) async {
    await startTrace('message_send');
    setTraceAttribute('message_send', 'type', messageType);
  }

  Future<void> stopMessageSendTrace() async {
    await stopTrace('message_send');
  }

  // Media Upload
  Future<void> startMediaUploadTrace(String mediaType) async {
    await startTrace('media_upload');
    setTraceAttribute('media_upload', 'type', mediaType);
  }

  Future<void> stopMediaUploadTrace({required int sizeBytes}) async {
    incrementTraceMetric('media_upload', 'size_bytes', sizeBytes);
    await stopTrace('media_upload');
  }

  // Call Connection
  Future<void> startCallConnectionTrace(String callType) async {
    await startTrace('call_connection');
    setTraceAttribute('call_connection', 'call_type', callType);
  }

  Future<void> stopCallConnectionTrace() async {
    await stopTrace('call_connection');
  }

  // Emergency Activation
  Future<void> startEmergencyTrace() async {
    await startTrace('emergency_activation');
  }

  Future<void> stopEmergencyTrace() async {
    await stopTrace('emergency_activation');
  }

  // Firestore Query
  Future<void> startFirestoreQueryTrace(String collectionName) async {
    await startTrace('firestore_query');
    setTraceAttribute('firestore_query', 'collection', collectionName);
  }

  Future<void> stopFirestoreQueryTrace({required int resultCount}) async {
    incrementTraceMetric('firestore_query', 'result_count', resultCount);
    await stopTrace('firestore_query');
  }

  // ═══════════════════════════════════════════════════════════════
  // HTTP REQUEST MONITORING (AUTOMÁTICO)
  // ═══════════════════════════════════════════════════════════════

  /// Crea un HttpMetric para monitorear requests HTTP
  HttpMetric? httpMetric(String url, HttpMethod method) {
    if (!_initialized || kDebugMode) return null;

    try {
      return _performance.newHttpMetric(url, method);
    } catch (e) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILIDADES
  // ═══════════════════════════════════════════════════════════════

  /// Mide el tiempo de ejecución de una función
  Future<T> measureAsync<T>(
    String traceName,
    Future<T> Function() function, {
    Map<String, String>? attributes,
  }) async {
    await startTrace(traceName);

    if (attributes != null) {
      for (final entry in attributes.entries) {
        setTraceAttribute(traceName, entry.key, entry.value);
      }
    }

    try {
      final result = await function();
      await stopTrace(traceName);
      return result;
    } catch (e) {
      setTraceAttribute(traceName, 'error', e.toString());
      await stopTrace(traceName);
      rethrow;
    }
  }

  /// Mide el tiempo de ejecución de una función síncrona
  T measure<T>(
    String traceName,
    T Function() function, {
    Map<String, String>? attributes,
  }) {
    if (!_initialized || kDebugMode) {
      return function();
    }

    try {
      return function();
    } catch (e) {
      rethrow;
    }
  }
}
