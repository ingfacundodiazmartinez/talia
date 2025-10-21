import 'package:hive_flutter/hive_flutter.dart';
import 'package:talia/services/remote_logger_service.dart';
import '../models/child.dart';

/// Servicio para cachear datos del dashboard usando Hive
///
/// Responsabilidades:
/// - Guardar datos de hijos y métricas en cache persistente
/// - Recuperar datos del cache instantáneamente
/// - Gestionar timestamps de actualización
/// - Proveer datos mientras se actualizan desde Firestore
class DashboardCacheService {
  static final DashboardCacheService _instance = DashboardCacheService._internal();
  factory DashboardCacheService() => _instance;
  DashboardCacheService._internal();

  static const String _childrenBoxName = 'dashboard_children';
  static const String _metricsBoxName = 'dashboard_metrics';

  Box? _childrenBox;
  Box? _metricsBox;

  /// Inicializar Hive boxes
  /// Nota: Hive.initFlutter() ya se llama en MessageCacheService
  Future<void> initialize() async {
    try {
      _childrenBox = await Hive.openBox(_childrenBoxName);
      _metricsBox = await Hive.openBox(_metricsBoxName);
      appLogger.log('✅ [DashboardCacheService] Inicializado correctamente', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [DashboardCacheService] Error inicializando: $e', level: 'ERROR');
    }
  }

  // ============================================================================
  // CHILD DATA CACHING
  // ============================================================================

  /// Guardar datos de un hijo en el cache
  Future<void> saveChild(Child child) async {
    if (_childrenBox == null) return;

    try {
      final data = {
        'id': child.id,
        'name': child.name,
        'birthDate': child.birthDate?.toIso8601String(),
        'photoURL': child.photoURL,
        'isOnline': child.isOnline,
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      };

      await _childrenBox!.put(child.id, data);
      appLogger.log('✅ [DashboardCache] Guardado hijo: ${child.name}', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error guardando hijo: $e', level: 'ERROR');
    }
  }

  /// Guardar múltiples hijos
  Future<void> saveChildren(List<Child> children) async {
    if (_childrenBox == null) return;

    try {
      final entries = <String, Map<String, dynamic>>{};

      for (final child in children) {
        entries[child.id] = {
          'id': child.id,
          'name': child.name,
          'birthDate': child.birthDate?.toIso8601String(),
          'photoURL': child.photoURL,
          'isOnline': child.isOnline,
          'cachedAt': DateTime.now().millisecondsSinceEpoch,
        };
      }

      await _childrenBox!.putAll(entries);
      appLogger.log('✅ [DashboardCache] Guardados ${children.length} hijos', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error guardando hijos: $e', level: 'ERROR');
    }
  }

  /// Recuperar datos de un hijo del cache
  Future<Child?> getChild(String childId) async {
    if (_childrenBox == null) return null;

    try {
      final data = _childrenBox!.get(childId) as Map<dynamic, dynamic>?;
      if (data == null) return null;

      final child = Child(
        id: data['id'] as String,
        name: data['name'] as String,
        birthDate: data['birthDate'] != null
            ? DateTime.parse(data['birthDate'] as String)
            : null,
        photoURL: data['photoURL'] as String?,
        isOnline: data['isOnline'] as bool?,
      );

      final cachedAt = data['cachedAt'] as int?;
      if (cachedAt != null) {
        final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
        appLogger.log('📥 [DashboardCache] Recuperado hijo desde cache (${(age / 1000).round()}s ago): ${child.name}', level: 'INFO');
      }

      return child;
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error recuperando hijo: $e', level: 'ERROR');
      return null;
    }
  }

  /// Verificar si los datos de un hijo están en cache y son recientes
  bool hasRecentChild(String childId, {Duration maxAge = const Duration(minutes: 30)}) {
    if (_childrenBox == null) return false;

    try {
      final data = _childrenBox!.get(childId) as Map<dynamic, dynamic>?;
      if (data == null) return false;

      final cachedAt = data['cachedAt'] as int?;
      if (cachedAt == null) return false;

      final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
      return age < maxAge.inMilliseconds;
    } catch (e) {
      return false;
    }
  }

  // ============================================================================
  // METRICS CACHING
  // ============================================================================

  /// Guardar métricas de un hijo
  Future<void> saveMetrics(
    String childId, {
    required int contactsCount,
    required int messagesTodayCount,
    required int alertsCount,
  }) async {
    if (_metricsBox == null) return;

    try {
      final data = {
        'contactsCount': contactsCount,
        'messagesTodayCount': messagesTodayCount,
        'alertsCount': alertsCount,
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      };

      await _metricsBox!.put(childId, data);
      appLogger.log('✅ [DashboardCache] Guardadas métricas para hijo: $childId', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error guardando métricas: $e', level: 'ERROR');
    }
  }

  /// Recuperar métricas de un hijo del cache
  Future<Map<String, int>?> getMetrics(String childId) async {
    if (_metricsBox == null) return null;

    try {
      final data = _metricsBox!.get(childId) as Map<dynamic, dynamic>?;
      if (data == null) return null;

      final cachedAt = data['cachedAt'] as int?;
      if (cachedAt != null) {
        final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
        appLogger.log('📥 [DashboardCache] Recuperadas métricas desde cache (${(age / 1000).round()}s ago)', level: 'INFO');
      }

      return {
        'contactsCount': data['contactsCount'] as int? ?? 0,
        'messagesTodayCount': data['messagesTodayCount'] as int? ?? 0,
        'alertsCount': data['alertsCount'] as int? ?? 0,
      };
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error recuperando métricas: $e', level: 'ERROR');
      return null;
    }
  }

  /// Verificar si las métricas están en cache y son recientes
  bool hasRecentMetrics(String childId, {Duration maxAge = const Duration(minutes: 5)}) {
    if (_metricsBox == null) return false;

    try {
      final data = _metricsBox!.get(childId) as Map<dynamic, dynamic>?;
      if (data == null) return false;

      final cachedAt = data['cachedAt'] as int?;
      if (cachedAt == null) return false;

      final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
      return age < maxAge.inMilliseconds;
    } catch (e) {
      return false;
    }
  }

  // ============================================================================
  // CACHE MANAGEMENT
  // ============================================================================

  /// Limpiar cache de un hijo específico
  Future<void> clearChild(String childId) async {
    try {
      await _childrenBox?.delete(childId);
      await _metricsBox?.delete(childId);
      appLogger.log('🗑️ [DashboardCache] Cache limpiado para hijo: $childId', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error limpiando cache: $e', level: 'ERROR');
    }
  }

  /// Limpiar todo el cache del dashboard
  Future<void> clearAll() async {
    try {
      await _childrenBox?.clear();
      await _metricsBox?.clear();
      appLogger.log('🗑️ [DashboardCache] Todo el cache limpiado', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [DashboardCache] Error limpiando cache: $e', level: 'ERROR');
    }
  }

  /// Cerrar las boxes al terminar
  Future<void> dispose() async {
    await _childrenBox?.close();
    await _metricsBox?.close();
  }

  /// Obtener estadísticas del cache
  Map<String, dynamic> getCacheStats() {
    return {
      'childrenCount': _childrenBox?.length ?? 0,
      'metricsCount': _metricsBox?.length ?? 0,
      'isInitialized': _childrenBox != null && _metricsBox != null,
    };
  }
}
