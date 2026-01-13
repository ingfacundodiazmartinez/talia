import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:talia/utils/release_logger.dart';

/// Agora RTC Engine Configuration
///
/// This class contains all the configuration needed for Agora RTC Engine.
/// The App ID is loaded from Firebase Remote Config for security.
///
/// Setup in Firebase Console:
/// 1. Go to Remote Config
/// 2. Add parameter: agora_app_id = "your_app_id"
/// 3. Publish changes
///
/// Fallback: Can also use --dart-define=AGORA_APP_ID=your_app_id
class AgoraConfig {
  static String? _cachedAppId;
  static bool _isInitialized = false;

  // Fallback App ID from dart-define (for development/CI)
  static const String _dartDefineAppId = String.fromEnvironment(
    'AGORA_APP_ID',
    defaultValue: '',
  );

  /// Get App ID - prioritizes Remote Config, falls back to dart-define
  static String get appId {
    return _cachedAppId ?? _dartDefineAppId;
  }

  /// Initialize Agora config from Firebase Remote Config
  /// Call this during app startup (after Firebase.initializeApp)
  ///
  /// OPTIMIZACIÓN: Esta función usa valores cached/defaults inmediatamente
  /// y actualiza desde Remote Config en background para no bloquear el startup.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    ReleaseLogger.log('🎥 [AgoraConfig] Initializing...', tag: 'AgoraConfig');

    try {
      final remoteConfig = FirebaseRemoteConfig.instance;

      // Set defaults (sync, rápido)
      await remoteConfig.setDefaults({
        'agora_app_id': _dartDefineAppId,
      });

      // OPTIMIZACIÓN: Timeout reducido de 10s a 3s
      await remoteConfig.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 3),
        minimumFetchInterval: const Duration(minutes: 5),
      ));

      // Usar valor cached inmediatamente (de la sesión anterior)
      _cachedAppId = remoteConfig.getString('agora_app_id');
      if (_cachedAppId?.isEmpty ?? true) {
        _cachedAppId = _dartDefineAppId;
      }

      _isInitialized = true;
      ReleaseLogger.log(
        '🎥 [AgoraConfig] ✅ Initialized with cached/default value',
        tag: 'AgoraConfig',
      );

      // Fetch en background (no-bloqueante)
      _fetchRemoteConfigInBackground(remoteConfig);

    } catch (e) {
      ReleaseLogger.error('🎥 [AgoraConfig] Init failed: $e', tag: 'AgoraConfig');
      _cachedAppId = _dartDefineAppId;
      _isInitialized = true;

      if (!isConfigured()) {
        ReleaseLogger.error(
          '🎥 [AgoraConfig] ❌ CRITICAL: No Agora App ID available!',
          tag: 'AgoraConfig',
        );
      }
    }
  }

  /// Fetch Remote Config en background sin bloquear
  static void _fetchRemoteConfigInBackground(FirebaseRemoteConfig remoteConfig) {
    remoteConfig.fetchAndActivate().then((activated) {
      if (activated) {
        final newAppId = remoteConfig.getString('agora_app_id');
        if (newAppId.isNotEmpty && newAppId != _cachedAppId) {
          _cachedAppId = newAppId;
          ReleaseLogger.log(
            '🎥 [AgoraConfig] Updated from Remote Config in background',
            tag: 'AgoraConfig',
          );
        }
      }
    }).catchError((e) {
      ReleaseLogger.log(
        '🎥 [AgoraConfig] Background fetch failed (using cached): $e',
        tag: 'AgoraConfig',
      );
    });
  }

  // Token server endpoint - if using custom token server
  static const String tokenServerUrl = '';

  // Channel prefix for consistency
  static const String channelPrefix = 'call_';

  // Video configuration
  static const int videoWidth = 640;
  static const int videoHeight = 480;
  static const int videoFrameRate = 15;
  static const int videoBitrate = 0; // 0 = standard bitrate

  // Audio configuration
  static const bool enableAudioByDefault = true;
  static const bool enableVideoByDefault = true;

  // Log level for debugging (0 = none, 1 = info, 2 = warn, 3 = error, 4 = critical)
  static const int logLevel = 1;

  /// Generate a consistent channel name for calls
  static String generateChannelName(String callId) {
    return '$channelPrefix$callId';
  }

  /// Generate a unique UID for a user (1-4294967295)
  /// In production, this should be managed by your backend
  static int generateUid(String userId) {
    // Simple hash function to convert userId to a number
    // In production, maintain a mapping in your database
    int hash = 0;
    for (int i = 0; i < userId.length; i++) {
      hash = ((hash << 5) - hash) + userId.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF; // Convert to 32-bit integer
    }
    // Ensure it's positive and non-zero
    if (hash <= 0) hash = 1;
    return hash;
  }

  /// Check if App ID is configured via dart-define
  static bool isConfigured() {
    return appId.isNotEmpty;
  }
}