import 'package:shared_preferences/shared_preferences.dart';
import '../utils/release_logger.dart';

/// ✅ Servicio centralizado para anti-duplicación de notificaciones
///
/// Arquitectura HÍBRIDA (memoria + SharedPreferences para iOS killed state):
/// - Set<String> en memoria = 0ms lookup para casos normales
/// - SharedPreferences = persistencia para el caso específico de iOS killed state
///
/// Caso especial iOS killed state:
/// - iOS muestra push notification automáticamente
/// - User toca notificación → app se inicia desde killed
/// - main.dart guarda messageId en SharedPreferences ANTES de runApp()
/// - Este servicio lee SharedPreferences y bloquea el duplicado
class NotificationDeduplicationService {
  static final NotificationDeduplicationService _instance =
      NotificationDeduplicationService._internal();

  factory NotificationDeduplicationService() => _instance;

  NotificationDeduplicationService._internal();

  // In-memory cache - instant lookups, zero cost
  final Map<String, DateTime> _shownNotifications = {};

  // ✅ NEW: Persistent cache for tapped notifications (from killed state)
  // Loaded from SharedPreferences on initialize()
  String? _persistentTappedMessageId;
  int? _persistentTappedTimestamp;
  bool _initialized = false;

  // Cleanup configuration
  static const Duration _cleanupAge = Duration(hours: 24);

  // Keys for SharedPreferences
  static const String _keyTappedMessageId = 'tapped_notification_message_id';
  static const String _keyTappedTimestamp = 'tapped_notification_timestamp';

  /// ✅ Initialize from SharedPreferences
  /// Must be called BEFORE runApp() in main.dart to prevent race conditions
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _persistentTappedMessageId = prefs.getString(_keyTappedMessageId);
      _persistentTappedTimestamp = prefs.getInt(_keyTappedTimestamp);
      _initialized = true;

      if (_persistentTappedMessageId != null) {
        ReleaseLogger.log(
          '✅ [NotificationDedup] Loaded persistent messageId from killed state: $_persistentTappedMessageId',
          tag: 'NotificationDedup',
        );
      } else {
        ReleaseLogger.log(
          '✅ [NotificationDedup] Initialized (no pending tapped message)',
          tag: 'NotificationDedup',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        'Error initializing NotificationDeduplicationService: $e',
        tag: 'NotificationDedup',
      );
      _initialized = true; // Mark as initialized to avoid repeated failures
    }
  }

  /// Check if a message was tapped from killed state (persistent cache)
  /// Valid for 30 seconds after tap to avoid stale data
  bool _isPersistentTappedMessage(String messageId) {
    if (_persistentTappedMessageId != messageId) return false;
    if (_persistentTappedTimestamp == null) return false;

    // Only valid for 30 seconds after tap
    final now = DateTime.now().millisecondsSinceEpoch;
    final age = now - _persistentTappedTimestamp!;
    final isValid = age < 30000; // 30 seconds

    if (isValid) {
      ReleaseLogger.log(
        '🔒 [NotificationDedup] Message $messageId was tapped from killed state (age: ${age}ms)',
        tag: 'NotificationDedup',
      );
    }

    return isValid;
  }

  /// Clear the persistent tapped message (call when user enters chat)
  Future<void> clearTappedMessage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyTappedMessageId);
      await prefs.remove(_keyTappedTimestamp);
      _persistentTappedMessageId = null;
      _persistentTappedTimestamp = null;
      ReleaseLogger.log(
        '🧹 [NotificationDedup] Cleared persistent tapped message',
        tag: 'NotificationDedup',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error clearing tapped message: $e',
        tag: 'NotificationDedup',
      );
    }
  }

  /// ✅ ATOMIC: Try to acquire the "right" to show this notification
  ///
  /// This is an atomic check-and-set operation in memory.
  /// Only ONE caller will get `true`, all others get `false`.
  ///
  /// Returns:
  /// - `true` if this is the FIRST caller (show notification)
  /// - `false` if already acquired by another caller (skip notification)
  bool tryAcquire(String messageId) {
    // ✅ FIX iOS DUPLICATE: Check persistent cache first (killed state -> notification tap)
    if (_isPersistentTappedMessage(messageId)) {
      ReleaseLogger.log(
        '🔒 [NotificationDedup] BLOCKED - Persistent tapped message (iOS killed state): $messageId',
        tag: 'NotificationDedup',
      );
      return false; // Already shown by iOS push notification
    }

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
