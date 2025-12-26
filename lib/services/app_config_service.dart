import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../utils/release_logger.dart';

/// Servicio para manejar configuraciones de la app de manera segura
///
/// Jerarquía de configuración (en orden de prioridad):
/// 1. Variables de entorno (.env) - MÁXIMA SEGURIDAD
/// 2. Firebase Remote Config - Configuración remota
/// 3. Valores por defecto - Fallback de emergencia
///
/// Proporciona acceso seguro a configuraciones sensibles como API keys
/// sin necesidad de hardcodearlas en el código.
class AppConfigService {
  static final AppConfigService _instance = AppConfigService._internal();
  factory AppConfigService() => _instance;
  AppConfigService._internal();

  late FirebaseRemoteConfig _remoteConfig;
  bool _initialized = false;

  // Constantes para valores por defecto (NUNCA cambiar en producción)
  static const String _defaultAgoraAppId = 'REPLACE_WITH_REAL_VALUE';

  // AdMob Test IDs (fallback seguro)
  static const String _testAndroidNativeAdId = 'ca-app-pub-3940256099942544/2247696110';
  static const String _testIosNativeAdId = 'ca-app-pub-3940256099942544/3986624511';
  static const String _testAndroidRewardedAdId = 'ca-app-pub-3940256099942544/5224354917';
  static const String _testIosRewardedAdId = 'ca-app-pub-3940256099942544/1712485313';

