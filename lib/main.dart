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
import 'screens/audio_call_screen.dart';
import 'screens/video_call_screen.dart';
import 'screens/animated_splash_screen.dart';
import 'screens/splash_wrapper.dart';
import 'notification_service.dart';
import 'theme_service.dart';
import 'services/callkit_service.dart';
import 'services/video_call_service.dart';
import 'services/two_factor_session_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'services/app_config_service.dart';
import 'services/message_cache_service.dart';
import 'services/dashboard_cache_service.dart';
import 'services/device_session_service.dart';
import 'services/online_status_service.dart';
import 'services/screenshot_protection_service.dart';
import 'services/voip_service.dart';
import 'services/analytics_service.dart';
import 'services/performance_service.dart';
import 'services/snackbar_service.dart';
import 'services/network_status_service.dart';
import 'services/offline_queue_service.dart';
import 'services/accessibility_service.dart';
import 'services/foreground_message_listener.dart';
import 'services/stickers_service.dart';
import 'services/unread_messages_service.dart';
import 'services/ad_service.dart';
import 'services/story_service.dart';
import 'dart:async';
import 'utils/release_logger.dart';

// IMPORTANTE: Después de ejecutar 'flutterfire configure',
// descomenta la siguiente línea:
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔍 DEBUGGING: Activar logging detallado de rebuilds (solo en debug)
  if (kDebugMode) {
    debugPrintRebuildDirtyWidgets = true;
    print('🔍 REBUILD DEBUGGING ACTIVADO - Veremos todos los rebuilds en logs');
  }

  // Bloquear rotación de pantalla - solo permitir portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  ReleaseLogger.log('📱 Rotación de pantalla bloqueada a portrait', tag: 'MainApp');

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

  ReleaseLogger.log('🚀 Iniciando aplicación Talia...', tag: 'MainApp');

  // 🚀 CACHE INITIALIZATION: MessageCacheService primero (inicializa Hive)
  ReleaseLogger.log('🚀 Inicializando MessageCacheService...', tag: 'MainApp');

  // Inicializar MessageCacheService primero (llama Hive.initFlutter())
  try {
    await MessageCacheService().initialize();
    ReleaseLogger.log('✅ MessageCacheService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error('❌ Error inicializando MessageCacheService: $e', tag: 'MainApp');
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

  // Ahora DashboardCacheService puede usar Hive Y Firebase (remote logger)
  try {
    await DashboardCacheService().initialize();
    ReleaseLogger.log('✅ DashboardCacheService inicializado', tag: 'MainApp');
  } catch (e) {
    ReleaseLogger.error('❌ Error inicializando DashboardCacheService: $e', tag: 'MainApp');
  }

  // Configurar Crashlytics
  if (kDebugMode) {
    // Deshabilitar Crashlytics en modo debug para no contaminar reportes
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    ReleaseLogger.log('🐛 Crashlytics DESHABILITADO en modo debug', tag: 'MainApp');
  } else {
    // Habilitar Crashlytics en producción
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
    ReleaseLogger.log('📊 Crashlytics HABILITADO en producción', tag: 'MainApp');
  }

  // Capturar errores de Flutter framework
  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
    ReleaseLogger.error('❌ Flutter error capturado: ${errorDetails.exception}', tag: 'MainApp');
    ReleaseLogger.error('📍 Stack trace: ${errorDetails.stack}', tag: 'MainApp');
    print('🔍 FLUTTER ERROR DEBUG:');
    print('   Exception: ${errorDetails.exception}');
    print('   Library: ${errorDetails.library}');
    print('   Context: ${errorDetails.context}');
    print('   Stack trace: ${errorDetails.stack}');
    print('🔍 END FLUTTER ERROR DEBUG');
  };

  // Capturar errores asíncronos fuera del framework Flutter
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    ReleaseLogger.error('❌ Error asíncrono capturado: $error', tag: 'MainApp');
    ReleaseLogger.error('📍 Stack trace: $stack', tag: 'MainApp');
    print('🔍 ASYNC ERROR DEBUG:');
    print('   Error: $error');
    print('   Stack trace: $stack');
    print('🔍 END ASYNC ERROR DEBUG');
    return true;
  };

  ReleaseLogger.log('✅ Crashlytics configurado', tag: 'MainApp');

  // 🚀 PERFORMANCE OPTIMIZATION: Paralelizar servicios independientes post-Firebase
  ReleaseLogger.log('🚀 Inicializando servicios principales en paralelo...', tag: 'MainApp');
  await Future.wait([
    // Grupo 1: Firebase Services
    AnalyticsService().initialize().then((_) {
      ReleaseLogger.log('✅ Analytics inicializado', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.error('⚠️ Error inicializando Analytics: $e (continuando...)', tag: 'MainApp');
    }),

    PerformanceService().initialize().then((_) {
      ReleaseLogger.log('✅ Performance Monitoring inicializado', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.error('⚠️ Error inicializando Performance: $e (continuando...)', tag: 'MainApp');
    }),

    // Grupo 2: Network & Queue Services
    NetworkStatusService().initialize().then((_) {
      ReleaseLogger.log('✅ Network Status Service inicializado', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.error('⚠️ Error inicializando Network Status: $e (continuando...)', tag: 'MainApp');
    }),

    OfflineQueueService().initialize().then((_) {
      ReleaseLogger.log('✅ Offline Queue Service inicializado', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.error('⚠️ Error inicializando Offline Queue: $e (continuando...)', tag: 'MainApp');
    }),

    // Grupo 3: Independent Services
    AccessibilityService().initialize().then((_) {
      ReleaseLogger.log('✅ Accessibility Service inicializado', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.error('⚠️ Error inicializando Accessibility: $e (continuando...)', tag: 'MainApp');
    }),

    AdService().initialize().then((_) {
      ReleaseLogger.log('✅ AdMob inicializado con cumplimiento COPPA', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.error('⚠️ Error inicializando AdMob: $e (continuando...)', tag: 'MainApp');
    }),
  ]);
  ReleaseLogger.log('✅ Servicios principales inicializados concurrentemente', tag: 'MainApp');

  // Pre-cargar stickers en segundo plano (sin bloquear la app)
  StickersService()
      .preloadStickers()
      .then((_) {
        ReleaseLogger.log('✅Stickers pre-cargados en segundo plano');
      })
      .catchError((e) {
        ReleaseLogger.log('⚠️ Error pre-cargando stickers: $e (continuando...)');
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
        ReleaseLogger.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', tag: 'MainApp');
        ReleaseLogger.log('   $token', tag: 'MainApp');
        ReleaseLogger.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', tag: 'MainApp');
        ReleaseLogger.log('📋Copia este token y regístralo en:');
        ReleaseLogger.log('   Firebase Console → App Check → Apps → Manage debug tokens');
        ReleaseLogger.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', tag: 'MainApp');
      } else {
        ReleaseLogger.log('⚠️ No se pudo obtener debug token (token es null o vacío)');
        ReleaseLogger.log('💡En algunos casos, el token se genera en logcat de Android');
        ReleaseLogger.log('   Busca en logcat: "DebugAppCheckProvider"');
      }
    } catch (e) {
      ReleaseLogger.log('⚠️ No se pudo obtener debug token: $e');
      ReleaseLogger.log('💡El token de debug se puede encontrar en logcat de Android');
      ReleaseLogger.log('   Busca: "DebugAppCheckProvider" o "AppCheckDebugProvider"');
    }
  } else {
    // En producción, usar Play Integrity y Device Check
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.playIntegrity,
      appleProvider: AppleProvider.deviceCheck,
      webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    );
    ReleaseLogger.log('✅Firebase App Check activado con Play Integrity y Device Check');
  }

  // Habilitar persistencia offline de Firestore para caché local
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  ReleaseLogger.log('💾Persistencia offline de Firestore habilitada');

  // 🚀 PERFORMANCE OPTIMIZATION: AppConfig puede inicializar concurrentemente con ThemeService
  ReleaseLogger.log('🚀 Inicializando configuración final en paralelo...', tag: 'MainApp');
  late ThemeService themeService;

  await Future.wait([
    AppConfigService().initialize().then((_) {
      ReleaseLogger.log('✅ App Config Service inicializado', tag: 'MainApp');
    }).catchError((e) {
      ReleaseLogger.log('⚠️ Error inicializando App Config: $e (continuando con valores por defecto)', tag: 'MainApp');
    }),

    () async {
      themeService = ThemeService();
      await themeService.initialize();
      ReleaseLogger.log('✅ ThemeService inicializado', tag: 'MainApp');
    }(),
  ]);
  ReleaseLogger.log('✅ Configuración final completada concurrentemente', tag: 'MainApp');

  // 🚀 PERFORMANCE OPTIMIZATION: Diferir servicios pesados para después de runApp()
  // Esto permite que la UI se renderice primero, mejorando perceived performance

  ReleaseLogger.log('🎯 Configuración crítica completada - iniciando UI...', tag: 'MainApp');

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
  ReleaseLogger.log('🚀 Inicializando servicios pesados en background...', tag: 'BackgroundInit');

  // Paralelizar servicios pesados para máximo performance
  await Future.wait([
    // Notification Service (FCM setup)
    NotificationService().initialize().then((_) {
      ReleaseLogger.log('✅ NotificationService inicializado en background', tag: 'BackgroundInit');
    }).catchError((e) {
      ReleaseLogger.error('❌ Error inicializando NotificationService: $e', tag: 'BackgroundInit');
    }),

    // VoIP Service (solo iOS, para llamadas)
    () async {
      if (Platform.isIOS) {
        try {
          await VoIPService().initialize();
          ReleaseLogger.log('✅ VoIP Service inicializado en background (iOS)', tag: 'BackgroundInit');
        } catch (e) {
          ReleaseLogger.error('❌ Error inicializando VoIP Service: $e', tag: 'BackgroundInit');
        }
      }
    }(),

    // APNs Token (solo iOS, para Phone Auth)
    () async {
      if (Platform.isIOS) {
        try {
          final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
          if (apnsToken != null) {
            ReleaseLogger.log('✅ APNs token obtenido en background: ${apnsToken.substring(0, 20)}...', tag: 'BackgroundInit');
          } else {
            ReleaseLogger.log('⚠️ APNs token no disponible - configurando listener', tag: 'BackgroundInit');
            FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
              ReleaseLogger.log('✅ APNs token actualizado en background', tag: 'BackgroundInit');
            });
          }
        } catch (e) {
          ReleaseLogger.error('❌ Error obteniendo APNs token: $e', tag: 'BackgroundInit');
        }
      }
    }(),
  ]);

  ReleaseLogger.log('✅ Servicios pesados inicializados completamente en background', tag: 'BackgroundInit');
}

class TaliaApp extends StatefulWidget {
  const TaliaApp({super.key});

  @override
  State<TaliaApp> createState() => _TaliaAppState();
}

class _TaliaAppState extends State<TaliaApp> with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? _incomingCallSubscription;
  StreamSubscription<DocumentSnapshot>? _userRoleSubscription;
  StreamSubscription<Map<String, dynamic>>? _pendingCallSubscription;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  String? _currentUserRole;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupIncomingCallListener();
    _setupRoleListener();
    _setupPendingCallListener(); // Escuchar llamadas pendientes de VoIP
    _checkPendingCall(); // Verificar llamadas pendientes al iniciar
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingCallSubscription?.cancel();
    _userRoleSubscription?.cancel();
    _pendingCallSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ReleaseLogger.log('📱App resumed from background');

      // App regresó de background, verificar llamadas pendientes
      _checkPendingCall();

      // Marcar en ForegroundMessageListener que la app volvió del background
      // Esto suprime banners custom por unos segundos para evitar mostrar notificaciones
      // cuando el usuario abre la app manualmente después de recibir notificaciones
      ForegroundMessageListener().markAppResumedFromBackground();

      // ℹ️ Firestore maneja automáticamente la reconexión cuando la app se reanuda.
      // NO forzar disableNetwork/enableNetwork porque cancela todos los StreamBuilders
      // activos y causa que la UI se quede en loading infinito.
      ReleaseLogger.log('✅Firestore se reconectará automáticamente');
    }
  }

  /// Escuchar stream de llamadas pendientes de VoIP
  void _setupPendingCallListener() {
    if (!Platform.isIOS) return;

    _pendingCallSubscription = VoIPService().pendingCallStream.listen((
      callData,
    ) {
      ReleaseLogger.log('📞[Main] Llamada pendiente recibida del stream: $callData');
      _navigateToCall(callData);
    });
  }

  Future<void> _checkPendingCall() async {
    if (!Platform.isIOS) return;

    await Future.delayed(
      const Duration(milliseconds: 500),
    ); // Pequeño delay para que Flutter esté listo

    final pendingData = VoIPService().getPendingCallData();
    if (pendingData != null) {
      ReleaseLogger.log('📞[Main] Llamada pendiente detectada: $pendingData');
      _navigateToCall(pendingData);
    }
  }

  void _navigateToCall(Map<String, dynamic> callData) {
    final callId = callData['callId'] as String;
    final channelName = callData['channelName'] as String;
    final token = callData['token'] as String;
    final uid = callData['uid'] as int;
    final callType = callData['callType'] as String?;
    final callerName = callData['callerName'] as String;
    final callerId = callData['callerId'] as String? ?? '';

    final isAudioCall = callType == 'audio';

    ReleaseLogger.log('🚀[Main] Navegando a pantalla de llamada:');
    ReleaseLogger.log('   -Call ID: $callId');
    ReleaseLogger.log('   -Channel: $channelName');
    ReleaseLogger.log('   -Type: $callType');
    ReleaseLogger.log('   -Is Audio: $isAudioCall');
    ReleaseLogger.log('   -UID: $uid');

    if (_navigatorKey.currentContext != null) {
      if (isAudioCall) {
        // Navegar a AudioCallScreen para llamadas de audio
        ReleaseLogger.log('📞[Main] Navegando a AudioCallScreen');
        Navigator.of(_navigatorKey.currentContext!).push(
          MaterialPageRoute(
            builder: (context) => AudioCallScreen(
              callId: callId,
              channelName: channelName,
              token: token,
              uid: uid,
              isCaller: false, // Estamos recibiendo la llamada
              remoteName: callerName,
            ),
          ),
        );
      } else {
        // Navegar a VideoCallScreen para llamadas de video
        ReleaseLogger.log('📹[Main] Navegando a VideoCallScreen');
        Navigator.of(_navigatorKey.currentContext!).push(
          MaterialPageRoute(
            builder: (context) => VideoCallScreen(
              callId: callId,
              channelName: channelName,
              token: token,
              uid: uid,
              isCaller: false, // Estamos recibiendo la llamada
              remoteName: callerName,
              receiverId: callerId, // ID del que llama
              isVideo: true,
            ),
          ),
        );
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

        // Inicializar ForegroundMessageListener para notificaciones en tiempo real
        ReleaseLogger.log('🔔Inicializando ForegroundMessageListener...');
        ForegroundMessageListener().initialize(_navigatorKey);
        ReleaseLogger.log('✅ForegroundMessageListener inicializado');

        // Inicializar protección de screenshots
        ReleaseLogger.log('📸 Inicializando ScreenshotProtectionService...');
        ScreenshotProtectionService().initialize();
        ReleaseLogger.log('✅ScreenshotProtectionService inicializado');

        // Inicializar listener de badge del ícono
        ReleaseLogger.log('🔔Inicializando badge listener...');
        UnreadMessagesService().startBadgeListener();
        ReleaseLogger.log('✅Badge listener inicializado');

        // Inicializar stream background de historias
        ReleaseLogger.log('📱Iniciando stream background de historias...');
        StoryService().startBackgroundCacheUpdates().then((_) {
          ReleaseLogger.log('✅Stream background de historias iniciado');
        }).catchError((e) {
          ReleaseLogger.log('⚠️ Error iniciando stream background de historias: $e');
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
                ReleaseLogger.log('🔍Role guardado en memoria: $_currentUserRole');

                if (_currentUserRole != null && _currentUserRole != newRole) {
                  ReleaseLogger.log(
                    '🔄 Role cambió de $_currentUserRole a $newRole - Reconstruyendo navegación',
                  );

                  // Actualizar role primero
                  _currentUserRole = newRole;

                  // Forzar reconexión de Firestore para obtener datos frescos sin cache
                  ReleaseLogger.log('🔄Forzando reconexión de Firestore para limpiar cache...');
                  FirebaseFirestore.instance.disableNetwork().then((_) {
                    ReleaseLogger.log('✅Firestore desconectado');
                    return Future.delayed(Duration(milliseconds: 200));
                  }).then((_) {
                    return FirebaseFirestore.instance.enableNetwork();
                  }).then((_) {
                    ReleaseLogger.log('✅Firestore reconectado con datos frescos');

                    // Navegar después de que Firestore esté listo
                    Future.delayed(Duration(milliseconds: 100), () {
                      final navigator = _navigatorKey.currentState;
                      if (navigator != null && navigator.mounted) {
                        ReleaseLogger.log('✅Navegando a AuthWrapper con nuevo rol: $newRole');
                        navigator.pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const AuthWrapper()),
                          (route) => false,
                        );
                      } else {
                        ReleaseLogger.log('⚠️ Navigator no disponible para navegación');
                      }
                    });
                  }).catchError((error) {
                    ReleaseLogger.log('⚠️ Error reconectando Firestore: $error');
                    // Intentar navegar de todos modos
                    Future.delayed(Duration(milliseconds: 100), () {
                      final navigator = _navigatorKey.currentState;
                      if (navigator != null && navigator.mounted) {
                        ReleaseLogger.log('⚠️ Navegando a AuthWrapper a pesar del error');
                        navigator.pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const AuthWrapper()),
                          (route) => false,
                        );
                      }
                    });
                  });
                } else if (_currentUserRole == null) {
                  ReleaseLogger.log('ℹ️Inicializando role por primera vez: $newRole');
                  _currentUserRole = newRole;
                }
              }
            });
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

  void _setupIncomingCallListener() {
    _incomingCallSubscription = NotificationService().incomingCallStream.listen((
      callData,
    ) async {
      // Usar callType directamente de los datos de la notificación
      final callType = callData['callType'] ?? 'video';
      final isAudioCall = callType == 'audio';

      final isEmergency = callData['isEmergency'] == true;

      ReleaseLogger.log(
        '📞 ${isAudioCall ? 'Llamada de audio' : 'Videollamada'} entrante recibida en main.dart',
      );
      ReleaseLogger.log('📦 Datos completos: $callData');
      ReleaseLogger.log(
        '📦 channelName: "${callData['channelName']}" (null? ${callData['channelName'] == null})',
      );
      if (isEmergency) {
        ReleaseLogger.log('🆘 Es una llamada de EMERGENCIA');
      }

      // En iOS, usar CallKit nativo directamente (no el diálogo de Flutter)
      // Esto evita duplicación con VoIP push que puede llegar después
      if (Platform.isIOS) {
        ReleaseLogger.log(
          '📱 [iOS] Procesando llamada - usando CallKit nativo para evitar duplicación',
        );

        final callId = callData['callId'] ?? '';

        // Importar CallKitService
        final callKit = CallKitService();

        // Mostrar CallKit usando el método nativo
        await callKit.showIncomingCall(
          callId: callId,
          callerName: callData['callerName'] ?? 'Usuario desconocido',
          callerId: callData['callerId'] ?? '',
          callerPhotoUrl: callData['callerPhotoURL'],
          callType: callType,
          isEmergency: isEmergency,
          extraData: callData,
        );

        ReleaseLogger.log('✅[iOS] CallKit mostrado desde FCM foreground notification');

        // IMPORTANTE: Configurar listener para detectar si la llamada es cancelada
        // Esto maneja el caso donde la llamada se cancela antes de que el listener
        // del controller se configure (race condition)
        ReleaseLogger.log('👂[iOS] Configurando listener de cancelación para callId: $callId');
        final cancelListener = FirebaseFirestore.instance
            .collection('video_calls')
            .doc(callId)
            .snapshots()
            .listen((snapshot) {
          if (!snapshot.exists) {
            ReleaseLogger.log('📵 [iOS-main] Documento $callId eliminado - cerrando CallKit');
            callKit.endCall(callId);
            return;
          }

          final data = snapshot.data() as Map<String, dynamic>?;
          final status = data?['status'];

          if (status == 'cancelled') {
            ReleaseLogger.log('📵 [iOS-main] Llamada $callId cancelada - cerrando CallKit');
            // Usar el method channel nativo en lugar del plugin para evitar reinicio
            VoIPService().notifyCallEnded(callId);
          } else if (status == 'accepted' || status == 'active' || status == 'ended') {
            ReleaseLogger.log('ℹ️[iOS-main] Llamada $callId en status $status - listener se limpiará automáticamente');
          }
        });

        // Cancelar el listener después de 60 segundos (timeout de llamada)
        Future.delayed(Duration(seconds: 60), () {
          cancelListener.cancel();
          ReleaseLogger.log('🧹 [iOS-main] Listener de cancelación limpiado por timeout');
        });

        return; // No continuar con el diálogo de Flutter
      }

      // ANDROID: Determinar si la llamada fue aceptada desde CallKit en background
      // o si es una llamada entrante en foreground que debe mostrar el diálogo

      // Si la llamada viene de CallKit acceptance (background), debe incluir 'id' en lugar de 'callId'
      // porque flutter_callkit_incoming usa 'id' como key
      final hasId = callData.containsKey('id');
      final hasFromFirestore = callData.containsKey('fromFirestore');
      final hasFromNotificationTap = callData.containsKey('fromNotificationTap');
      final isFromCallKitAcceptance = hasId && !hasFromFirestore && !hasFromNotificationTap;

      ReleaseLogger.log('🔍Detectando origen del evento:');
      ReleaseLogger.log('   hasId: $hasId');
      ReleaseLogger.log('   hasFromFirestore: $hasFromFirestore');
      ReleaseLogger.log('   hasFromNotificationTap: $hasFromNotificationTap');
      ReleaseLogger.log('   isFromCallKitAcceptance: $isFromCallKitAcceptance');

      if (isFromCallKitAcceptance) {
        // Usuario aceptó desde CallKit en background - navegar directamente a VideoCallScreen
        ReleaseLogger.log('✅Llamada aceptada desde CallKit en background - generando token y navegando a videollamada');

        // IMPORTANTE: Si la app está en background, puede que el contexto aún no esté disponible
        // Esperar hasta que esté listo (máximo 5 segundos)
        BuildContext? context = _navigatorKey.currentContext;
        if (context == null) {
          ReleaseLogger.log('⏳ Contexto no disponible, esperando a que la app inicialice...');
          for (int i = 0; i < 50; i++) {
            await Future.delayed(const Duration(milliseconds: 100));
            context = _navigatorKey.currentContext;
            if (context != null) {
              ReleaseLogger.log('✅Contexto disponible después de ${(i + 1) * 100}ms');
              break;
            }
          }
        }

        if (context == null) {
          ReleaseLogger.error('❌No se pudo obtener el contexto del navegador después de 5 segundos');
          return;
        }

        // Extraer datos del callData (que vienen del extraData de CallKit)
        final callId = callData['id'] as String?;

        // channelName está en extra, no en el root
        // Convertir extra de Map<Object?, Object?> a Map<String, dynamic>
        final extraRaw = callData['extra'];
        final extra = extraRaw != null ? Map<String, dynamic>.from(extraRaw as Map) : null;
        final channelName = extra?['channelName'] as String? ?? callData['channelName'] as String?;
        final callerId = extra?['callerId'] as String? ?? callData['number'] as String? ?? callData['callerId'] as String?;
        final callerName = callData['nameCaller'] as String? ?? extra?['callerName'] as String? ?? 'Usuario desconocido';

        if (callId == null || channelName == null || callerId == null) {
          ReleaseLogger.error('❌Datos incompletos en callData de CallKit:');
          ReleaseLogger.log('   callId=$callId');
          ReleaseLogger.log('   channelName=$channelName');
          ReleaseLogger.log('   callerId=$callerId');
          ReleaseLogger.log('   extra=$extra');
          return;
        }

        // Obtener callType desde Firestore si no está en extra
        String callType = extra?['callType'] as String? ?? callData['type'] as String? ?? 'video';

        // Si callType no está en los datos de CallKit, consultar Firestore
        if (callType == 'video' && (extra?['callType'] == null && callData['type'] == null)) {
          ReleaseLogger.log('⚠️ callType no encontrado en CallKit data, consultando Firestore...');
          try {
            final callDoc = await FirebaseFirestore.instance
                .collection('video_calls')
                .doc(callId)
                .get();
            if (callDoc.exists) {
              callType = callDoc.data()?['callType'] as String? ?? 'video';
              ReleaseLogger.log('✅callType obtenido de Firestore: $callType');
            }
          } catch (e) {
            ReleaseLogger.log('⚠️ Error obteniendo callType de Firestore: $e');
            // Mantener 'video' como default
          }
        }

        ReleaseLogger.log('📞Procesando aceptación de CallKit:');
        ReleaseLogger.log('   callId: $callId');
        ReleaseLogger.log('   channelName: $channelName');
        ReleaseLogger.log('   callerId: $callerId');
        ReleaseLogger.log('   callerName: $callerName');
        ReleaseLogger.log('   callType: $callType');

        // Mostrar indicador de carga mientras se genera el token
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(),
          ),
        );

        try {
          // 1. Actualizar estado de llamada en Firestore
          ReleaseLogger.log('📝 Actualizando estado de llamada en Firestore...');
          await VideoCallService().acceptCall(callId);
          ReleaseLogger.log('✅Llamada aceptada en Firestore');

          // 2. Generar token de Agora
          ReleaseLogger.log('🎫 Generando token de Agora...');
          final functions = FirebaseFunctions.instance;
          final callable = functions.httpsCallable('generateAgoraToken');

          final result = await callable.call({
            'channelName': channelName.toString().trim(),
            'uid': 0,
          });

          final token = result.data['token'] as String;
          final uid = result.data['uid'] as int;

          ReleaseLogger.log('✅Token generado - UID: $uid');

          // 3. Cerrar indicador de carga y navegar a la pantalla de llamada correcta
          if (context.mounted) {
            Navigator.of(context).pop(); // Cerrar loading indicator

            // Navegar a AudioCallScreen para llamadas de audio, VideoCallScreen para video
            if (callType == 'audio') {
              await Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(
                  builder: (context) => AudioCallScreen(
                    callId: callId,
                    channelName: channelName,
                    token: token,
                    uid: uid,
                    isCaller: false,
                    remoteName: callerName,
                    receiverId: callerId,
                  ),
                ),
              );
            } else {
              await Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(
                  builder: (context) => VideoCallScreen(
                    callId: callId,
                    channelName: channelName,
                    token: token,
                    uid: uid,
                    isCaller: false,
                    remoteName: callerName,
                    receiverId: callerId,
                    isVideo: true,
                  ),
                ),
              );
            }

            // Cuando vuelve de VideoCallScreen, navegar de vuelta a home
            ReleaseLogger.log('📱Videollamada terminada - navegando a home');

            // Obtener el rol del usuario para navegar a la pantalla correcta
            if (context.mounted) {
              try {
                final currentUser = firebase_auth.FirebaseAuth.instance.currentUser;
                if (currentUser != null) {
                  final userDoc = await FirebaseFirestore.instance
                      .collection('users')
                      .doc(currentUser.uid)
                      .get();

                  final userData = userDoc.data();
                  final role = userData?['role'] ?? 'child';

                  ReleaseLogger.log('👤Role del usuario: $role - navegando a ${role == 'parent' ? 'ParentMainShell' : 'ChildMainShell'}');

                  // Navegar a la pantalla correcta y limpiar el stack
                  if (context.mounted) {
                    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (context) => role == 'parent'
                            ? ParentMainShell()
                            : ChildMainShell(),
                      ),
                      (route) => false, // Remover todas las rutas anteriores
                    );
                  }
                } else {
                  ReleaseLogger.error('❌No hay usuario autenticado después de la llamada');
                }
              } catch (e) {
                ReleaseLogger.error('❌Error navegando a home después de llamada: $e');
              }
            }
          }
        } catch (e) {
          ReleaseLogger.error('❌Error procesando aceptación de CallKit: $e');

          if (context.mounted) {
            // Cerrar loading indicator
            Navigator.of(context).pop();

            // Mostrar error
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error al conectar la llamada: ${e.toString().length > 60 ? e.toString().substring(0, 60) + '...' : e}'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      } else {
        // Las llamadas se manejan completamente por CallKit (Android) y VoIP (iOS)
        ReleaseLogger.log('✅Llamada detectada en foreground - CallKit/VoIP debe manejarla');
        ReleaseLogger.log('ℹ️No se muestra diálogo de Flutter - solo notificaciones nativas');
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
        ReleaseLogger.log('🔄AuthWrapper - Connection state: ${snapshot.connectionState}');
        ReleaseLogger.log('🔄AuthWrapper - Has data: ${snapshot.hasData}');
        ReleaseLogger.log('🔄AuthWrapper - User: ${snapshot.data?.email}');

        // Usuario autenticado
        if (snapshot.hasData) {
          ReleaseLogger.log('✅Usuario autenticado: ${snapshot.data!.email}');

          // Registrar sesión del dispositivo
          _deviceSessionService
              .registerDeviceSession(snapshot.data!.uid)
              .catchError((e) {
                ReleaseLogger.log('⚠️ Error registrando sesión de dispositivo: $e');
              });

          // Iniciar listener de sesión para detectar login en otro dispositivo
          _deviceSessionService.startSessionListener(context);

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
                ReleaseLogger.error('❌Error consultando usuario: ${userSnapshot.error}');
                // Intentar obtener datos del cache local antes de mostrar error
                // Si hay datos cacheados, usarlos aunque haya error de red
                if (userSnapshot.hasData && userSnapshot.data != null) {
                  ReleaseLogger.log('⚠️ Error de red detectado, usando datos cacheados');
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
                ReleaseLogger.log('   connectionState: ${userSnapshot.connectionState}');

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
              final has2FA = userData?['twoFactorEnabled'] ?? false;

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
                      ReleaseLogger.log('👶 Redirigiendo a ChildMainShell (role: $role)');
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
                ReleaseLogger.log('👶 Redirigiendo a ChildMainShell (role: $role)');
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
