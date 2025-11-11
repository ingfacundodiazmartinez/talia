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

  // Constante para valor por defecto (NUNCA cambiar en producción)
  static const String _defaultAgoraAppId = 'REPLACE_WITH_REAL_VALUE';

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
