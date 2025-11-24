import 'package:shared_preferences/shared_preferences.dart';
import '../utils/release_logger.dart';

/// ✅ FIX #7: Servicio centralizado para anti-duplicación de notificaciones
///
/// Responsabilidades:
/// - Verificar si una notificación ya fue mostrada
/// - Marcar notificaciones como mostradas
/// - Cleanup automático de entradas antiguas
///
/// Arquitectura:
/// - In-memory cache para rapidez (0ms lookup)
/// - SharedPreferences para persistencia entre reinicios
/// - Auto-cleanup de entradas >24h
class NotificationDeduplicationService {
  static final NotificationDeduplicationService _instance = NotificationDeduplicationService._internal();

  factory NotificationDeduplicationService() => _instance;

  NotificationDeduplicationService._internal();

  // In-memory cache for instant lookups
  final Set<String> _shownNotifications = {};
  SharedPreferences? _prefs;
  bool _initialized = false;

  // Cleanup configuration
  static const Duration _cleanupAge = Duration(hours: 24);
  static const String _keyPrefix = 'instant_notification_';

  /// Initialize the service (call once at app startup)
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();

      // Load existing entries into memory cache
      final keys = _prefs!.getKeys().where((key) => key.startsWith(_keyPrefix));
      for (final key in keys) {
        final messageId = key.substring(_keyPrefix.length);
        _shownNotifications.add(messageId);
      }

      ReleaseLogger.log('✅ [NotificationDedup] Initialized with ${_shownNotifications.length} cached entries');

      // Run cleanup in background
      _cleanup();

      _initialized = true;
    } catch (e) {
      ReleaseLogger.error('❌ [NotificationDedup] Initialization error: $e');
    }
  }

  /// Check if a notification has already been shown
  ///
  /// Returns:
  /// - `true` if notification was already shown (skip it)
  /// - `false` if notification is new (show it)
  Future<bool> wasShown(String messageId) async {
    // Fast in-memory check (0ms)
    if (_shownNotifications.contains(messageId)) {
      return true;
    }

    // Fallback to SharedPreferences if not in memory (rare)
    // This handles edge case where app restarted and cache not fully loaded
    await _ensureInitialized();
    final key = '$_keyPrefix$messageId';
    final exists = _prefs?.containsKey(key) ?? false;

    if (exists) {
      // Add to memory cache for future fast lookups
      _shownNotifications.add(messageId);
    }

    return exists;
  }

  /// ✅ ATOMIC: Try to acquire the "right" to show this notification
  ///
  /// This is an atomic check-and-set operation that prevents race conditions.
  /// Only ONE caller will get `true`, all others get `false`.
  ///
  /// Returns:
  /// - `true` if this is the FIRST caller (show notification)
  /// - `false` if already acquired by another caller (skip notification)
  bool tryAcquire(String messageId) {
    // Atomic check-and-set in single operation
    if (_shownNotifications.contains(messageId)) {
      return false; // Already acquired
    }

    // Mark as shown IMMEDIATELY (before any async operations)
    _shownNotifications.add(messageId);

    // Persist in background (non-blocking)
    _persistInBackground(messageId);

    return true; // Successfully acquired
  }

  /// Mark a notification as shown
  ///
  /// This prevents duplicate notifications for the same message.
  /// Uses both in-memory cache (instant) and SharedPreferences (persistent).
  Future<void> markAsShown(String messageId) async {
    // Immediate in-memory marking (0ms)
    _shownNotifications.add(messageId);

    // Persist in background (non-blocking)
    _persistInBackground(messageId);
  }

  /// Persist to SharedPreferences in background (non-blocking)
  void _persistInBackground(String messageId) {
    _ensureInitialized().then((_) {
      final key = '$_keyPrefix$messageId';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _prefs?.setInt(key, timestamp);
    }).catchError((error) {
      ReleaseLogger.error('❌ [NotificationDedup] Persist error for $messageId: $error');
    });
  }

  /// Ensure service is initialized before use
  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  /// Remove old entries (>24h) to prevent unbounded growth
  Future<void> _cleanup() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final cutoff = now - _cleanupAge.inMilliseconds;

      final keys = _prefs!.getKeys().where((key) => key.startsWith(_keyPrefix));
      int removedCount = 0;

      for (final key in keys) {
        final timestamp = _prefs!.getInt(key);
        if (timestamp != null && timestamp < cutoff) {
          await _prefs!.remove(key);

          // Also remove from memory cache
          final messageId = key.substring(_keyPrefix.length);
          _shownNotifications.remove(messageId);

          removedCount++;
        }
      }

      if (removedCount > 0) {
        ReleaseLogger.log('🧹 [NotificationDedup] Cleaned up $removedCount old entries (>24h)');
      }
    } catch (e) {
      ReleaseLogger.error('❌ [NotificationDedup] Cleanup error: $e');
    }
  }

  /// Clear all deduplication data (useful for logout)
  Future<void> clear() async {
    try {
      await _ensureInitialized();

      // Remove all keys from SharedPreferences
      final keys = _prefs!.getKeys().where((key) => key.startsWith(_keyPrefix));
      for (final key in keys) {
        await _prefs!.remove(key);
      }

      // Clear memory cache
      _shownNotifications.clear();

      ReleaseLogger.log('🧹 [NotificationDedup] All data cleared');
    } catch (e) {
      ReleaseLogger.error('❌ [NotificationDedup] Clear error: $e');
    }
  }

  /// Get current cache size (for debugging)
  int get cacheSize => _shownNotifications.length;
}
