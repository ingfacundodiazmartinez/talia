import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// Importa tus pantallas
import 'auth_screen.dart';
import 'screens/parent/parent_main_shell.dart';
import 'screens/child/child_main_shell.dart';
import 'screens/common/profile_completion_screen.dart';
import 'screens/auth/two_factor_verification_screen.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'notification_service.dart';
import 'theme_service.dart';
import 'services/two_factor_session_service.dart';
import 'services/app_config_service.dart';
import 'services/message_cache_service.dart';
import 'groups/services/group_message_cache_service.dart';
import 'services/dashboard_cache_service.dart';
import 'services/notification_cache_service.dart';
import 'services/device_session_service.dart';
import 'services/online_status_service.dart';
import 'services/timezone_service.dart';
import 'services/screenshot_protection_service.dart';
import 'services/voip_service.dart';
import 'services/call_service_wrapper.dart';
import 'services/local_unread_count_service.dart';
import 'services/app_state_service.dart';
import 'services/analytics_service.dart';
import 'services/performance_service.dart';
import 'services/snackbar_service.dart';
import 'services/network_status_service.dart';
import 'services/permission_sync_service.dart';
import 'services/offline_queue_service.dart';
import 'services/accessibility_service.dart';
import 'services/stickers_service.dart';
import 'services/character_service.dart';
import 'services/unread_messages_service.dart';
import 'services/ad_service.dart';
import 'services/story_service_refactored.dart';
import 'services/contact_photo_cache_service.dart';
import 'services/deep_link_service.dart';
import 'services/share_target_service.dart';
import 'services/shared_keychain_service.dart';
import 'screens/share_target_selection_screen.dart';
import 'models/shared_content.dart';
import 'services/chats/chat_orchestrator.dart';
import 'services/chats/services/chat_messaging_service.dart';
import 'services/chats/chat_preferences_cache.dart';
import 'calls_v2/services/agora_engine_service.dart';
import 'calls_v2/config/agora_config.dart';
import 'dart:async';
import 'utils/release_logger.dart';
import 'utils/init_diagnostics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'services/device_contact_name_cache.dart';
import 'services/nudge_service.dart';
import 'models/nudge.dart';
import 'widgets/nudge/nudge_receiver_overlay.dart';

// Environment configuration
import 'config/app_config.dart';

// IMPORTANTE: Después de ejecutar 'flutterfire configure',
// descomenta la siguiente línea:
import 'firebase_options.dart';

/// Main entry point for PRODUCTION environment.
/// For staging, use main_staging.dart instead.
void main() async {
  // Set environment to production (default)
  AppConfig.setEnvironment(Environment.production);
  // Preservar splash nativo hasta que la app esté lista
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // 🔍 DEBUG: Detectar TODOS los widget rebuilds
  // Descomenta para ver qué widgets se reconstruyen (⚠️ MUY RUIDOSO)
  // debugPrintRebuildDirtyWidgets = true;

  // Bloquear rotación de pantalla - solo permitir portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  ReleaseLogger.log(
    '📱 Rotación de pantalla bloqueada a portrait',
    tag: 'MainApp',
  );

  // Configurar el status bar para que sea visible
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent, // Hacer el status bar transparente
      statusBarIconBrightness:
          Brightness.dark, // Iconos oscuros para fondo claro
      statusBarBrightness: Brightness.light, // Para iOS
      systemNavigationBarColor: Colors.white, // Barra de navegación blanca
      systemNavigationBarIconBrightness: Brightness.dark, // Iconos oscuros
    ),
  );
  ReleaseLogger.log('📱 Status bar configurado como visible', tag: 'MainApp');

  // 🕐 TIMESTAMP único para identificar logs de esta sesión
  final sessionTimestamp = DateTime.now().millisecondsSinceEpoch;
  ReleaseLogger.log(
    'APP_START_$sessionTimestamp - Iniciando aplicación Talia...',
    tag: 'MainApp',
  );

  // 🚀 CACHE INITIALIZATION: MessageCacheService primero (inicializa Hive)
  ReleaseLogger.log('🚀 Inicializando MessageCacheService...', tag: 'MainApp');
  await InitDiagnostics.track(
    'MessageCache (Hive)',
    () => MessageCacheService().initialize(),
    timeout: const Duration(seconds: 10),
  );

  // Inicializar Firebase solo si no está inicializado
  // Usar try-catch porque algunos plugins nativos pueden auto-inicializar Firebase
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      ReleaseLogger.log('✅ Firebase inicializado (${AppConfig.environmentName})', tag: 'MainApp');
    } else {
      ReleaseLogger.log('✅ Firebase ya estaba inicializado', tag: 'MainApp');
    }
  } catch (e) {
    if (e.toString().contains('duplicate-app')) {
      ReleaseLogger.log('⚠️ Firebase ya inicializado por native SDK (ignorando)', tag: 'MainApp');
    } else {
      rethrow;
    }
  }

  // Continue with common initialization
  await _initializeAfterFirebase();
}

/// Entry point for when Firebase is already initialized (used by main_staging.dart)
/// This allows different entry points to initialize Firebase with different configs
/// before calling the common initialization code.
Future<void> mainWithFirebaseInitialized() async {
  // Preservar splash nativo hasta que la app esté lista
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Bloquear rotación de pantalla - solo permitir portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Configurar el status bar para que sea visible
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  ReleaseLogger.log(
    '🚀 Iniciando Talia (${AppConfig.environmentName})...',
    tag: 'MainApp',
  );

  // Inicializar MessageCacheService (Hive)
  await InitDiagnostics.track(
    'MessageCache (Hive)',
    () => MessageCacheService().initialize(),
    timeout: const Duration(seconds: 10),
  );

  // Firebase ya está inicializado por el entry point
  ReleaseLogger.log('✅ Firebase ya inicializado por entry point', tag: 'MainApp');

  // Continue with common initialization
  await _initializeAfterFirebase();
}

