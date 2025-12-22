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
  static Future<void> initialize() async {
    if (_isInitialized) return;

    ReleaseLogger.log('🎥 [AgoraConfig] Initializing...', tag: 'AgoraConfig');
    ReleaseLogger.log('🎥 [AgoraConfig] Dart-define App ID: ${_dartDefineAppId.isNotEmpty ? "${_dartDefineAppId.substring(0, 8)}..." : "(empty)"}', tag: 'AgoraConfig');

    try {
      final remoteConfig = FirebaseRemoteConfig.instance;

      // Set defaults
      await remoteConfig.setDefaults({
        'agora_app_id': _dartDefineAppId,
      });

      // Fetch with short timeout for faster startup
      // ✅ FIX: Usar intervalo mínimo de 0 para debug, asegura fetch fresco
      await remoteConfig.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: Duration.zero, // Siempre fetch fresco
      ));

      // Try to fetch from server
      try {
        final activated = await remoteConfig.fetchAndActivate();
        ReleaseLogger.log('🎥 [AgoraConfig] Remote Config fetched, activated: $activated', tag: 'AgoraConfig');
      } catch (e) {
        ReleaseLogger.log(
          '🎥 [AgoraConfig] Remote fetch failed, using cached/default: $e',
          tag: 'AgoraConfig',
        );
      }

      // Get the App ID
      _cachedAppId = remoteConfig.getString('agora_app_id');

      // Debug: mostrar todas las keys disponibles
      final allKeys = remoteConfig.getAll();
      ReleaseLogger.log('🎥 [AgoraConfig] Remote Config keys: ${allKeys.keys.toList()}', tag: 'AgoraConfig');
      ReleaseLogger.log('🎥 [AgoraConfig] Remote Config agora_app_id: ${_cachedAppId?.isNotEmpty == true ? "${_cachedAppId!.substring(0, 8)}..." : "(empty)"}', tag: 'AgoraConfig');
      ReleaseLogger.log('🎥 [AgoraConfig] Last fetch status: ${remoteConfig.lastFetchStatus}', tag: 'AgoraConfig');

      if (_cachedAppId?.isEmpty ?? true) {
        _cachedAppId = _dartDefineAppId;
        ReleaseLogger.log('🎥 [AgoraConfig] Using dart-define fallback', tag: 'AgoraConfig');
      }

      _isInitialized = true;

      final isConfiguredNow = isConfigured();
      ReleaseLogger.log(
        '🎥 [AgoraConfig] ✅ Initialized - isConfigured: $isConfiguredNow, source: ${_cachedAppId == _dartDefineAppId ? "dart-define" : "Remote Config"}',
        tag: 'AgoraConfig',
      );

      if (!isConfiguredNow) {
        ReleaseLogger.error(
          '🎥 [AgoraConfig] ❌ WARNING: Agora App ID is EMPTY! Video calls will NOT work.',
          tag: 'AgoraConfig',
        );
        ReleaseLogger.error(
          '🎥 [AgoraConfig] Please configure "agora_app_id" in Firebase Remote Config or use --dart-define=AGORA_APP_ID=your_app_id',
          tag: 'AgoraConfig',
        );
      }
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