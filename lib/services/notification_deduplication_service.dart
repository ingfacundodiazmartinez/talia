import '../utils/release_logger.dart';

/// ✅ Servicio centralizado para anti-duplicación de notificaciones
///
/// Arquitectura SIMPLIFICADA (solo cache en memoria):
/// - Set<String> en memoria = 0ms lookup, 0 I/O, 0 costo
/// - NO persiste entre reinicios (no es necesario)
/// - Auto-cleanup cada 24h para liberar memoria
///
/// Razones para NO usar SharedPreferences/Firestore:
/// 1. SharedPreferences NO es atómico entre Dart/Kotlin/Swift
/// 2. Firestore writes cuestan dinero y tienen latencia
/// 3. Cache en memoria es suficiente (solo necesitamos evitar duplicados inmediatos)
/// 4. Si la app se reinicia, es un nuevo contexto sin riesgo de duplicados
class NotificationDeduplicationService {
  static final NotificationDeduplicationService _instance =
      NotificationDeduplicationService._internal();

  factory NotificationDeduplicationService() => _instance;

  NotificationDeduplicationService._internal();

  // In-memory cache ONLY - instant lookups, zero cost
  final Map<String, DateTime> _shownNotifications = {};

  // Cleanup configuration
  static const Duration _cleanupAge = Duration(hours: 24);

  /// ✅ ATOMIC: Try to acquire the "right" to show this notification
  ///
  /// This is an atomic check-and-set operation in memory.
  /// Only ONE caller will get `true`, all others get `false`.
  ///
  /// Returns:
  /// - `true` if this is the FIRST caller (show notification)
  /// - `false` if already acquired by another caller (skip notification)
  bool tryAcquire(String messageId) {
    // Atomic check-and-set in single operation
    if (_shownNotifications.containsKey(messageId)) {
      ReleaseLogger.log('🔒 [NotificationDedup] Already acquired: $messageId');
      return false; // Already acquired
    }

    // Mark as shown IMMEDIATELY with timestamp
    _shownNotifications[messageId] = DateTime.now();

    ReleaseLogger.log('✅ [NotificationDedup] Acquired lock for: $messageId');

    // Cleanup old entries if cache is getting large
    if (_shownNotifications.length > 1000) {
      _cleanupSync();
    }

    return true; // Successfully acquired
  }

  /// Synchronous cleanup to prevent unbounded memory growth
  void _cleanupSync() {
    final now = DateTime.now();
    final cutoff = now.subtract(_cleanupAge);

    _shownNotifications.removeWhere((messageId, timestamp) {
      return timestamp.isBefore(cutoff);
    });

    ReleaseLogger.log('🧹 [NotificationDedup] Cleaned up old entries. Current size: ${_shownNotifications.length}');
  }

  /// Clear all deduplication data (useful for logout)
  void clear() {
    _shownNotifications.clear();
    ReleaseLogger.log('🧹 [NotificationDedup] All data cleared');
  }

  /// Get current cache size (for debugging)
  int get cacheSize => _shownNotifications.length;
}