/// Common initialization code after Firebase is ready
Future<void> _initializeAfterFirebase() async {
  // 🚨 CRITICAL: Registrar background handler DESPUÉS de Firebase.initializeApp
  // ANTES de runApp() para que funcione correctamente
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  ReleaseLogger.log(
    '✅ Background message handler registrado en main.dart',
    tag: 'MainApp',
  );

  // 📱 CRÍTICO: Inicializar AppStateService para detectar foreground/background (sync, no bloquea)
  try {
    AppStateService().initialize();
    ReleaseLogger.log('✅ AppStateService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error(
      '❌ Error inicializando AppStateService: $e',
      tag: 'MainApp',
    );
  }

  // 🚀 PERFORMANCE OPTIMIZATION: Inicializar cache services en PARALELO
  // Todos estos servicios usan Hive (ya inicializado) y son independientes entre sí
  ReleaseLogger.log('🚀 Inicializando cache services en paralelo...', tag: 'MainApp');
  await Future.wait([
    InitDiagnostics.track('DashboardCache', () => DashboardCacheService().initialize()),
    InitDiagnostics.track('NotificationCache', () => NotificationCacheService().initialize()),
    InitDiagnostics.track('LocalUnreadCount', () => LocalUnreadCountService().initialize()),
    InitDiagnostics.track('ChatPreferencesCache', () => ChatPreferencesCache().initialize()),
    // 🔒 SST = Hive: sin esto el índice de últimos mensajes de grupos arranca
    // vacío en cold start (solo se inicializaba lazy al guardar/leer) y la
    // chat list muestra grupos sin preview hasta que llega red.
    InitDiagnostics.track('GroupMessageCache', () => GroupMessageCacheService().initialize()),
  ]);
  ReleaseLogger.log('✅ Cache services inicializados en paralelo', tag: 'MainApp');

  // ✅ CRÍTICO: Inicializar StoryService manualmente si el usuario ya está autenticado
  // authStateChanges() solo se dispara en CAMBIOS, no en estados existentes
  ReleaseLogger.log(
    'Verificando usuario autenticado para inicializar StoryService...',
    tag: 'MainApp',
  );
  final currentUser = firebase_auth.FirebaseAuth.instance.currentUser;
  if (currentUser != null) {
    ReleaseLogger.log(
      'Usuario ya autenticado: ${currentUser.uid} - inicializando StoryService manualmente',
      tag: 'MainApp',
    );
    try {
      // 🚀 SPLASH: NO bloquear el arranque esperando el stream de historias.
      // startBackgroundCacheUpdates hace init de red (listeners + fetch inicial)
      // que alargaba el splash en cold start. Fire-and-forget: las historias
      // cargan al renderizar el home, no antes del primer frame.
      unawaited(
        StoryService().startBackgroundCacheUpdates().catchError((e) {
          ReleaseLogger.error(
            'Error iniciando StoryService en background: $e',
            tag: 'MainApp',
          );
        }),
      );

      // ✅ Re-sincronizar timezone del device (self-heal). Evita que Talia mande
      // mensajes en horarios incoherentes si el usuario viajó o se registró con
      // el device en otro offset. No bloquea el arranque.
      unawaited(TimezoneService.syncDeviceTimezone());

      // Pre-cargar Native Ad para stories (no bloquea)
      AdService().preloadStoryNativeAd();
    } catch (e) {
      ReleaseLogger.error(
        'Error inicializando StoryService manualmente: $e',
        tag: 'MainApp',
      );
    }
  } else {
    ReleaseLogger.log(
      'No hay usuario autenticado - StoryService se inicializará con authStateChanges()',
      tag: 'MainApp',
    );
  }

  // Configurar Crashlytics
  // ✅ FIX: Added timeout to prevent hanging if Crashlytics isn't properly configured
  try {
    if (kDebugMode || AppConfig.isStaging) {
      // Deshabilitar Crashlytics en modo debug y staging para no contaminar reportes
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false)
          .timeout(const Duration(seconds: 5), onTimeout: () {
            ReleaseLogger.log('⚠️ Crashlytics config timed out', tag: 'MainApp');
          });
      ReleaseLogger.log(
        '🐛 Crashlytics DESHABILITADO en ${kDebugMode ? "debug" : "staging"}',
        tag: 'MainApp',
      );
    } else {
      // Habilitar Crashlytics en producción
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true)
          .timeout(const Duration(seconds: 5), onTimeout: () {
            ReleaseLogger.log('⚠️ Crashlytics config timed out', tag: 'MainApp');
          });
      ReleaseLogger.log(
        '📊 Crashlytics HABILITADO en producción',
        tag: 'MainApp',
      );
    }
  } catch (e) {
    ReleaseLogger.error('❌ Crashlytics config failed: $e (continuing)', tag: 'MainApp');
  }

  // Capturar errores de Flutter framework
  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
    ReleaseLogger.error(
      '❌ Flutter error capturado: ${errorDetails.exception}',
      tag: 'MainApp',
    );
    ReleaseLogger.error(
      '📍 Stack trace: ${errorDetails.stack}',
      tag: 'MainApp',
    );
    ReleaseLogger.error(
      'FLUTTER ERROR DEBUG - Exception: ${errorDetails.exception}, Library: ${errorDetails.library}, Context: ${errorDetails.context}',
      tag: 'MainApp',
    );
  };

  // Capturar errores asíncronos fuera del framework Flutter
  PlatformDispatcher.instance.onError = (error, stack) {
    // Filter out expected exceptions that are not actual crashes
    final isExpectedException = error is TimeoutException ||
        error.toString().contains('TimeoutException') ||
        error.toString().contains('No active stream to cancel') ||
        error.toString().contains('codec is released already');

    if (isExpectedException) {
      // Log but don't report as fatal - these are expected/handled errors
      ReleaseLogger.log('Expected async error (not fatal): $error', tag: 'MainApp');
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
    } else {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      ReleaseLogger.error('Error asíncrono capturado: $error', tag: 'MainApp');
      ReleaseLogger.error('Stack trace: $stack', tag: 'MainApp');
    }
    return true;
  };

  ReleaseLogger.log('✅ Crashlytics configurado', tag: 'MainApp');

  // 🔑 AppConfigService PRIMERO (secuencial) - necesario para AdService (Remote Config IDs)
  await InitDiagnostics.track(
    'AppConfig (RemoteConfig)',
    () => AppConfigService().initialize(),
    timeout: const Duration(seconds: 10),
  );

  // 🚀 PERFORMANCE OPTIMIZATION: Paralelizar servicios independientes post-Firebase
  ReleaseLogger.log(
    '🚀 Inicializando servicios principales en paralelo...',
    tag: 'MainApp',
  );
  await Future.wait([
    // Grupo 1: Firebase Services
    InitDiagnostics.track('Analytics', () => AnalyticsService().initialize()),
    InitDiagnostics.track('PerformanceMonitoring', () => PerformanceService().initialize()),
    // Grupo 2: Network & Queue Services
    InitDiagnostics.track('NetworkStatus', () => NetworkStatusService().initialize()),
    InitDiagnostics.track('OfflineQueue', () => OfflineQueueService().initialize()),
    // Grupo 3: Independent Services
    InitDiagnostics.track('Accessibility', () => AccessibilityService().initialize()),
    // 📢 AdMob NO va acá: su init tarda ~900ms y bloqueaba el primer frame
    // (el cuello de botella del splash). Se difiere a la init de fondo.
  ]);
  ReleaseLogger.log(
    '✅ Servicios principales inicializados concurrentemente',
    tag: 'MainApp',
  );

  // Pre-cargar stickers y personajes en segundo plano (sin bloquear la app)
  StickersService()
      .preloadStickers()
      .then((_) {
        ReleaseLogger.log('✅Stickers pre-cargados en segundo plano');
      })
      .catchError((e) {
        ReleaseLogger.log(
          '⚠️ Error pre-cargando stickers: $e (continuando...)',
        );
      });

  // ✅ Pre-cargar personajes para face-swap (evita lista vacía al abrir rápido)
  CharacterService()
      .preloadCharacters()
      .then((_) {
        ReleaseLogger.log('✅ Personajes pre-cargados en segundo plano', tag: 'MainApp');
      })
      .catchError((e) {
        ReleaseLogger.log(
          '⚠️ Error pre-cargando personajes: $e (continuando...)',
          tag: 'MainApp',
        );
      });

  // Activar Firebase App Check con Play Integrity para producción
  // ✅ FIX: Usar --dart-define=USE_DEBUG_APP_CHECK=true para probar release sin TestFlight
  // Staging también usa debug App Check para evitar configurar DeviceCheck por separado
  const useDebugAppCheck = bool.fromEnvironment('USE_DEBUG_APP_CHECK', defaultValue: false);

  // Timing del bloque completo de AppCheck — es uno de los principales
  // sospechosos del "primer send lento" tras cold start.
  final appCheckStopwatch = Stopwatch()..start();
  // ✅ FIX: Wrap App Check activation with timeout to prevent hanging in staging
  // App Check can hang if not properly configured in the Firebase project
  try {
    if (kDebugMode || useDebugAppCheck || AppConfig.isStaging) {
      // En modo debug, staging, o cuando se fuerza debug App Check para testing
      await FirebaseAppCheck.instance.activate(
        providerAndroid: const AndroidDebugProvider(),
        providerApple: const AppleDebugProvider(),
        providerWeb: ReCaptchaV3Provider('recaptcha-v3-site-key'),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          ReleaseLogger.log('⚠️ App Check activation timed out (continuing without App Check)', tag: 'MainApp');
        },
      );
      ReleaseLogger.log('🐛Firebase App Check activado con DEBUG provider${AppConfig.isStaging ? " (staging)" : useDebugAppCheck ? " (forzado)" : ""}');

      // Obtener y mostrar el debug token para registrarlo en Firebase Console
      // En Android debug, el token se genera automáticamente por el debug provider
      // OPTIMIZACIÓN: Eliminar delay artificial de 2 segundos en main thread

      // Solo intentar obtener debug token en desarrollo local, no en staging
      // getToken() puede colgarse si App Check no está correctamente configurado
      if (!AppConfig.isStaging) {
        try {
          final token = await FirebaseAppCheck.instance.getToken()
              .timeout(const Duration(seconds: 5), onTimeout: () => null);
          if (token != null && token.isNotEmpty) {
            ReleaseLogger.log('🔑DEBUG TOKEN para Firebase Console:');
            ReleaseLogger.log(
              '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
              tag: 'MainApp',
            );
            ReleaseLogger.log('   $token', tag: 'MainApp');
            ReleaseLogger.log(
              '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
              tag: 'MainApp',
            );
            ReleaseLogger.log('📋Copia este token y regístralo en:');
            ReleaseLogger.log(
              '   Firebase Console → App Check → Apps → Manage debug tokens',
            );
            ReleaseLogger.log(
              '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
              tag: 'MainApp',
            );
          } else {
            ReleaseLogger.log(
              '⚠️ No se pudo obtener debug token (token es null o vacío)',
            );
            ReleaseLogger.log(
              '💡En algunos casos, el token se genera en logcat de Android',
            );
            ReleaseLogger.log('   Busca en logcat: "DebugAppCheckProvider"');
          }
        } catch (e) {
          ReleaseLogger.log('⚠️ No se pudo obtener debug token: $e');
          ReleaseLogger.log(
            '💡El token de debug se puede encontrar en logcat de Android',
          );
          ReleaseLogger.log(
            '   Busca: "DebugAppCheckProvider" o "AppCheckDebugProvider"',
          );
        }
      } else {
        ReleaseLogger.log('⏭️ Saltando getToken() en staging (no necesario)', tag: 'MainApp');
      }
    } else {
      // En producción, usar Play Integrity y Device Check
      await FirebaseAppCheck.instance.activate(
        providerAndroid: const AndroidPlayIntegrityProvider(),
        providerApple: const AppleDeviceCheckProvider(),
        providerWeb: ReCaptchaV3Provider('recaptcha-v3-site-key'),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          ReleaseLogger.log('⚠️ App Check activation timed out (continuing without App Check)', tag: 'MainApp');
        },
      );
      ReleaseLogger.log(
        '✅Firebase App Check activado con Play Integrity y Device Check',
      );

      // 🔥 PRE-WARM del token de AppCheck — trackeado en InitDiagnostics
      // para que su timing aparezca en el banner si es lento. En producción,
      // sin esto, el primer Firestore write tras cold start tiene que esperar
      // a que el SDK pida el token a DeviceCheck/Play Integrity (varios
      // segundos). Eso causaba "mensaje queda pending, después error" al
      // reiniciar la app. Si el banner muestra que AppCheck-prewarm tardó
      // muchos segundos, ése es el culpable del primer-send lento.
      // Fire-and-forget para no bloquear el boot.
      unawaited(InitDiagnostics.track(
        'AppCheck pre-warm token',
        () async {
          final token = await FirebaseAppCheck.instance.getToken();
          if (token == null || token.isEmpty) {
            throw StateError('AppCheck token vacío');
          }
        },
        timeout: const Duration(seconds: 10),
      ));
    }
  } catch (e, st) {
    ReleaseLogger.error('❌ App Check activation failed: $e (continuing without App Check)', tag: 'MainApp');
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'AppCheck activation failed',
      fatal: false,
    );
  }
  appCheckStopwatch.stop();
  // Registramos AppCheck como entry sintética para que aparezca en el banner
  // si es lento (>3s) — es el sospechoso #1 del primer send tardío.
  InitDiagnostics.instance.entries.value = List.of(
    InitDiagnostics.instance.entries.value,
  )..add(
      InitEntry(
        name: 'AppCheck',
        duration: appCheckStopwatch.elapsed,
        failed: false,
        timedOut: false,
      ),
    );

  // Habilitar persistencia offline de Firestore para caché local
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  ReleaseLogger.log('💾Persistencia offline de Firestore habilitada');

  // 🚀 PERFORMANCE OPTIMIZATION: AppConfig puede inicializar concurrentemente con ThemeService
  ReleaseLogger.log(
    '🚀 Inicializando configuración final en paralelo...',
    tag: 'MainApp',
  );
  late ThemeService themeService;

  // ThemeService initialization (AppConfigService ya se inicializó antes)
  themeService = ThemeService();
  await InitDiagnostics.track(
    'ThemeService',
    () => themeService.initialize(),
    timeout: const Duration(seconds: 10),
  );
  ReleaseLogger.log(
    '✅ Configuración final completada concurrentemente',
    tag: 'MainApp',
  );

  // 🚀 PERFORMANCE OPTIMIZATION: Diferir servicios pesados para después de runApp()
  // Esto permite que la UI se renderice primero, mejorando perceived performance

  ReleaseLogger.log(
    '🎯 Configuración crítica completada - iniciando UI...',
    tag: 'MainApp',
  );

  // ✅ FIX iOS DUPLICATE: Check if app was opened from killed state via notification tap
  // This MUST run BEFORE runApp() so the messageId is saved BEFORE ChatDocsListener activates
  // When app is killed and user taps notification:
  // 1. iOS shows push notification
  // 2. App starts fresh (memory empty)
  // 3. This code saves messageId + full data to SharedPreferences (persistent)
  // 4. runApp() -> ChatDocsListener activates -> checks SharedPreferences -> SKIP duplicate
  // 5. NotificationService.initialize() -> reads pending navigation -> navigates to chat
  // ✅ FIX: Added timeout to prevent hanging if FCM isn't properly configured
  try {
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage()
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (initialMessage != null) {
      final prefs = await SharedPreferences.getInstance();
      // NOTA: antes acá se escribían tapped_notification_message_id y
      // tapped_notification_timestamp "para dedup" — ningún código los leía
      // (claves muertas que quedaban en SharedPreferences para siempre).
      // La dedup real de navegación es el registry `tap` en
      // NotificationDedupRegistry + pending_notification_data.

      // ✅ Save full notification data for navigation (NotificationService will process this)
      await prefs.setString('pending_notification_data', jsonEncode(initialMessage.data));
      ReleaseLogger.log(
        '✅ [Navigation] Datos de notificación guardados para navegación pendiente',
        tag: 'MainApp',
      );
    }
  } catch (e) {
    ReleaseLogger.error('Error checking getInitialMessage: $e', tag: 'MainApp');
  }

  runApp(
    ChangeNotifierProvider.value(value: themeService, child: const TaliaApp()),
  );

  // 🚀 BACKGROUND INITIALIZATION: Inicializar servicios pesados después del primer render
  // Esto mejora el perceived performance significativamente
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Remover splash nativo ahora que la UI está lista
    FlutterNativeSplash.remove();
    _initializeHeavyServicesInBackground();
  });
}

