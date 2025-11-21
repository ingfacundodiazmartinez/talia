/// Call State Cache Service
///
/// Centralized cache for call processing state to prevent duplicate processing.
/// This service ensures that only one component processes a call at a time,
/// preventing race conditions from VoIP push, FCM notifications, and Firestore listeners.

import '../../utils/release_logger.dart';

/// Singleton service for managing call processing state
class CallStateCacheService {
  static final CallStateCacheService _instance = CallStateCacheService._internal();
  factory CallStateCacheService() => _instance;
  CallStateCacheService._internal();

  static const String _tag = 'CallStateCache';

  // Cache structure: callId -> ProcessingState
  final Map<String, CallProcessingState> _cache = {};

  /// Mark a call as being processed by a specific source
  /// Returns true if successfully marked (new), false if already being processed (duplicate)
  bool markAsProcessing(String callId, CallProcessingSource source) {
    final now = DateTime.now();

    // Check if already being processed
    final existing = _cache[callId];
    if (existing != null && !existing.isExpired()) {
      ReleaseLogger.log(
        '⚠️ Call $callId already being processed by ${existing.source.name}',
        tag: _tag,
      );
      return false; // Duplicate
    }

    // Mark as processing
    _cache[callId] = CallProcessingState(
      callId: callId,
      source: source,
      startedAt: now,
      expiresAt: now.add(const Duration(minutes: 2)),
    );

    ReleaseLogger.log(
      '✅ Call $callId marked as processing by ${source.name}',
      tag: _tag,
    );
    return true; // New
  }

  /// Check if a call is currently being processed
  bool isProcessing(String callId) {
    final state = _cache[callId];
    if (state == null) return false;

    if (state.isExpired()) {
      _cache.remove(callId);
      ReleaseLogger.log('🕒 Call $callId expired from cache', tag: _tag);
      return false;
    }

    return true;
  }

  /// Get the source that is currently processing the call
  CallProcessingSource? getProcessingSource(String callId) {
    final state = _cache[callId];
    if (state == null) return null;

    if (state.isExpired()) {
      _cache.remove(callId);
      return null;
    }

    return state.source;
  }

  /// Clear a call from the cache (call ended, accepted, or declined)
  void clearCall(String callId) {
    final removed = _cache.remove(callId);
    if (removed != null) {
      ReleaseLogger.log(
        '🧹 Call $callId cleared from cache (was ${removed.source.name})',
        tag: _tag,
      );
    }
  }

  /// Cleanup expired entries from the cache
  /// Should be called periodically
  void cleanupExpired() {
    final now = DateTime.now();
    final beforeCount = _cache.length;

    _cache.removeWhere((key, state) => state.isExpired());

    final removedCount = beforeCount - _cache.length;
    if (removedCount > 0) {
      ReleaseLogger.log(
        '🧹 Cleaned up $removedCount expired call state(s)',
        tag: _tag,
      );
    }
  }

  /// Get all active calls in the cache
  List<String> getActiveCalls() {
    cleanupExpired();
    return _cache.keys.toList();
  }

  /// Get cache statistics for debugging
  Map<String, dynamic> getStats() {
    cleanupExpired();

    final stats = <String, int>{};
    for (final state in _cache.values) {
      final sourceName = state.source.name;
      stats[sourceName] = (stats[sourceName] ?? 0) + 1;
    }

    return {
      'total': _cache.length,
      'bySource': stats,
      'calls': _cache.keys.toList(),
    };
  }

  /// Clear all cache entries (use with caution, mainly for testing)
  void clearAll() {
    final count = _cache.length;
    _cache.clear();
    ReleaseLogger.log('🧹 Cleared all $count call state(s) from cache', tag: _tag);
  }
}

/// Represents the processing state of a call
class CallProcessingState {
  final String callId;
  final CallProcessingSource source;
  final DateTime startedAt;
  final DateTime expiresAt;

  CallProcessingState({
    required this.callId,
    required this.source,
    required this.startedAt,
    required this.expiresAt,
  });

  /// Check if this state has expired
  bool isExpired() => DateTime.now().isAfter(expiresAt);

  /// Get age of this state in seconds
  int getAgeSeconds() => DateTime.now().difference(startedAt).inSeconds;

  @override
  String toString() {
    return 'CallProcessingState(callId: $callId, source: ${source.name}, '
        'age: ${getAgeSeconds()}s, expired: ${isExpired()})';
  }
}

/// Sources that can process calls
enum CallProcessingSource {
  /// iOS VoIP push notification
  voipPush,

  /// Android FCM notification
  fcmNotification,

  /// Firestore incoming calls listener
  firestoreListener,

  /// Manual accept by user (from UI)
  manualAccept,

  /// CallKit accept action
  callKitAccept,

  /// Other/unknown source
  other,
}
