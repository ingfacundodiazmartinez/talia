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
import 'screens/chat_moderation_settings_screen.dart';
import 'screens/parent/chat_moderation_management_screen.dart';
import 'screens/splash_wrapper.dart';
import 'notification_service.dart';
import 'theme_service.dart';
import 'services/two_factor_session_service.dart';
import 'services/app_config_service.dart';
import 'services/message_cache_service.dart';
import 'services/dashboard_cache_service.dart';
import 'services/device_session_service.dart';
import 'services/online_status_service.dart';
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
import 'services/unread_messages_service.dart';
import 'services/ad_service.dart';
import 'services/story_service_refactored.dart';
import 'services/contact_photo_cache_service.dart';
import 'services/deep_link_service.dart';
import 'dart:async';
import 'utils/release_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

// IMPORTANTE: Después de ejecutar 'flutterfire configure',
// descomenta la siguiente línea:
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // Inicializar MessageCacheService primero (llama Hive.initFlutter())
  try {
    await MessageCacheService().initialize();
    ReleaseLogger.log('✅ MessageCacheService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error(
      '❌ Error inicializando MessageCacheService: $e',
      tag: 'MainApp',
    );
  }

  // Inicializar Firebase solo si no está inicializado
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    ReleaseLogger.log('✅ Firebase inicializado', tag: 'MainApp');
  } else {
    ReleaseLogger.log('✅ Firebase ya estaba inicializado', tag: 'MainApp');
  }

  // 🚨 CRITICAL: Registrar background handler DESPUÉS de Firebase.initializeApp
  // ANTES de runApp() para que funcione correctamente
  //
  // PROBLEMA RESUELTO: Los handlers FCM no se ejecutaban porque estaban registrados
  // dentro de NotificationService.initialize(), pero Flutter requiere que se registren
  // aquí en main.dart para el manejo correcto de notificaciones en background.
  //
  // SOLUCIÓN: firebaseMessagingBackgroundHandler ahora está definido como función
  // top-level en notification_service.dart con @pragma('vm:entry-point')
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  ReleaseLogger.log(
    '✅ Background message handler registrado en main.dart',
    tag: 'MainApp',
  );

  // Ahora DashboardCacheService puede usar Hive Y Firebase (remote logger)
  try {
    await DashboardCacheService().initialize();
    ReleaseLogger.log('✅ DashboardCacheService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error(
      '❌ Error inicializando DashboardCacheService: $e',
      tag: 'MainApp',
    );
  }

  // ✅ Inicializar LocalUnreadCountService para contadores de mensajes no leídos
  try {
    await LocalUnreadCountService().initialize();
    ReleaseLogger.log('✅ LocalUnreadCountService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error(
      '❌ Error inicializando LocalUnreadCountService: $e',
      tag: 'MainApp',
    );
  }

  // 📱 CRÍTICO: Inicializar AppStateService para detectar foreground/background
  // Esto es esencial para manejar correctamente las notificaciones de videollamadas
  try {
    AppStateService().initialize();
    ReleaseLogger.log('✅ AppStateService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error(
      '❌ Error inicializando AppStateService: $e',
      tag: 'MainApp',
    );
  }

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
      await StoryService().startBackgroundCacheUpdates();
      ReleaseLogger.log(
        'StoryService inicializado manualmente',
        tag: 'MainApp',
      );
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
  if (kDebugMode) {
    // Deshabilitar Crashlytics en modo debug para no contaminar reportes
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    ReleaseLogger.log(
      '🐛 Crashlytics DESHABILITADO en modo debug',
      tag: 'MainApp',
    );
  } else {
    // Habilitar Crashlytics en producción
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
    ReleaseLogger.log(
      '📊 Crashlytics HABILITADO en producción',
      tag: 'MainApp',
    );
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
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    ReleaseLogger.error('Error asíncrono capturado: $error', tag: 'MainApp');
    ReleaseLogger.error('Stack trace: $stack', tag: 'MainApp');
    return true;
  };

  ReleaseLogger.log('✅ Crashlytics configurado', tag: 'MainApp');

  // 🚀 PERFORMANCE OPTIMIZATION: Paralelizar servicios independientes post-Firebase
  ReleaseLogger.log(
    '🚀 Inicializando servicios principales en paralelo...',
    tag: 'MainApp',
  );
  await Future.wait([
    // Grupo 1: Firebase Services
    AnalyticsService()
        .initialize()
        .then((_) {
          ReleaseLogger.log('✅ Analytics inicializado', tag: 'MainApp');
        })
        .catchError((e) {
          ReleaseLogger.error(
            '⚠️ Error inicializando Analytics: $e (continuando...)',
            tag: 'MainApp',
          );
        }),

    PerformanceService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ Performance Monitoring inicializado',
            tag: 'MainApp',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '⚠️ Error inicializando Performance: $e (continuando...)',
            tag: 'MainApp',
          );
        }),

    // Grupo 2: Network & Queue Services
    NetworkStatusService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ Network Status Service inicializado',
            tag: 'MainApp',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '⚠️ Error inicializando Network Status: $e (continuando...)',
            tag: 'MainApp',
          );
        }),

    OfflineQueueService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ Offline Queue Service inicializado',
            tag: 'MainApp',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '⚠️ Error inicializando Offline Queue: $e (continuando...)',
            tag: 'MainApp',
          );
        }),

    // Grupo 3: Independent Services
    AccessibilityService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ Accessibility Service inicializado',
            tag: 'MainApp',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '⚠️ Error inicializando Accessibility: $e (continuando...)',
            tag: 'MainApp',
          );
        }),

    AdService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ AdMob inicializado con cumplimiento COPPA',
            tag: 'MainApp',
          );
        })
        .catchError((e) {
          ReleaseLogger.error(
            '⚠️ Error inicializando AdMob: $e (continuando...)',
            tag: 'MainApp',
          );
        }),
  ]);
  ReleaseLogger.log(
    '✅ Servicios principales inicializados concurrentemente',
    tag: 'MainApp',
  );

  // Pre-cargar stickers en segundo plano (sin bloquear la app)
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

  // Activar Firebase App Check con Play Integrity para producción
  if (kDebugMode) {
    // En modo debug, usar debug provider para emuladores
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
      webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    );
    ReleaseLogger.log('🐛Firebase App Check activado con DEBUG provider');

    // Obtener y mostrar el debug token para registrarlo en Firebase Console
    // En Android debug, el token se genera automáticamente por el debug provider
    // OPTIMIZACIÓN: Eliminar delay artificial de 2 segundos en main thread

    try {
      final token = await FirebaseAppCheck.instance.getToken();
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
    // En producción, usar Play Integrity y Device Check
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.playIntegrity,
      appleProvider: AppleProvider.deviceCheck,
      webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    );
    ReleaseLogger.log(
      '✅Firebase App Check activado con Play Integrity y Device Check',
    );
  }

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

  await Future.wait([
    AppConfigService()
        .initialize()
        .then((_) {
          ReleaseLogger.log(
            '✅ App Config Service inicializado',
            tag: 'MainApp',
          );
        })
        .catchError((e) {
          ReleaseLogger.log(
            '⚠️ Error inicializando App Config: $e (continuando con valores por defecto)',
            tag: 'MainApp',
          );
        }),

    () async {
      themeService = ThemeService();
      await themeService.initialize();
      ReleaseLogger.log('✅ ThemeService inicializado', tag: 'MainApp');
    }(),
  ]);
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
  try {
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      final prefs = await SharedPreferences.getInstance();
      final messageId = initialMessage.data['messageId'] ?? initialMessage.data['id'];

      // Save messageId for deduplication
      if (messageId != null) {
        await prefs.setString('tapped_notification_message_id', messageId);
        await prefs.setInt('tapped_notification_timestamp', DateTime.now().millisecondsSinceEpoch);
        ReleaseLogger.log(
          '✅ [Dedup] App abierta desde notificación (killed) - messageId guardado: $messageId',
          tag: 'MainApp',
        );
      }

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
                    'Token (primeros 20): ${voipToken.length > 20 ? voipToken.substring(0, 20) + '...' : voipToken}',
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

class TaliaApp extends StatefulWidget {
  const TaliaApp({super.key});

  @override
  State<TaliaApp> createState() => _TaliaAppState();
}

class _TaliaAppState extends State<TaliaApp> with WidgetsBindingObserver {
  StreamSubscription<DocumentSnapshot>? _userRoleSubscription;
  StreamSubscription<firebase_auth.User?>?
  _authSubscription; // ✅ NUEVO: listener auth independiente
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
  }

  /// Initialize V2 Agora call system (legacy system removed)
  Future<void> _initializeCallSystem() async {
    ReleaseLogger.log(
      '🚀 [Main] Initializing V2 Agora call system (VoIP/CallKit only)',
      tag: 'Main',
    );

    // V2 NAVIGATION: Shared navigation callback for both iOS and Android
    final navigateToCall = (String callId, {bool isIncoming = false}) {
      ReleaseLogger.log(
        '🚀 [Main] Navigating to AgoraCallScreen: $callId (incoming: $isIncoming)',
        tag: 'Main',
      );

      // Navigate using CallServiceWrapper which returns AgoraCallScreen for V2
      final callScreen = CallServiceWrapper().getCallScreen(
        callId: callId,
        isIncoming: isIncoming,
      );

      _navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => callScreen,
        ),
      );

      ReleaseLogger.log('✅ [Main] Navigation to AgoraCallScreen completed', tag: 'Main');
    };

    // Configure iOS path (VoIPService)
    VoIPService().onNavigateToCall = navigateToCall;

    // Configure Android path (NotificationService)
    NotificationService().onNavigateToCall = navigateToCall;

    ReleaseLogger.log(
      '✅ [Main] V2 navigation callbacks configured for both platforms',
      tag: 'Main',
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _userRoleSubscription?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // ✅ FIX: Notificar a NotificationService cuando la app vuelve a foreground
    // Esto evita que las notificaciones de background se muestren como foreground
    if (state == AppLifecycleState.resumed) {
      NotificationService().notifyAppResumed();

      // Sincronizar permisos para usuarios hijo
      if (_currentUserRole == 'child') {
        PermissionSyncService().syncPermissions();
      }
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

        // Inicializar stream background de historias
        ReleaseLogger.log('📱Iniciando stream background de historias...');
        StoryService()
            .startBackgroundCacheUpdates()
            .then((_) {
              ReleaseLogger.log('✅Stream background de historias iniciado');
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

    return GestureDetector(
      onTap: () {
        // Cerrar teclado al tocar fuera de cualquier input
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: NetworkStatusBanner(
        child: MaterialApp(
          key: ValueKey('app_${_currentUserRole ?? "unknown"}'),
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: SnackbarService().scaffoldMessengerKey,
          title: 'Talia',
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
                  if (mediaQueryData == null) {
                    return child!;
                  }
                  return MediaQuery(
                    data: mediaQueryData.copyWith(
                      textScaler: TextScaler.linear(accessibility.textScale),
                    ),
                    child: child!,
                  );
                },
              ),
            );
          },
          home: const SplashWrapper(nextScreen: AuthWrapper()),
          onGenerateRoute: (settings) {
            if (settings.name == '/chat_moderation_settings') {
              final args = settings.arguments as Map<String, dynamic>;
              return MaterialPageRoute(
                builder: (context) => ChatModerationSettingsScreen(
                  chatId: args['chatId'] as String,
                  contactName: args['contactName'] as String,
                ),
              );
            }
            if (settings.name == '/chat_moderation_management') {
              return MaterialPageRoute(
                builder: (context) => const ChatModerationManagementScreen(),
              );
            }
            return null;
          },
        ),
      ),
    );
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
                _deviceSessionService.startSessionListener(context);
              })
              .catchError((e) {
                ReleaseLogger.log(
                  '⚠️ Error registrando sesión de dispositivo: $e',
                );
                // Aún así iniciar listener para detectar otros dispositivos
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
                      return ParentMainShell();
                    } else {
                      ReleaseLogger.log(
                        '👶 Redirigiendo a ChildMainShell (role: $role)',
                      );
                      return ChildMainShell();
                    }
                  },
                );
              } else {
                ReleaseLogger.log('ℹ️Usuario NO tiene 2FA habilitado');
              }

              // Redirigir según el rol: solo 'parent' va a ParentMainShell, el resto va a ChildMainShell
              if (role == 'parent') {
                ReleaseLogger.log('👔 Redirigiendo a ParentMainShell');
                return ParentMainShell();
              } else {
                ReleaseLogger.log(
                  '👶 Redirigiendo a ChildMainShell (role: $role)',
                );
                return ChildMainShell();
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