/// 🚀 PERFORMANCE OPTIMIZATION: Inicializar servicios pesados en background
/// después de que la UI esté completamente renderizada
Future<void> _initializeHeavyServicesInBackground() async {
  ReleaseLogger.log(
    '🚀 Inicializando servicios pesados en background...',
    tag: 'BackgroundInit',
  );

  // Paralelizar servicios pesados para máximo performance
  await Future.wait([
    // 📢 AdMob (diferido - su init tarda ~900ms; era el cuello de botella del
    // splash. Los ads cargan lazy al mostrarse un widget de ad).
    AdService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ AdMob inicializado en background',
            tag: 'BackgroundInit',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '❌ Error inicializando AdMob: $e',
            tag: 'BackgroundInit',
          );
        }),

    // 🎥 Agora Config (diferido - solo necesario para llamadas)
    AgoraConfig.initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ AgoraConfig inicializado en background',
            tag: 'BackgroundInit',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '❌ Error inicializando AgoraConfig: $e',
            tag: 'BackgroundInit',
          );
        }),

    // Deep Link Service (App Links / Universal Links)
    DeepLinkService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ DeepLinkService inicializado en background',
            tag: 'BackgroundInit',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '❌ Error inicializando DeepLinkService: $e',
            tag: 'BackgroundInit',
          );
        }),

    // Shared Keychain Service (share Firebase credentials with Share Extension)
    () async {
      await SharedKeychainService().initialize();
      ReleaseLogger.log(
        '✅ SharedKeychainService inicializado',
        tag: 'BackgroundInit',
      );
    }().catchError((e) {
      ReleaseLogger.error(
        '❌ Error inicializando SharedKeychainService: $e',
        tag: 'BackgroundInit',
      );
    }),

    // Share Target Service (receive shared content from other apps)
    () async {
      final shareService = ShareTargetService();

      // ✅ FIX: Configurar callback para cuando llega nuevo share via stream
      shareService.onShareReceived = (contents) async {
        ReleaseLogger.log(
          '📥 [ShareTarget] New share received via stream: ${contents.length} items',
          tag: 'ShareTarget',
        );

        // Verificar si hay chats pre-seleccionados
        final preSelectedChatIds = shareService.pendingDestinationChatIds;
        if (preSelectedChatIds != null && preSelectedChatIds.isNotEmpty) {
          ReleaseLogger.log(
            '📥 [ShareTarget] Sending directly to ${preSelectedChatIds.length} pre-selected chats',
            tag: 'ShareTarget',
          );
          await _sendShareDirectly(contents, preSelectedChatIds);
          return;
        }

        // Solo navegar a pantalla si no hay chats pre-seleccionados
        _navigateToShareScreen();
      };

      await shareService.initialize();

      ReleaseLogger.log(
        '✅ ShareTargetService inicializado en background',
        tag: 'BackgroundInit',
      );

      // Verificar si hay contenido pendiente del iOS Share Extension
      _checkPendingShareContent();
    }().catchError((e) {
      ReleaseLogger.error(
        '❌ Error inicializando ShareTargetService: $e',
        tag: 'BackgroundInit',
      );
    }),

    // Notification Service (FCM setup)
    NotificationService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ NotificationService inicializado en background',
            tag: 'BackgroundInit',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '❌ Error inicializando NotificationService: $e',
            tag: 'BackgroundInit',
          );
        }),

    // VoIP Service (solo iOS, para llamadas)
    () async {
      ReleaseLogger.log(
        'Verificando plataforma iOS - Platform.isIOS = ${Platform.isIOS}',
        tag: 'VoIPDebug',
      );

      if (Platform.isIOS) {
        ReleaseLogger.log(
          'Ejecutando en iOS - iniciando VoIP Service...',
          tag: 'VoIPDebug',
        );

        try {
          await VoIPService().initialize();
          ReleaseLogger.log(
            'VoIP Service inicializado en background (iOS)',
            tag: 'BackgroundInit',
          );

          // ✅ CRÍTICO: Debug adicional para verificar estado del token VoIP
          ReleaseLogger.log(
            'Verificando estado token VoIP post-inicialización...',
            tag: 'VoIPDebug',
          );
          try {
            final user = firebase_auth.FirebaseAuth.instance.currentUser;
            ReleaseLogger.log(
              'Usuario autenticado: ${user?.uid ?? "null"}',
              tag: 'VoIPDebug',
            );

            if (user != null) {
              // Verificar token en Firestore
              final userDoc = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .get();

              if (userDoc.exists) {
                final data = userDoc.data() as Map<String, dynamic>;
                final voipToken = data['voipToken'] as String?;
                final tokenUpdatedAt = data['voipTokenUpdatedAt'];

                ReleaseLogger.log(
                  'VoIP Token existe: ${voipToken != null}',
                  tag: 'VoIPDebug',
                );
                if (voipToken != null) {
                  ReleaseLogger.log(
                    'Token (primeros 20): ${voipToken.length > 20 ? '${voipToken.substring(0, 20)}...' : voipToken}',
                    tag: 'VoIPDebug',
                  );
                  ReleaseLogger.log(
                    'Token actualizado: $tokenUpdatedAt',
                    tag: 'VoIPDebug',
                  );
                } else {
                  ReleaseLogger.error(
                    'NO HAY TOKEN VOIP - Intentando forzar solicitud de token...',
                    tag: 'VoIPDebug',
                  );

                  // Forzar solicitud manual de token VoIP
                  const platform = MethodChannel('com.talia.chat/voip');
                  try {
                    await platform.invokeMethod('requestVoIPToken');
                    ReleaseLogger.log(
                      'Solicitud manual enviada a iOS',
                      tag: 'VoIPDebug',
                    );
                  } catch (platformError) {
                    ReleaseLogger.error(
                      'Error llamando método nativo: $platformError',
                      tag: 'VoIPDebug',
                    );
                  }
                }
              } else {
                ReleaseLogger.error(
                  'Documento de usuario no existe',
                  tag: 'VoIPDebug',
                );
              }
            } else {
              ReleaseLogger.log(
                'Usuario no autenticado en momento de inicialización VoIP',
                tag: 'VoIPDebug',
              );
            }
          } catch (debugError) {
            ReleaseLogger.error(
              'Error en verificación post-inicialización: $debugError',
              tag: 'VoIPDebug',
            );
          }
        } catch (e) {
          ReleaseLogger.error(
            'Error inicializando VoIP Service: $e',
            tag: 'BackgroundInit',
          );
        }
      } else {
        ReleaseLogger.log(
          'Plataforma no es iOS, saltando VoIP',
          tag: 'VoIPDebug',
        );
      }
    }(),

    // APNs Token (solo iOS, para Phone Auth)
    () async {
      if (Platform.isIOS) {
        try {
          final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
          if (apnsToken != null) {
            ReleaseLogger.log(
              '✅ APNs token obtenido en background: ${apnsToken.substring(0, 20)}...',
              tag: 'BackgroundInit',
            );
          } else {
            ReleaseLogger.log(
              '⚠️ APNs token no disponible - configurando listener',
              tag: 'BackgroundInit',
            );
            FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
              ReleaseLogger.log(
                '✅ APNs token actualizado en background',
                tag: 'BackgroundInit',
              );
            });
          }
        } catch (e) {
          ReleaseLogger.error(
            '❌ Error obteniendo APNs token: $e',
            tag: 'BackgroundInit',
          );
        }
      }
    }(),

    // Media preloading is now handled by StoryOrchestrator via background streams
  ]);

  ReleaseLogger.log(
    '✅ Servicios pesados inicializados completamente en background',
    tag: 'BackgroundInit',
  );
}

