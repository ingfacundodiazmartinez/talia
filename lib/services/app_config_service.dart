import 'package:firebase_remote_config/firebase_remote_config.dart';

/// Servicio para manejar configuraciones de la app desde Firebase Remote Config
///
/// Proporciona acceso seguro a configuraciones sensibles como API keys
/// sin necesidad de hardcodearlas en el código.
class AppConfigService {
  static final AppConfigService _instance = AppConfigService._internal();
  factory AppConfigService() => _instance;
  AppConfigService._internal();

  late FirebaseRemoteConfig _remoteConfig;
  bool _initialized = false;

  /// Inicializa Remote Config con valores por defecto
  Future<void> initialize() async {
    if (_initialized) {
      print('⚠️ AppConfigService ya fue inicializado');
      return;
    }

    try {
      print('🔧 Inicializando Firebase Remote Config...');

      _remoteConfig = FirebaseRemoteConfig.instance;

      await _remoteConfig.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 30),
        minimumFetchInterval: const Duration(hours: 1),
      ));

      // Valores por defecto en caso de que falle la carga desde Firebase
      // IMPORTANTE: El APP_ID real debe configurarse en Firebase Console
      await _remoteConfig.setDefaults({
        'agora_app_id': 'f4537746b6fc4e65aca1bd969c42c988', // Valor por defecto temporal
      });

      // Intenta obtener valores desde Firebase
      try {
        await _remoteConfig.fetchAndActivate();
        print('✅ Remote Config cargado desde Firebase');
      } catch (e) {
        print('⚠️ No se pudo cargar desde Firebase, usando valores por defecto: $e');
      }

      _initialized = true;
      print('✅ AppConfigService inicializado');
    } catch (e) {
      print('❌ Error inicializando AppConfigService: $e');
      // En caso de error, marcamos como inicializado para no bloquer la app
      _initialized = true;
      rethrow;
    }
  }

  /// Obtiene el Agora APP ID desde Remote Config
  ///
  /// Este valor debe configurarse en Firebase Console:
  /// Remote Config → Agregar parámetro → agora_app_id
  String get agoraAppId {
    if (!_initialized) {
      print('⚠️ AppConfigService no inicializado, usando valor por defecto');
      return 'f4537746b6fc4e65aca1bd969c42c988';
    }
    return _remoteConfig.getString('agora_app_id');
  }

  /// Verifica si Remote Config está inicializado
  bool get isInitialized => _initialized;

  /// Fuerza una actualización de los valores de Remote Config
  Future<void> refresh() async {
    try {
      await _remoteConfig.fetchAndActivate();
      print('✅ Remote Config actualizado');
    } catch (e) {
      print('❌ Error actualizando Remote Config: $e');
    }
  }
}
