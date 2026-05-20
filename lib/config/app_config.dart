/// Configuration for different app environments.
///
/// This class manages environment-specific settings and provides
/// a centralized way to check which environment the app is running in.
enum Environment {
  /// Local development with emulators
  development,

  /// Staging environment for QA and beta testing
  staging,

  /// Production environment for real users
  production,
}

/// Singleton configuration class for app environment management.
class AppConfig {
  AppConfig._();
  static final AppConfig _instance = AppConfig._();
  factory AppConfig() => _instance;

  static Environment _environment = Environment.production;

  /// Current environment
  static Environment get environment => _environment;

  /// Set the environment (should be called once at app startup)
  static void setEnvironment(Environment env) {
    _environment = env;
  }

  /// Check if running in production
  static bool get isProduction => _environment == Environment.production;

  /// Check if running in staging
  static bool get isStaging => _environment == Environment.staging;

  /// Check if running in development
  static bool get isDevelopment => _environment == Environment.development;

  /// Get environment name as string
  static String get environmentName {
    switch (_environment) {
      case Environment.production:
        return 'production';
      case Environment.staging:
        return 'staging';
      case Environment.development:
        return 'development';
    }
  }

  /// Badge text for visual identification (empty in production)
  static String get environmentBadge {
    switch (_environment) {
      case Environment.production:
        return '';
      case Environment.staging:
        return ' [STAGING]';
      case Environment.development:
        return ' [DEV]';
    }
  }

  /// Firebase project ID for current environment
  static String get firebaseProjectId {
    switch (_environment) {
      case Environment.production:
        return 'talia-chat-app-v2';
      case Environment.staging:
        return 'talia-staging';
      case Environment.development:
        return 'talia-staging'; // Dev uses staging Firebase or emulators
    }
  }
}