/// Verifica si hay contenido pendiente del iOS Share Extension
/// y navega a ShareTargetSelectionScreen si es necesario
Future<void> _checkPendingShareContent() async {
  if (!Platform.isIOS) return;

  final shareService = ShareTargetService();
  if (!shareService.hasPendingContent) return;

  final pendingContent = shareService.pendingContent;
  final preSelectedChatIds = shareService.pendingDestinationChatIds;

  ReleaseLogger.log(
    '📤 [ShareTarget] Found pending content: ${pendingContent?.length ?? 0} items, '
    'pre-selected chats: ${preSelectedChatIds?.length ?? 0}',
    tag: 'ShareTarget',
  );

  // Si hay chats pre-seleccionados desde el Share Extension, enviar directamente
  if (preSelectedChatIds != null && preSelectedChatIds.isNotEmpty && pendingContent != null) {
    ReleaseLogger.log(
      '📤 [ShareTarget] Sending directly to ${preSelectedChatIds.length} pre-selected chats',
      tag: 'ShareTarget',
    );
    // ✅ FIX: Esperar a que termine el envío antes de continuar
    await _sendShareDirectly(pendingContent, preSelectedChatIds);
    return;
  }

  // Si no hay chats pre-seleccionados, mostrar pantalla de selección
  _navigateToShareScreen();
}

/// ✅ NEW: Verificar shares pendientes al volver a foreground (iOS)
Future<void> _checkPendingShareOnResume() async {
  try {
    final shareService = ShareTargetService();

    // Forzar refresh del contenido pendiente
    await shareService.refreshPendingContent();

    if (!shareService.hasPendingContent) return;

    final pendingContent = shareService.pendingContent;
    final preSelectedChatIds = shareService.pendingDestinationChatIds;

    ReleaseLogger.log(
      '📤 [ShareTarget] Found pending content on resume: ${pendingContent?.length ?? 0} items, '
      'pre-selected chats: ${preSelectedChatIds?.length ?? 0}',
      tag: 'ShareTarget',
    );

    // ✅ FIX: Si hay chats pre-seleccionados, enviar directamente (no mostrar pantalla)
    if (preSelectedChatIds != null && preSelectedChatIds.isNotEmpty && pendingContent != null) {
      ReleaseLogger.log(
        '📤 [ShareTarget] Sending directly to ${preSelectedChatIds.length} pre-selected chats',
        tag: 'ShareTarget',
      );
      await _sendShareDirectly(pendingContent, preSelectedChatIds);
      return;
    }

    // Solo mostrar pantalla si NO hay chats pre-seleccionados
    _navigateToShareScreen();
  } catch (e) {
    ReleaseLogger.error(
      '📤 [ShareTarget] Error checking pending share on resume: $e',
      tag: 'ShareTarget',
    );
  }
}

