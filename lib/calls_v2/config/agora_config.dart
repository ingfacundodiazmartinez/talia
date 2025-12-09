/// Agora RTC Engine Configuration
///
/// This class contains all the configuration needed for Agora RTC Engine.
/// The App ID is provided via --dart-define at build time for security.
///
/// Build commands:
/// flutter run --dart-define=AGORA_APP_ID=your_app_id
/// flutter build apk --dart-define=AGORA_APP_ID=your_app_id
/// flutter build ipa --dart-define=AGORA_APP_ID=your_app_id
class AgoraConfig {
  // App ID - Provided via dart-define at build time
  // IMPORTANT: Never hardcode the real App ID here
  static const String appId = String.fromEnvironment(
    'AGORA_APP_ID',
    defaultValue: '',
  );

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