  /// Inicializa Remote Config y variables de entorno
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    try {
      // 1. Cargar variables de entorno
      try {
        await dotenv.load(fileName: '.env');
        ReleaseLogger.log('Variables de entorno cargadas exitosamente', tag: 'AppConfig');
      } catch (e) {
        ReleaseLogger.log('No se encontró archivo .env, continuando sin variables locales', tag: 'AppConfig');
      }

      // 2. Inicializar Firebase Remote Config
      _remoteConfig = FirebaseRemoteConfig.instance;

      await _remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 30),
          minimumFetchInterval: const Duration(hours: 1),
        ),
      );

      // 3. Configurar valores por defecto (NUNCA usar valores reales aquí)
      await _remoteConfig.setDefaults({
        'agora_app_id': _defaultAgoraAppId,
        'admob_android_native_ad_id': _testAndroidNativeAdId,
        'admob_ios_native_ad_id': _testIosNativeAdId,
        'admob_android_rewarded_ad_id': _testAndroidRewardedAdId,
        'admob_ios_rewarded_ad_id': _testIosRewardedAdId,
      });

      // 4. Intentar obtener configuración remota
      try {
        await _remoteConfig.fetchAndActivate();
        ReleaseLogger.log('Remote Config actualizado exitosamente', tag: 'AppConfig');
      } catch (e) {
        ReleaseLogger.log('No se pudo cargar Remote Config, usando valores por defecto: $e', tag: 'AppConfig');
      }

      _initialized = true;
      ReleaseLogger.log('AppConfigService inicializado exitosamente', tag: 'AppConfig');
    } catch (e) {
      ReleaseLogger.error('Error inicializando AppConfigService: $e', tag: 'AppConfig');
      // En caso de error, marcamos como inicializado para no bloquear la app
      _initialized = true;
      rethrow;
    }
  }

  /// Obtiene el Agora APP ID de manera segura
  ///
  /// Jerarquía de fuentes (en orden de prioridad):
  /// 1. Variable de entorno AGORA_APP_ID (.env)
  /// 2. Firebase Remote Config 'agora_app_id'
  /// 3. Valor por defecto (fallback de emergencia)
  String get agoraAppId {
    try {
      // 1. Prioridad máxima: Variable de entorno
      final envAppId = dotenv.env['AGORA_APP_ID'];
      ReleaseLogger.log('🔍 Debug - Variable de entorno AGORA_APP_ID: "$envAppId"', tag: 'AppConfig');
      if (envAppId != null && envAppId.isNotEmpty && envAppId != _defaultAgoraAppId && envAppId != 'your_agora_app_id_here') {
        ReleaseLogger.log('✅ Usando Agora App ID desde variable de entorno: $envAppId', tag: 'AppConfig');
        return envAppId;
      }

      // 2. Si no hay .env, verificar si está inicializado
      if (!_initialized) {
        ReleaseLogger.log('AppConfigService no inicializado, usando valor por defecto', tag: 'AppConfig');
        return _defaultAgoraAppId;
      }

      // 3. Intentar obtener desde Remote Config
      final remoteAppId = _remoteConfig.getString('agora_app_id');
      if (remoteAppId.isNotEmpty && remoteAppId != _defaultAgoraAppId) {
        ReleaseLogger.log('Usando Agora App ID desde Remote Config', tag: 'AppConfig');
        return remoteAppId;
      }

      // 4. Fallback final
      ReleaseLogger.log('Usando Agora App ID por defecto (configurar .env o Remote Config)', tag: 'AppConfig');
      return _defaultAgoraAppId;

    } catch (e) {
      ReleaseLogger.error('Error obteniendo Agora App ID: $e', tag: 'AppConfig');
      return _defaultAgoraAppId;
    }
  }

  /// Verifica si Remote Config está inicializado
  bool get isInitialized => _initialized;

  /// Obtiene el AdMob Native Ad ID para Android
  ///
  /// Jerarquía de fuentes:
  /// 1. Variable de entorno ADMOB_ANDROID_NATIVE_AD_ID (.env)
  /// 2. Firebase Remote Config 'admob_android_native_ad_id'
  /// 3. Test ID (fallback seguro)
  String get admobAndroidNativeAdId {
    try {
      // 1. Variable de entorno
      final envAdId = dotenv.env['ADMOB_ANDROID_NATIVE_AD_ID'];
      if (envAdId != null && envAdId.isNotEmpty && envAdId != _testAndroidNativeAdId) {
        ReleaseLogger.log('Usando Android Native Ad ID desde variable de entorno', tag: 'AppConfig');
        return envAdId;
      }

      // 2. Remote Config
      if (_initialized) {
        final remoteAdId = _remoteConfig.getString('admob_android_native_ad_id');
        if (remoteAdId.isNotEmpty && remoteAdId != _testAndroidNativeAdId) {
          ReleaseLogger.log('Usando Android Native Ad ID desde Remote Config', tag: 'AppConfig');
          return remoteAdId;
        }
      }

      // 3. Fallback a test ID
      ReleaseLogger.log('Usando Android Native Ad ID de prueba', tag: 'AppConfig');
      return _testAndroidNativeAdId;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo Android Native Ad ID: $e', tag: 'AppConfig');
      return _testAndroidNativeAdId;
    }
  }

  /// Obtiene el AdMob Native Ad ID para iOS
  ///
  /// Jerarquía de fuentes:
  /// 1. Variable de entorno ADMOB_IOS_NATIVE_AD_ID (.env)
  /// 2. Firebase Remote Config 'admob_ios_native_ad_id'
  /// 3. Test ID (fallback seguro)
  String get admobIosNativeAdId {
    try {
      // 1. Variable de entorno
      final envAdId = dotenv.env['ADMOB_IOS_NATIVE_AD_ID'];
      if (envAdId != null && envAdId.isNotEmpty && envAdId != _testIosNativeAdId) {
        ReleaseLogger.log('Usando iOS Native Ad ID desde variable de entorno', tag: 'AppConfig');
        return envAdId;
      }

      // 2. Remote Config
      if (_initialized) {
        final remoteAdId = _remoteConfig.getString('admob_ios_native_ad_id');
        if (remoteAdId.isNotEmpty && remoteAdId != _testIosNativeAdId) {
          ReleaseLogger.log('Usando iOS Native Ad ID desde Remote Config', tag: 'AppConfig');
          return remoteAdId;
        }
      }

      // 3. Fallback a test ID
      ReleaseLogger.log('Usando iOS Native Ad ID de prueba', tag: 'AppConfig');
      return _testIosNativeAdId;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo iOS Native Ad ID: $e', tag: 'AppConfig');
      return _testIosNativeAdId;
    }
  }

  /// Obtiene el AdMob Rewarded Ad ID para Android (reportes)
  ///
  /// Jerarquía de fuentes:
  /// 1. Variable de entorno ADMOB_ANDROID_REWARDED_AD_ID (.env)
  /// 2. Firebase Remote Config 'admob_android_rewarded_ad_id'
  /// 3. Test ID (fallback seguro)
  String get admobAndroidRewardedAdId {
    try {
      // 1. Variable de entorno
      final envAdId = dotenv.env['ADMOB_ANDROID_REWARDED_AD_ID'];
      if (envAdId != null && envAdId.isNotEmpty && envAdId != _testAndroidRewardedAdId) {
        ReleaseLogger.log('Usando Android Rewarded Ad ID desde variable de entorno', tag: 'AppConfig');
        return envAdId;
      }

      // 2. Remote Config
      if (_initialized) {
        final remoteAdId = _remoteConfig.getString('admob_android_rewarded_ad_id');
        if (remoteAdId.isNotEmpty && remoteAdId != _testAndroidRewardedAdId) {
          ReleaseLogger.log('Usando Android Rewarded Ad ID desde Remote Config', tag: 'AppConfig');
          return remoteAdId;
        }
      }

      // 3. Fallback a test ID
      ReleaseLogger.log('Usando Android Rewarded Ad ID de prueba', tag: 'AppConfig');
      return _testAndroidRewardedAdId;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo Android Rewarded Ad ID: $e', tag: 'AppConfig');
      return _testAndroidRewardedAdId;
    }
  }

  /// Obtiene el AdMob Rewarded Ad ID para iOS (reportes)
  ///
  /// Jerarquía de fuentes:
  /// 1. Variable de entorno ADMOB_IOS_REWARDED_AD_ID (.env)
  /// 2. Firebase Remote Config 'admob_ios_rewarded_ad_id'
  /// 3. Test ID (fallback seguro)
  String get admobIosRewardedAdId {
    try {
      // 1. Variable de entorno
      final envAdId = dotenv.env['ADMOB_IOS_REWARDED_AD_ID'];
      ReleaseLogger.log('🔍 [iOS Rewarded] envAdId: "$envAdId", initialized: $_initialized', tag: 'AppConfig');
      if (envAdId != null && envAdId.isNotEmpty && envAdId != _testIosRewardedAdId) {
        ReleaseLogger.log('✅ Usando iOS Rewarded Ad ID desde variable de entorno: $envAdId', tag: 'AppConfig');
        return envAdId;
      }

      // 2. Remote Config
      if (_initialized) {
        final remoteAdId = _remoteConfig.getString('admob_ios_rewarded_ad_id');
        ReleaseLogger.log('🔍 [iOS Rewarded] remoteAdId: "$remoteAdId", testId: "$_testIosRewardedAdId"', tag: 'AppConfig');
        if (remoteAdId.isNotEmpty && remoteAdId != _testIosRewardedAdId) {
          ReleaseLogger.log('✅ Usando iOS Rewarded Ad ID desde Remote Config: $remoteAdId', tag: 'AppConfig');
          return remoteAdId;
        }
      }

      // 3. Fallback a test ID
      ReleaseLogger.log('⚠️ Usando iOS Rewarded Ad ID de PRUEBA (no se encontró en env ni Remote Config)', tag: 'AppConfig');
      return _testIosRewardedAdId;
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo iOS Rewarded Ad ID: $e', tag: 'AppConfig');
      return _testIosRewardedAdId;
    }
  }

  /// Fuerza una actualización de los valores de Remote Config
  Future<void> refresh() async {
    try {
      await _remoteConfig.fetchAndActivate();
      ReleaseLogger.log('Remote Config actualizado exitosamente', tag: 'AppConfig');
    } catch (e) {
      ReleaseLogger.error('Error actualizando Remote Config: $e', tag: 'AppConfig');
    }
  }
}