/// ✅ NEW: Navegar a la pantalla de share
/// Flag para evitar múltiples pantallas
bool _isShareScreenShowing = false;

void _navigateToShareScreen({int attempt = 0}) {
  // Evitar múltiples pantallas de share
  if (_isShareScreenShowing) {
    ReleaseLogger.log(
      '📤 [ShareTarget] Share screen already showing, skipping navigation',
      tag: 'ShareTarget',
    );
    return;
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_isShareScreenShowing) return;
    final navigator = DeepLinkService.navigatorKey.currentState;
    if (navigator != null) {
      ReleaseLogger.log(
        '📤 [ShareTarget] Navigating to ShareTargetSelectionScreen',
        tag: 'ShareTarget',
      );
      _isShareScreenShowing = true;
      navigator.push(
        MaterialPageRoute(
          builder: (context) => const ShareTargetSelectionScreen(),
        ),
      ).then((_) {
        // Reset flag cuando se cierra la pantalla
        _isShareScreenShowing = false;
        ReleaseLogger.log(
          '📤 [ShareTarget] Share screen closed',
          tag: 'ShareTarget',
        );
      });
    } else if (attempt < 20) {
      // En cold start desde share el navigator puede no existir todavía.
      // Antes solo se logueaba "will retry" sin reintentar y el share se
      // perdía. Reintentar hasta ~10s.
      Future.delayed(const Duration(milliseconds: 500), () {
        _navigateToShareScreen(attempt: attempt + 1);
      });
    } else {
      ReleaseLogger.error(
        '📤 [ShareTarget] Navigator never became available, share dropped',
        tag: 'ShareTarget',
      );
    }
  });
}

/// Enviar contenido compartido directamente a los chats pre-seleccionados
/// ✅ OPTIMISTIC: Muestra feedback inmediato y envía en background
Future<void> _sendShareDirectly(
  List<SharedContent> content,
  List<String> chatIds,
) async {
  final shareService = ShareTargetService();

  // ✅ OPTIMISTIC: Mostrar feedback inmediato ANTES de empezar el envío
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final context = DeepLinkService.navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Text('Enviando a ${chatIds.length} chat${chatIds.length > 1 ? 's' : ''}...'),
            ],
          ),
          backgroundColor: Colors.blue,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  });

  // Limpiar contenido pendiente inmediatamente para evitar re-procesamiento
  shareService.clearPendingContent();

  // ✅ OPTIMISTIC: Enviar en background sin bloquear
  _sendShareInBackground(content, chatIds);
}

/// Envía el contenido compartido en background
/// Se ejecuta de forma asíncrona sin bloquear el UI
Future<void> _sendShareInBackground(
  List<SharedContent> content,
  List<String> chatIds,
) async {
  try {
    final chatOrchestrator = ChatOrchestrator();
    final shareService = ShareTargetService();
    int successCount = 0;
    int totalItems = content.length * chatIds.length;

    for (final chatId in chatIds) {
      for (final item in content) {
        try {
          if (item.isMedia && item.mediaPath != null) {
            // Copiar archivo a ubicación accesible
            final copiedPath = await shareService.copyToTempDirectory(item.mediaPath!);
            if (copiedPath == null) {
              ReleaseLogger.error(
                '📤 [ShareTarget] Failed to copy file: ${item.mediaPath}',
                tag: 'ShareTarget',
              );
              continue;
            }

            final messageType = item.type == SharedContentType.image
                ? MessageType.image
                : MessageType.video;

            // ✅ El sendMessage ya es optimista internamente
            // El mensaje aparece inmediatamente en el cache del chat
            await chatOrchestrator.sendMessage(
              chatId: chatId,
              content: item.text ?? '',
              type: messageType,
              mediaPath: copiedPath,
            );

            successCount++;
            ReleaseLogger.log(
              '📤 [ShareTarget] Sent ${item.type.name} to chat $chatId',
              tag: 'ShareTarget',
            );
          } else if (item.isText && item.text != null) {
            await chatOrchestrator.sendMessage(
              chatId: chatId,
              content: item.text!,
              type: MessageType.text,
            );
            successCount++;
          } else if (item.isUrl && item.url != null) {
            await chatOrchestrator.sendMessage(
              chatId: chatId,
              content: item.url!,
              type: MessageType.text,
            );
            successCount++;
          }
        } catch (itemError) {
          ReleaseLogger.error(
            '📤 [ShareTarget] Error sending item: $itemError',
            tag: 'ShareTarget',
          );
        }
      }
    }

    ReleaseLogger.log(
      '📤 [ShareTarget] Background send complete: $successCount/$totalItems',
      tag: 'ShareTarget',
    );

    // Mostrar resultado final
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = DeepLinkService.navigatorKey.currentContext;
      if (context != null) {
        final isSuccess = successCount > 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isSuccess
                ? '✓ Enviado correctamente'
                : 'Error al enviar contenido',
            ),
            backgroundColor: isSuccess ? Colors.green : Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  } catch (e) {
    ReleaseLogger.error(
      '📤 [ShareTarget] Error in background send: $e',
      tag: 'ShareTarget',
    );

    // Mostrar error
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = DeepLinkService.navigatorKey.currentContext;
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al enviar contenido'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }
}

class TaliaApp extends StatefulWidget {
  const TaliaApp({super.key});

  @override
  State<TaliaApp> createState() => _TaliaAppState();
}

class _TaliaAppState extends State<TaliaApp> with WidgetsBindingObserver {
  StreamSubscription<DocumentSnapshot>? _userRoleSubscription;
  StreamSubscription<firebase_auth.User?>?
  _authSubscription; // ✅ NUEVO: listener auth independiente
  StreamSubscription<NudgeData>? _nudgeSubscription; // 📳 Nudges entrantes
  // Usar el navigatorKey del DeepLinkService para navegación global
  final GlobalKey<NavigatorState> _navigatorKey = DeepLinkService.navigatorKey;
  String? _currentUserRole;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupRoleListener();

    // ✅ FIX PERMISSION_DENIED: Only initialize LEGACY CallsOrchestrator when NOT using V2
    // V2 system uses VoIPService + CallServiceWrapper directly (no orchestrator needed)
    _initializeCallSystem();

    // 📳 NUDGE: Escuchar nudges entrantes y mostrar overlay
    _setupNudgeListener();

    // Procesar deep links pendientes después del primer frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService().processPendingStory();
      DeepLinkService().processPendingShare();
    });
  }

  /// Initialize V2 Agora call system (legacy system removed)
  Future<void> _initializeCallSystem() async {
    ReleaseLogger.log(
      '🚀 [Main] Initializing V2 Agora call system (VoIP/CallKit only)',
      tag: 'Main',
    );

    // V2 NAVIGATION: Shared navigation callback for both iOS and Android
    // ✅ FIX #1: Código defensivo para evitar crash al contestar desde lock screen
    void navigateToCall(String callId, {bool isIncoming = false}) {
      ReleaseLogger.log(
        '🚀 [Main] Navigating to AgoraCallScreen: $callId (incoming: $isIncoming)',
        tag: 'Main',
      );

      try {
        // ✅ FIX #1: Verificar que el Navigator esté disponible antes de navegar
        final navigatorState = _navigatorKey.currentState;
        if (navigatorState == null) {
          ReleaseLogger.error(
            '❌ [Main] Navigator not available - deferring navigation',
            tag: 'Main',
          );
          // Diferir navegación hasta que el widget tree esté listo
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _safeNavigateToCall(callId, isIncoming: isIncoming);
          });
          return;
        }

        // Navigate using CallServiceWrapper which returns AgoraCallScreen for V2
        final callScreen = CallServiceWrapper().getCallScreen(
          callId: callId,
          isIncoming: isIncoming,
        );

        navigatorState.push(
          MaterialPageRoute(
            builder: (context) => callScreen,
          ),
        );

        ReleaseLogger.log('✅ [Main] Navigation to AgoraCallScreen completed', tag: 'Main');
      } catch (e, stackTrace) {
        // ✅ FIX #1: Capturar cualquier error y diferir navegación
        ReleaseLogger.error(
          '❌ [Main] Error navigating to call screen: $e',
          tag: 'Main',
        );
        ReleaseLogger.error('Stack trace: $stackTrace', tag: 'Main');

        // Intentar diferir la navegación
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _safeNavigateToCall(callId, isIncoming: isIncoming);
        });
      }
    }

    // Configure iOS path (VoIPService)
    VoIPService().onNavigateToCall = navigateToCall;

    // Configure Android path (NotificationService)
    NotificationService().onNavigateToCall = navigateToCall;

    ReleaseLogger.log(
      '✅ [Main] V2 navigation callbacks configured for both platforms',
      tag: 'Main',
    );
  }

  /// ✅ FIX #1: Safe navigation with retry for calls from lock screen
  /// This handles cases where the Navigator isn't immediately available
  int _navigationRetryCount = 0;
  static const int _maxNavigationRetries = 3;

  void _safeNavigateToCall(String callId, {bool isIncoming = false}) {
    try {
      ReleaseLogger.log(
        '🔄 [Main] Safe navigation attempt ${_navigationRetryCount + 1} for: $callId',
        tag: 'Main',
      );

      final navigatorState = _navigatorKey.currentState;
      if (navigatorState == null) {
        _navigationRetryCount++;
        if (_navigationRetryCount < _maxNavigationRetries) {
          ReleaseLogger.log(
            '⏳ [Main] Navigator still not ready, scheduling retry...',
            tag: 'Main',
          );
          // Esperar un poco más y reintentar
          Future.delayed(const Duration(milliseconds: 500), () {
            _safeNavigateToCall(callId, isIncoming: isIncoming);
          });
        } else {
          ReleaseLogger.error(
            '❌ [Main] Max navigation retries reached, call may not display',
            tag: 'Main',
          );
          _navigationRetryCount = 0;
        }
        return;
      }

      // Reset retry count on success
      _navigationRetryCount = 0;

      final callScreen = CallServiceWrapper().getCallScreen(
        callId: callId,
        isIncoming: isIncoming,
      );

      navigatorState.push(
        MaterialPageRoute(
          builder: (context) => callScreen,
        ),
      );

      ReleaseLogger.log('✅ [Main] Safe navigation completed', tag: 'Main');
    } catch (e) {
      ReleaseLogger.error('❌ [Main] Safe navigation failed: $e', tag: 'Main');
      _navigationRetryCount = 0;
    }
  }

  /// 📳 Configurar listener para nudges entrantes
  void _setupNudgeListener() {
    ReleaseLogger.log('📳 [Main] Configurando nudge listener...', tag: 'Nudge');

    // Inicializar method channel para iOS (recibe nudges desde AppDelegate)
    NudgeService().initialize();

    _nudgeSubscription = NudgeService().incomingNudges.listen(
      (nudge) {
        ReleaseLogger.log(
          '📳 [Main] Stream recibió nudge: ${nudge.type.displayName} de ${nudge.senderName}',
          tag: 'Nudge',
        );

        // Mostrar overlay usando el context del navigator
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final context = _navigatorKey.currentContext;
          ReleaseLogger.log(
            '📳 [Main] Context disponible: ${context != null}',
            tag: 'Nudge',
          );
          if (context != null) {
            ReleaseLogger.log('📳 [Main] Mostrando overlay...', tag: 'Nudge');
            NudgeOverlayManager().showNudgeOverlay(context, nudge);
            ReleaseLogger.log('📳 [Main] Overlay mostrado', tag: 'Nudge');
          } else {
            ReleaseLogger.error(
              '❌ [Main] No hay context disponible para mostrar overlay',
              tag: 'Nudge',
            );
          }
        });
      },
      onError: (error) {
        ReleaseLogger.error(
          '❌ [Main] Error en stream de nudges: $error',
          tag: 'Nudge',
        );
      },
    );

    ReleaseLogger.log('✅ [Main] Nudge listener configurado y escuchando', tag: 'Nudge');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _userRoleSubscription?.cancel();
    _authSubscription?.cancel();
    _nudgeSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // ✅ FIX: Notificar a NotificationService cuando la app vuelve a foreground
    // Esto evita que las notificaciones de background se muestren como foreground
    if (state == AppLifecycleState.resumed) {
      // 🔒 RECOVERY POST-BACKGROUND: el síntoma "abro la app y no se actualizan
      // historias / no se envían mensajes; la cierro y reabro y funciona" suele
      // ser por:
      //   (a) App Check token expirado y la app sin mecanismo de refresh.
      //       Sin token válido, Firestore/CFs rechazan o cuelgan.
      //   (b) Long-lived Firestore gRPC stream suspendido por iOS/Android
      //       durante background largo (>5min). Los listeners siguen "vivos"
      //       en Dart pero el socket no recibe updates hasta que algo lo
      //       despierte.
      // Ambos se fuerzan acá en resume. Fire-and-forget con timeout corto
      // para no bloquear el resto del lifecycle.
      unawaited(() async {
        try {
          await FirebaseAppCheck.instance
              .getToken(true)
              .timeout(const Duration(seconds: 5));
          ReleaseLogger.log(
            '🔐 App Check token refreshed on resume',
            tag: 'AppLifecycle',
          );
        } catch (e) {
          ReleaseLogger.warning(
            'App Check token refresh failed on resume (no crítico): $e',
            tag: 'AppLifecycle',
          );
        }
      }());
      // 🔌 Despertar el socket de Firestore y RECIÉN AHÍ refrescar historias.
      // enableNetwork() es local y casi instantáneo (flipea un flag, la
      // reconexión real pasa async). El listener de historias debe reabrirse
      // sobre un socket ya re-habilitado: si lo hace antes (como pasaba con
      // las tres operaciones en paralelo) se engancha a un socket suspendido,
      // no emite, y el auto-retry recién dispara a los 30s — o nunca si no
      // tira error. Resultado: historias vacías hasta matar la app.
      // El refresh del token de App Check (arriba) queda en paralelo a
      // propósito: el SDK adjunta el token por request y lo renueva solo,
      // no hace falta bloquear las historias esperándolo.
      unawaited(() async {
        try {
          await FirebaseFirestore.instance
              .enableNetwork()
              .timeout(const Duration(seconds: 5));
        } catch (e) {
          ReleaseLogger.warning(
            'Firestore enableNetwork failed on resume (no crítico): $e',
            tag: 'AppLifecycle',
          );
        }
        // softRefreshCache() NO invalida el cache de historias, así que el
        // usuario ve las historias viejas al instante; esto solo dispara la
        // llegada de datos frescos sobre un socket vivo.
        ReleaseLogger.log('📱 App resumed - soft refreshing story stream...', tag: 'AppLifecycle');
        try {
          await StoryService().softRefreshCache();
          ReleaseLogger.log('✅ Story stream soft refreshed', tag: 'AppLifecycle');
        } catch (e) {
          ReleaseLogger.error('⚠️ Error soft refreshing story stream: $e', tag: 'AppLifecycle');
        }
      }());

      NotificationService().notifyAppResumed();

      // ✅ Actualizar badge con el conteo real al abrir la app
      // (en lugar de clearBadge que lo ponía en 0, causando badges fantasma)
      UnreadMessagesService().updateBadgeCount();

      // ✅ AGORA WATCHDOG: Notificar que la app volvió a foreground
      AgoraEngineService().onAppForeground();

      // Sincronizar permisos para usuarios hijo
      if (_currentUserRole == 'child') {
        PermissionSyncService().syncPermissions();
      }

      // ✅ FIX: Verificar nuevos shares pendientes en iOS App Group
      // Esto maneja el caso donde el usuario compartió algo mientras la app estaba en background
      if (Platform.isIOS) {
        _checkPendingShareOnResume();
      }
    } else if (state == AppLifecycleState.paused) {
      // ✅ AGORA WATCHDOG: Notificar que la app va a background
      // Esto activa un watchdog más agresivo para evitar llamadas huérfanas
      AgoraEngineService().onAppBackground();

      // 🔑 Share Extension (iOS): refrescar el ID token compartido en el App
      // Group justo cuando el usuario sale de la app. El token vence a los
      // 55 min y la extensión no puede refrescarlo sola; el momento típico de
      // compartir es inmediatamente después de salir de Talia (ej. desde
      // Fotos), así que esto maximiza la ventana en que el envío directo
      // funciona.
      if (Platform.isIOS) {
        unawaited(SharedKeychainService().refreshToken());
      }

      // 🧹 MEMORIA: liberar el engine de Agora si NO hay llamada activa. En
      // background retiene el pipeline de video/cámara nativo (mucha memoria),
      // lo que hace que el OS mate la app más seguido → splash al reabrir.
      // Se re-crea solo en la próxima llamada. Solo en 'paused' (background
      // real), NO en 'inactive' (transitorio: control center, app switcher,
      // diálogo de permisos) para no liberar/recrear innecesariamente.
      unawaited(AgoraEngineService().releaseIfIdle());
    } else if (state == AppLifecycleState.inactive) {
      AgoraEngineService().onAppBackground();
    }
  }

  void _setupRoleListener() {
    firebase_auth.FirebaseAuth.instance.authStateChanges().listen((user) {
      ReleaseLogger.log(
        '🔐 AUTH STATE CHANGED - User: ${user?.uid ?? "null"}, Phone: ${user?.phoneNumber ?? "null"}',
      );
      if (user != null) {
        ReleaseLogger.log('✅Usuario autenticado: ${user.uid}');

        // Inicializar protección de screenshots
        ReleaseLogger.log('📸 Inicializando ScreenshotProtectionService...');
        ScreenshotProtectionService().initialize();
        ReleaseLogger.log('✅ScreenshotProtectionService inicializado');

        // Inicializar listener de badge del ícono
        ReleaseLogger.log('🔔Inicializando badge listener...');
        UnreadMessagesService().startBadgeListener();
        ReleaseLogger.log('✅Badge listener inicializado');

        // ✅ P1: Inicializar cache proactivo de fotos de contactos
        ReleaseLogger.log('📸 Inicializando ContactPhotoCacheService...');
        ContactPhotoCacheService().initialize().then((_) {
          ReleaseLogger.log('✅ ContactPhotoCacheService inicializado');
        }).catchError((e) {
          ReleaseLogger.error('❌ Error inicializando ContactPhotoCacheService: $e');
        });

        // ✅ P3: Inicializar listener de aliases
        ReleaseLogger.log('🏷️ Inicializando alias listener...');
        ContactPhotoCacheService().startAliasListener();

        // ✅ Inicializar cache de nombres de contactos del dispositivo
        ReleaseLogger.log('📱 Inicializando DeviceContactNameCache...');
        DeviceContactNameCache().initialize().then((_) {
          ReleaseLogger.log('✅ DeviceContactNameCache inicializado');
        }).catchError((e) {
          ReleaseLogger.error('❌ Error inicializando DeviceContactNameCache: $e');
        });

        // Inicializar stream background de historias
        ReleaseLogger.log('📱Iniciando stream background de historias...');
        StoryService()
            .startBackgroundCacheUpdates()
            .then((_) {
              ReleaseLogger.log('✅Stream background de historias iniciado');
              // Pre-cargar Native Ad para stories (no bloquea)
              AdService().preloadStoryNativeAd();
            })
            .catchError((e) {
              ReleaseLogger.log(
                '⚠️ Error iniciando stream background de historias: $e',
              );
            });

        // Cancelar suscripción anterior si existe
        _userRoleSubscription?.cancel();

        // Crear nueva suscripción para escuchar cambios de rol
        _userRoleSubscription = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots()
            .listen((snapshot) {
              ReleaseLogger.log(
                '📄 Snapshot de usuario: exists=${snapshot.exists}, data=${snapshot.data()}',
              );
              if (snapshot.exists) {
                final userData = snapshot.data();
                final newRole = userData?['role'] ?? 'child';
                ReleaseLogger.log('🔍Role actual en Firestore: $newRole');
                ReleaseLogger.log(
                  '🔍Role guardado en memoria: $_currentUserRole',
                );

                if (_currentUserRole != null && _currentUserRole != newRole) {
                  ReleaseLogger.log(
                    '🔄 Role cambió de $_currentUserRole a $newRole - Verificando si necesita navegación',
                  );

                  // Actualizar role primero
                  _currentUserRole = newRole;

                  // V2 system: No Firestore listeners for calls (VoIP/CallKit only)
                  // Safe to use short delay
                  const delayMs = 300;
                  ReleaseLogger.log(
                    '🔄 Esperando ${delayMs}ms para refresh de datos de Firestore',
                  );

                  // Navegar después de un delay apropiado
                  Future.delayed(Duration(milliseconds: delayMs), () {
                    final navigator = _navigatorKey.currentState;
                    if (navigator != null && navigator.mounted) {
                      ReleaseLogger.log(
                        '✅ Navegando a AuthWrapper con nuevo rol: $newRole (post-delay)',
                      );
                      navigator.pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => const AuthWrapper()),
                        (route) => false,
                      );
                    } else {
                      ReleaseLogger.log(
                        '⚠️ Navigator no disponible para navegación',
                      );
                    }
                  });
                } else if (_currentUserRole == null) {
                  ReleaseLogger.log(
                    'ℹ️Inicializando role por primera vez: $newRole',
                  );
                  _currentUserRole = newRole;

                  // Sincronizar permisos para usuarios hijo al iniciar
                  if (newRole == 'child') {
                    PermissionSyncService().syncPermissions();
                  }
                }
              }
            },
            onError: (error) {
              ReleaseLogger.error('❌ [Main] User role stream error: $error');
            },
            cancelOnError: false,
          );
      } else {
        // Usuario deslogueado - cancelar listener de Firestore
        _userRoleSubscription?.cancel();
        _userRoleSubscription = null;
        _currentUserRole = null;
        ReleaseLogger.log('🔒 Listener de role cancelado por logout');

        // Limpiar cache de historias
        StoryService().clearCache();
        ReleaseLogger.log('🧹 Cache de historias limpiado por logout');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);

    // Aplicar alto contraste si está habilitado
    final baseTheme = themeService.currentTheme;
    final accessibleTheme = accessibility.highContrast
        ? baseTheme.copyWith(
            colorScheme: accessibility.getHighContrastColors(
              baseTheme.colorScheme,
            ),
          )
        : baseTheme;

    Widget app = GestureDetector(
      onTap: () {
        // Cerrar teclado al tocar fuera de cualquier input
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: NetworkStatusBanner(
        child: MaterialApp(
          key: ValueKey('app_${_currentUserRole ?? "unknown"}_${AppConfig.environmentName}'),
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: SnackbarService().scaffoldMessengerKey,
          title: 'Tália${AppConfig.environmentBadge}',
          debugShowCheckedModeBanner: false,
          theme: accessibleTheme,
          // Configuración de localización para date pickers nativos
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('es', 'ES'), // Español España
            Locale('es', 'AR'), // Español Argentina
            Locale('es', 'MX'), // Español México
            Locale('es', ''), // Español genérico
            Locale('en', 'US'), // Inglés como fallback
          ],
          locale: const Locale('es', 'ES'), // Idioma por defecto
          builder: (context, child) {
            // Obtener el brightness del tema actual
            final brightness = Theme.of(context).brightness;

            // Aplicar text scale factor y status bar style
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: brightness == Brightness.dark
                    ? Brightness
                          .light // Iconos claros para modo oscuro
                    : Brightness.dark, // Iconos oscuros para modo claro
                statusBarBrightness: brightness == Brightness.dark
                    ? Brightness.dark
                    : Brightness.light,
                systemNavigationBarColor: brightness == Brightness.dark
                    ? Colors.black
                    : Colors.white,
                systemNavigationBarIconBrightness: brightness == Brightness.dark
                    ? Brightness.light
                    : Brightness.dark,
              ),
              child: Builder(
                builder: (context) {
                  final mediaQueryData = MediaQuery.maybeOf(context);
                  // ✅ Banner de diagnóstico de init REMOVIDO: era una herramienta
                  // temporal para detectar el culpable del primer-send lento y no
                  // debe aparecer en producción ("Init lento: ...").
                  final wrapped = child!;
                  if (mediaQueryData == null) {
                    return wrapped;
                  }
                  return MediaQuery(
                    data: mediaQueryData.copyWith(
                      textScaler: TextScaler.linear(accessibility.textScale),
                    ),
                    child: wrapped,
                  );
                },
              ),
            );
          },
          home: const AuthWrapper(),
          onGenerateRoute: (settings) {
            // Rutas dinámicas removidas - moderación se maneja directamente desde whitelist
            return null;
          },
        ),
      ),
    );

    // Add environment banner for non-production builds
    // ✅ FIX: Wrap Banner in Directionality since it's outside MaterialApp
    if (!AppConfig.isProduction) {
      app = Directionality(
        textDirection: TextDirection.ltr,
        child: Banner(
          message: AppConfig.isStaging ? 'STAGING' : 'DEV',
          location: BannerLocation.topEnd,
          color: AppConfig.isStaging ? Colors.orange : Colors.red,
          child: app,
        ),
      );
    }

    return app;
  }
}

// Wrapper para manejar autenticación
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final DeviceSessionService _deviceSessionService = DeviceSessionService();
  final OnlineStatusService _onlineStatusService = OnlineStatusService();

  @override
  void dispose() {
    _deviceSessionService.stopSessionListener();
    _onlineStatusService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<firebase_auth.User?>(
      stream: firebase_auth.FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        ReleaseLogger.log(
          '🔄AuthWrapper - Connection state: ${snapshot.connectionState}',
        );
        ReleaseLogger.log('🔄AuthWrapper - Has data: ${snapshot.hasData}');
        ReleaseLogger.log('🔄AuthWrapper - User: ${snapshot.data?.email}');

        // ✅ FIX: Show loading while waiting for auth state (especially important for staging)
        if (snapshot.connectionState == ConnectionState.waiting) {
          ReleaseLogger.log('⏳ AuthWrapper - Waiting for auth state...');
          return Scaffold(
            body: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    ThemeService.primaryColor,
                    Color(0xFFB39DDB),
                    Color(0xFFCE93D8),
                  ],
                ),
              ),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Iniciando...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // ✅ FIX: Handle auth stream errors gracefully
        if (snapshot.hasError) {
          ReleaseLogger.error('❌ AuthWrapper - Auth stream error: ${snapshot.error}');
          // On error, show login screen
          return AuthScreen();
        }

        // Usuario autenticado
        if (snapshot.hasData) {
          ReleaseLogger.log('✅Usuario autenticado: ${snapshot.data!.email}');

          // Registrar sesión del dispositivo y LUEGO iniciar listener
          // Es importante esperar que se registre antes de escuchar cambios
          // para evitar que el dispositivo nuevo se cierre a sí mismo
          _deviceSessionService
              .registerDeviceSession(snapshot.data!.uid)
              .then((_) {
                // Iniciar listener de sesión DESPUÉS de registrar
                // ignore: use_build_context_synchronously
                _deviceSessionService.startSessionListener(context);
              })
              .catchError((e) {
                ReleaseLogger.log(
                  '⚠️ Error registrando sesión de dispositivo: $e',
                );
                // Aún así iniciar listener para detectar otros dispositivos
                // ignore: use_build_context_synchronously
                _deviceSessionService.startSessionListener(context);
              });

          // Inicializar servicio de estado online
          _onlineStatusService.initialize();

          // SIEMPRE consultar Firestore para determinar el tipo de usuario real
          // Usar StreamBuilder para escuchar cambios en tiempo real
          return StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(snapshot.data!.uid)
                .snapshots(),
            builder: (context, userSnapshot) {
              // Si estamos esperando Y no tenemos datos cacheados, mostrar loading
              // Si tenemos datos cacheados (hasData), usar esos datos aunque estemos waiting
              if (userSnapshot.connectionState == ConnectionState.waiting &&
                  !userSnapshot.hasData) {
                return Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Verificando tipo de usuario...'),
                      ],
                    ),
                  ),
                );
              }

              if (userSnapshot.hasError) {
                ReleaseLogger.error(
                  '❌Error consultando usuario: ${userSnapshot.error}',
                );
                // Intentar obtener datos del cache local antes de mostrar error
                // Si hay datos cacheados, usarlos aunque haya error de red
                if (userSnapshot.hasData && userSnapshot.data != null) {
                  ReleaseLogger.log(
                    '⚠️ Error de red detectado, usando datos cacheados',
                  );
                  // Continuar con los datos cacheados (no hacer return aquí)
                } else {
                  // Sin cache disponible, volver a AuthScreen
                  ReleaseLogger.log(
                    '❌ Sin datos cacheados disponibles, mostrando AuthScreen',
                  );
                  return AuthScreen();
                }
              }

              if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                ReleaseLogger.log(
                  '❌ Usuario no existe en Firestore: ${snapshot.data!.uid}',
                );
                ReleaseLogger.log('   hasData: ${userSnapshot.hasData}');
                ReleaseLogger.log('   exists: ${userSnapshot.data?.exists}');
                ReleaseLogger.log(
                  '   connectionState: ${userSnapshot.connectionState}',
                );

                // Usuario autenticado pero no existe en Firestore - ir a completar perfil
                ReleaseLogger.log(
                  '📝 Mostrando ProfileCompletionScreen para completar registro',
                );
                return ProfileCompletionScreen(
                  phoneNumber: snapshot.data!.phoneNumber ?? 'Sin teléfono',
                );
              }

              final userData =
                  userSnapshot.data!.data() as Map<String, dynamic>?;

              // Verificar que userData no sea null
              if (userData == null) {
                ReleaseLogger.error('❌userData es null');
                return ProfileCompletionScreen(
                  phoneNumber: snapshot.data!.phoneNumber ?? 'Sin teléfono',
                );
              }
              final role = userData['role'] ?? 'child';
              final userEmail = snapshot.data!.email;
              final userPhone = snapshot.data!.phoneNumber;
              final userId = snapshot.data!.uid;

              ReleaseLogger.log('✅Usuario encontrado en Firestore:');
              ReleaseLogger.log('   Email: $userEmail');
              ReleaseLogger.log('   Phone: $userPhone');
              ReleaseLogger.log('   Role: $role');
              ReleaseLogger.log(
                '   🔑 Timestamp: ${DateTime.now().millisecondsSinceEpoch}',
              );

              // Verificar si tiene 2FA habilitado
              final has2FA = userData['twoFactorEnabled'] ?? false;

              if (has2FA) {
                ReleaseLogger.log('🔐Usuario tiene 2FA habilitado');

                // Verificar si ya lo verificó en esta sesión (async)
                return FutureBuilder<bool>(
                  future: TwoFactorSessionService().isVerified(userId),
                  builder: (context, verificationSnapshot) {
                    if (verificationSnapshot.connectionState ==
                        ConnectionState.waiting) {
                      return Scaffold(
                        body: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 16),
                              Text('Verificando sesión...'),
                            ],
                          ),
                        ),
                      );
                    }

                    final isVerified = verificationSnapshot.data ?? false;

                    if (!isVerified) {
                      ReleaseLogger.log(
                        '⚠️ 2FA no verificado en esta sesión, mostrando pantalla de verificación',
                      );
                      return TwoFactorVerificationScreen(
                        userId: userId,
                        role: role,
                      );
                    }

                    ReleaseLogger.log('✅2FA ya verificado en esta sesión');

                    // Usuario verificado, continuar con navegación normal
                    if (role == 'parent') {
                      ReleaseLogger.log('👔 Redirigiendo a ParentMainShell');
                      return ParentMainShell(key: ParentMainShell.shellKey);
                    } else {
                      ReleaseLogger.log(
                        '👶 Redirigiendo a ChildMainShell (role: $role)',
                      );
                      return ChildMainShell(key: ChildMainShell.shellKey);
                    }
                  },
                );
              } else {
                ReleaseLogger.log('ℹ️Usuario NO tiene 2FA habilitado');
              }

              // Redirigir según el rol: solo 'parent' va a ParentMainShell, el resto va a ChildMainShell
              if (role == 'parent') {
                ReleaseLogger.log('👔 Redirigiendo a ParentMainShell');
                return ParentMainShell(key: ParentMainShell.shellKey);
              } else {
                ReleaseLogger.log(
                  '👶 Redirigiendo a ChildMainShell (role: $role)',
                );
                return ChildMainShell(key: ChildMainShell.shellKey);
              }
            },
          );
        }

        // No autenticado - mostrar pantalla de login
        ReleaseLogger.error('❌Usuario no autenticado');
        ReleaseLogger.log('🔑Mostrando pantalla de autenticación');
        return AuthScreen();
      },
    );
  }
}
