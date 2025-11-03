import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  print('📱 Rotación de pantalla bloqueada a portrait');

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
  print('📱 Status bar configurado como visible');

  print('🚀 Iniciando aplicación Talia...');

  // Inicializar MessageCacheService (Hive)
  try {
    await MessageCacheService().initialize();
    print('✅ MessageCacheService inicializado');
  } catch (e) {
    print('❌ Error inicializando MessageCacheService: $e');
  }

  // Inicializar DashboardCacheService (Hive)
  try {
    await DashboardCacheService().initialize();
    print('✅ DashboardCacheService inicializado');
  } catch (e) {
    print('❌ Error inicializando DashboardCacheService: $e');
  }

  // Inicializar Firebase solo si no está inicializado
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print('✅ Firebase inicializado');
  } else {
    print('✅ Firebase ya estaba inicializado');
  }

  // Configurar Crashlytics
  if (kDebugMode) {
    // Deshabilitar Crashlytics en modo debug para no contaminar reportes
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    print('🐛 Crashlytics DESHABILITADO en modo debug');
  } else {
    // Habilitar Crashlytics en producción
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
    print('📊 Crashlytics HABILITADO en producción');
  }

  // Capturar errores de Flutter framework
  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
    print('❌ Flutter error capturado: ${errorDetails.exception}');
  };

  // Capturar errores asíncronos fuera del framework Flutter
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    print('❌ Error asíncrono capturado: $error');
    return true;
  };

  print('✅ Crashlytics configurado');

  // Inicializar Firebase Analytics
  try {
    await AnalyticsService().initialize();
    print('✅ Analytics inicializado');
  } catch (e) {
    print('⚠️ Error inicializando Analytics: $e (continuando...)');
  }

  // Inicializar Firebase Performance Monitoring
  try {
    await PerformanceService().initialize();
    print('✅ Performance Monitoring inicializado');
  } catch (e) {
    print('⚠️ Error inicializando Performance: $e (continuando...)');
  }

  // Inicializar Network Status Service
  try {
    await NetworkStatusService().initialize();
    print('✅ Network Status Service inicializado');
  } catch (e) {
    print('⚠️ Error inicializando Network Status: $e (continuando...)');
  }

  // Inicializar Offline Queue Service
  try {
    await OfflineQueueService().initialize();
    print('✅ Offline Queue Service inicializado');
  } catch (e) {
    print('⚠️ Error inicializando Offline Queue: $e (continuando...)');
  }

  // Inicializar Accessibility Service
  try {
    await AccessibilityService().initialize();
    print('✅ Accessibility Service inicializado');
  } catch (e) {
    print('⚠️ Error inicializando Accessibility: $e (continuando...)');
  }

  // Inicializar AdMob (Google Mobile Ads) para monetización
  try {
    await AdService().initialize();
    print('✅ AdMob inicializado con cumplimiento COPPA');
  } catch (e) {
    print('⚠️ Error inicializando AdMob: $e (continuando...)');
  }

  // Pre-cargar stickers en segundo plano (sin bloquear la app)
  StickersService()
      .preloadStickers()
      .then((_) {
        print('✅ Stickers pre-cargados en segundo plano');
      })
      .catchError((e) {
        print('⚠️ Error pre-cargando stickers: $e (continuando...)');
      });

  // Activar Firebase App Check con Play Integrity para producción
  if (kDebugMode) {
    // En modo debug, usar debug provider para emuladores
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
      webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    );
    print('🐛 Firebase App Check activado con DEBUG provider');

    // Obtener y mostrar el debug token para registrarlo en Firebase Console
    // En Android debug, el token se genera automáticamente por el debug provider
    // Esperar un momento para que se genere
    await Future.delayed(Duration(seconds: 2));

    try {
      final token = await FirebaseAppCheck.instance.getToken();
      if (token != null && token.isNotEmpty) {
        print('🔑 DEBUG TOKEN para Firebase Console:');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        print('   $token');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        print('📋 Copia este token y regístralo en:');
        print('   Firebase Console → App Check → Apps → Manage debug tokens');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      } else {
        print('⚠️ No se pudo obtener debug token (token es null o vacío)');
        print('💡 En algunos casos, el token se genera en logcat de Android');
        print('   Busca en logcat: "DebugAppCheckProvider"');
      }
    } catch (e) {
      print('⚠️ No se pudo obtener debug token: $e');
      print('💡 El token de debug se puede encontrar en logcat de Android');
      print('   Busca: "DebugAppCheckProvider" o "AppCheckDebugProvider"');
    }
  } else {
    // En producción, usar Play Integrity y Device Check
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.playIntegrity,
      appleProvider: AppleProvider.deviceCheck,
      webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    );
    print('✅ Firebase App Check activado con Play Integrity y Device Check');
  }

  // Habilitar persistencia offline de Firestore para caché local
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  print('💾 Persistencia offline de Firestore habilitada');

  // Inicializar Remote Config para configuraciones de la app
  try {
    await AppConfigService().initialize();
    print('✅ App Config Service inicializado');
  } catch (e) {
    print(
      '⚠️ Error inicializando App Config: $e (continuando con valores por defecto)',
    );
  }

  // Inicializar servicio de notificaciones
  print('📲 Inicializando servicio de notificaciones...');
  await NotificationService().initialize();
  print('✅ Servicio de notificaciones completado');

  // Inicializar VoIP Push y CallKit (solo iOS)
  if (Platform.isIOS) {
    print('📱 Inicializando VoIP Service...');
    await VoIPService().initialize();
    print('✅ VoIP Service inicializado');
  }

  // Registrar APNs token para Phone Authentication (iOS)
  if (Platform.isIOS) {
    try {
      print('📱 Obteniendo APNs token para Phone Auth...');
      final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
      if (apnsToken != null) {
        print('✅ APNs token obtenido: ${apnsToken.substring(0, 20)}...');
      } else {
        print('⚠️ No se pudo obtener APNs token - esperando registro...');
        // Escuchar cuando se obtenga el token
        FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
          print('✅ APNs token actualizado');
        });
      }
    } catch (e) {
      print('⚠️ Error obteniendo APNs token: $e');
    }
  }

  print('✅ APNs configurado y listo para Phone Auth');

  // Inicializar ThemeService
  final themeService = ThemeService();
  await themeService.initialize();
  print('✅ ThemeService inicializado');

  runApp(
    ChangeNotifierProvider.value(value: themeService, child: const TaliaApp()),
  );
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
      print('📱 App resumed from background');

      // App regresó de background, verificar llamadas pendientes
      _checkPendingCall();

      // Marcar en ForegroundMessageListener que la app volvió del background
      // Esto suprime banners custom por unos segundos para evitar mostrar notificaciones
      // cuando el usuario abre la app manualmente después de recibir notificaciones
      ForegroundMessageListener().markAppResumedFromBackground();

      // ℹ️ Firestore maneja automáticamente la reconexión cuando la app se reanuda.
      // NO forzar disableNetwork/enableNetwork porque cancela todos los StreamBuilders
      // activos y causa que la UI se quede en loading infinito.
      print('✅ Firestore se reconectará automáticamente');
    }
  }

  /// Escuchar stream de llamadas pendientes de VoIP
  void _setupPendingCallListener() {
    if (!Platform.isIOS) return;

    _pendingCallSubscription = VoIPService().pendingCallStream.listen((
      callData,
    ) {
      print('📞 [Main] Llamada pendiente recibida del stream: $callData');
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
      print('📞 [Main] Llamada pendiente detectada: $pendingData');
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

    print('🚀 [Main] Navegando a pantalla de llamada:');
    print('   - Call ID: $callId');
    print('   - Channel: $channelName');
    print('   - Type: $callType');
    print('   - Is Audio: $isAudioCall');
    print('   - UID: $uid');

    if (_navigatorKey.currentContext != null) {
      if (isAudioCall) {
        // Navegar a AudioCallScreen para llamadas de audio
        print('📞 [Main] Navegando a AudioCallScreen');
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
        print('📹 [Main] Navegando a VideoCallScreen');
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
    FirebaseAuth.instance.authStateChanges().listen((user) {
      print(
        '🔐 AUTH STATE CHANGED - User: ${user?.uid ?? "null"}, Phone: ${user?.phoneNumber ?? "null"}',
      );
      if (user != null) {
        print('✅ Usuario autenticado: ${user.uid}');

        // Inicializar ForegroundMessageListener para notificaciones en tiempo real
        print('🔔 Inicializando ForegroundMessageListener...');
        ForegroundMessageListener().initialize(_navigatorKey);
        print('✅ ForegroundMessageListener inicializado');

        // Inicializar protección de screenshots
        print('📸 Inicializando ScreenshotProtectionService...');
        ScreenshotProtectionService().initialize();
        print('✅ ScreenshotProtectionService inicializado');

        // Inicializar listener de badge del ícono
        print('🔔 Inicializando badge listener...');
        UnreadMessagesService().startBadgeListener();
        print('✅ Badge listener inicializado');

        // Preload de historias en segundo plano
        print('📱 Iniciando preload de historias...');
        StoryService().preloadStories().then((_) {
          print('✅ Preload de historias completado');
        }).catchError((e) {
          print('⚠️ Error en preload de historias: $e');
        });

        // Cancelar suscripción anterior si existe
        _userRoleSubscription?.cancel();

        // Crear nueva suscripción para escuchar cambios de rol
        _userRoleSubscription = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots()
            .listen((snapshot) {
              print(
                '📄 Snapshot de usuario: exists=${snapshot.exists}, data=${snapshot.data()}',
              );
              if (snapshot.exists) {
                final userData = snapshot.data();
                final newRole = userData?['role'] ?? 'child';
                print('🔍 Role actual en Firestore: $newRole');
                print('🔍 Role guardado en memoria: $_currentUserRole');

                if (_currentUserRole != null && _currentUserRole != newRole) {
                  print(
                    '🔄 Role cambió de $_currentUserRole a $newRole - Reconstruyendo navegación',
                  );

                  // Actualizar role primero
                  _currentUserRole = newRole;

                  // Forzar reconexión de Firestore para obtener datos frescos sin cache
                  print('🔄 Forzando reconexión de Firestore para limpiar cache...');
                  FirebaseFirestore.instance.disableNetwork().then((_) {
                    print('✅ Firestore desconectado');
                    return Future.delayed(Duration(milliseconds: 200));
                  }).then((_) {
                    return FirebaseFirestore.instance.enableNetwork();
                  }).then((_) {
                    print('✅ Firestore reconectado con datos frescos');

                    // Navegar después de que Firestore esté listo
                    Future.delayed(Duration(milliseconds: 100), () {
                      final navigator = _navigatorKey.currentState;
                      if (navigator != null && navigator.mounted) {
                        print('✅ Navegando a AuthWrapper con nuevo rol: $newRole');
                        navigator.pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const AuthWrapper()),
                          (route) => false,
                        );
                      } else {
                        print('⚠️ Navigator no disponible para navegación');
                      }
                    });
                  }).catchError((error) {
                    print('⚠️ Error reconectando Firestore: $error');
                    // Intentar navegar de todos modos
                    Future.delayed(Duration(milliseconds: 100), () {
                      final navigator = _navigatorKey.currentState;
                      if (navigator != null && navigator.mounted) {
                        print('⚠️ Navegando a AuthWrapper a pesar del error');
                        navigator.pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const AuthWrapper()),
                          (route) => false,
                        );
                      }
                    });
                  });
                } else if (_currentUserRole == null) {
                  print('ℹ️ Inicializando role por primera vez: $newRole');
                  _currentUserRole = newRole;
                }
              }
            });
      } else {
        // Usuario deslogueado - cancelar listener de Firestore
        _userRoleSubscription?.cancel();
        _userRoleSubscription = null;
        _currentUserRole = null;
        print('🔒 Listener de role cancelado por logout');

        // Limpiar cache de historias
        StoryService().clearCache();
        print('🧹 Cache de historias limpiado por logout');
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

      print(
        '📞 ${isAudioCall ? 'Llamada de audio' : 'Videollamada'} entrante recibida en main.dart',
      );
      print('📦 Datos completos: $callData');
      print(
        '📦 channelName: "${callData['channelName']}" (null? ${callData['channelName'] == null})',
      );
      if (isEmergency) {
        print('🆘 Es una llamada de EMERGENCIA');
      }

      // En iOS, usar CallKit nativo directamente (no el diálogo de Flutter)
      // Esto evita duplicación con VoIP push que puede llegar después
      if (Platform.isIOS) {
        print(
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

        print('✅ [iOS] CallKit mostrado desde FCM foreground notification');

        // IMPORTANTE: Configurar listener para detectar si la llamada es cancelada
        // Esto maneja el caso donde la llamada se cancela antes de que el listener
        // del controller se configure (race condition)
        print('👂 [iOS] Configurando listener de cancelación para callId: $callId');
        final cancelListener = FirebaseFirestore.instance
            .collection('video_calls')
            .doc(callId)
            .snapshots()
            .listen((snapshot) {
          if (!snapshot.exists) {
            print('📵 [iOS-main] Documento $callId eliminado - cerrando CallKit');
            callKit.endCall(callId);
            return;
          }

          final data = snapshot.data() as Map<String, dynamic>?;
          final status = data?['status'];

          if (status == 'cancelled') {
            print('📵 [iOS-main] Llamada $callId cancelada - cerrando CallKit');
            // Usar el method channel nativo en lugar del plugin para evitar reinicio
            VoIPService().notifyCallEnded(callId);
          } else if (status == 'accepted' || status == 'active' || status == 'ended') {
            print('ℹ️ [iOS-main] Llamada $callId en status $status - listener se limpiará automáticamente');
          }
        });

        // Cancelar el listener después de 60 segundos (timeout de llamada)
        Future.delayed(Duration(seconds: 60), () {
          cancelListener.cancel();
          print('🧹 [iOS-main] Listener de cancelación limpiado por timeout');
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

      print('🔍 Detectando origen del evento:');
      print('   hasId: $hasId');
      print('   hasFromFirestore: $hasFromFirestore');
      print('   hasFromNotificationTap: $hasFromNotificationTap');
      print('   isFromCallKitAcceptance: $isFromCallKitAcceptance');

      if (isFromCallKitAcceptance) {
        // Usuario aceptó desde CallKit en background - navegar directamente a VideoCallScreen
        print('✅ Llamada aceptada desde CallKit en background - generando token y navegando a videollamada');

        // IMPORTANTE: Si la app está en background, puede que el contexto aún no esté disponible
        // Esperar hasta que esté listo (máximo 5 segundos)
        BuildContext? context = _navigatorKey.currentContext;
        if (context == null) {
          print('⏳ Contexto no disponible, esperando a que la app inicialice...');
          for (int i = 0; i < 50; i++) {
            await Future.delayed(const Duration(milliseconds: 100));
            context = _navigatorKey.currentContext;
            if (context != null) {
              print('✅ Contexto disponible después de ${(i + 1) * 100}ms');
              break;
            }
          }
        }

        if (context == null) {
          print('❌ No se pudo obtener el contexto del navegador después de 5 segundos');
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
          print('❌ Datos incompletos en callData de CallKit:');
          print('   callId=$callId');
          print('   channelName=$channelName');
          print('   callerId=$callerId');
          print('   extra=$extra');
          return;
        }

        // Obtener callType desde Firestore si no está en extra
        String callType = extra?['callType'] as String? ?? callData['type'] as String? ?? 'video';

        // Si callType no está en los datos de CallKit, consultar Firestore
        if (callType == 'video' && (extra?['callType'] == null && callData['type'] == null)) {
          print('⚠️ callType no encontrado en CallKit data, consultando Firestore...');
          try {
            final callDoc = await FirebaseFirestore.instance
                .collection('video_calls')
                .doc(callId)
                .get();
            if (callDoc.exists) {
              callType = callDoc.data()?['callType'] as String? ?? 'video';
              print('✅ callType obtenido de Firestore: $callType');
            }
          } catch (e) {
            print('⚠️ Error obteniendo callType de Firestore: $e');
            // Mantener 'video' como default
          }
        }

        print('📞 Procesando aceptación de CallKit:');
        print('   callId: $callId');
        print('   channelName: $channelName');
        print('   callerId: $callerId');
        print('   callerName: $callerName');
        print('   callType: $callType');

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
          print('📝 Actualizando estado de llamada en Firestore...');
          await VideoCallService().acceptCall(callId);
          print('✅ Llamada aceptada en Firestore');

          // 2. Generar token de Agora
          print('🎫 Generando token de Agora...');
          final functions = FirebaseFunctions.instance;
          final callable = functions.httpsCallable('generateAgoraToken');

          final result = await callable.call({
            'channelName': channelName.toString().trim(),
            'uid': 0,
          });

          final token = result.data['token'] as String;
          final uid = result.data['uid'] as int;

          print('✅ Token generado - UID: $uid');

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
            print('📱 Videollamada terminada - navegando a home');

            // Obtener el rol del usuario para navegar a la pantalla correcta
            if (context.mounted) {
              try {
                final currentUser = FirebaseAuth.instance.currentUser;
                if (currentUser != null) {
                  final userDoc = await FirebaseFirestore.instance
                      .collection('users')
                      .doc(currentUser.uid)
                      .get();

                  final userData = userDoc.data();
                  final role = userData?['role'] ?? 'child';

                  print('👤 Role del usuario: $role - navegando a ${role == 'parent' ? 'ParentMainShell' : 'ChildMainShell'}');

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
                  print('❌ No hay usuario autenticado después de la llamada');
                }
              } catch (e) {
                print('❌ Error navegando a home después de llamada: $e');
              }
            }
          }
        } catch (e) {
          print('❌ Error procesando aceptación de CallKit: $e');

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
        print('✅ Llamada detectada en foreground - CallKit/VoIP debe manejarla');
        print('ℹ️ No se muestra diálogo de Flutter - solo notificaciones nativas');
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
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        print('🔄 AuthWrapper - Connection state: ${snapshot.connectionState}');
        print('🔄 AuthWrapper - Has data: ${snapshot.hasData}');
        print('🔄 AuthWrapper - User: ${snapshot.data?.email}');

        // Usuario autenticado
        if (snapshot.hasData) {
          print('✅ Usuario autenticado: ${snapshot.data!.email}');

          // Registrar sesión del dispositivo
          _deviceSessionService
              .registerDeviceSession(snapshot.data!.uid)
              .catchError((e) {
                print('⚠️ Error registrando sesión de dispositivo: $e');
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
                print('❌ Error consultando usuario: ${userSnapshot.error}');
                // Intentar obtener datos del cache local antes de mostrar error
                // Si hay datos cacheados, usarlos aunque haya error de red
                if (userSnapshot.hasData && userSnapshot.data != null) {
                  print('⚠️ Error de red detectado, usando datos cacheados');
                  // Continuar con los datos cacheados (no hacer return aquí)
                } else {
                  // Sin cache disponible, volver a AuthScreen
                  print(
                    '❌ Sin datos cacheados disponibles, mostrando AuthScreen',
                  );
                  return AuthScreen();
                }
              }

              if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                print(
                  '❌ Usuario no existe en Firestore: ${snapshot.data!.uid}',
                );
                print('   hasData: ${userSnapshot.hasData}');
                print('   exists: ${userSnapshot.data?.exists}');
                print('   connectionState: ${userSnapshot.connectionState}');

                // Usuario autenticado pero no existe en Firestore - ir a completar perfil
                print(
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
                print('❌ userData es null');
                return ProfileCompletionScreen(
                  phoneNumber: snapshot.data!.phoneNumber ?? 'Sin teléfono',
                );
              }
              final role = userData['role'] ?? 'child';
              final userEmail = snapshot.data!.email;
              final userPhone = snapshot.data!.phoneNumber;
              final userId = snapshot.data!.uid;

              print('✅ Usuario encontrado en Firestore:');
              print('   Email: $userEmail');
              print('   Phone: $userPhone');
              print('   Role: $role');
              print(
                '   🔑 Timestamp: ${DateTime.now().millisecondsSinceEpoch}',
              );

              // Verificar si tiene 2FA habilitado
              final has2FA = userData?['twoFactorEnabled'] ?? false;

              if (has2FA) {
                print('🔐 Usuario tiene 2FA habilitado');

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
                      print(
                        '⚠️ 2FA no verificado en esta sesión, mostrando pantalla de verificación',
                      );
                      return TwoFactorVerificationScreen(
                        userId: userId,
                        role: role,
                      );
                    }

                    print('✅ 2FA ya verificado en esta sesión');

                    // Usuario verificado, continuar con navegación normal
                    if (role == 'parent') {
                      print('👔 Redirigiendo a ParentMainShell');
                      return ParentMainShell();
                    } else {
                      print('👶 Redirigiendo a ChildMainShell (role: $role)');
                      return ChildMainShell();
                    }
                  },
                );
              } else {
                print('ℹ️ Usuario NO tiene 2FA habilitado');
              }

              // Redirigir según el rol: solo 'parent' va a ParentMainShell, el resto va a ChildMainShell
              if (role == 'parent') {
                print('👔 Redirigiendo a ParentMainShell');
                return ParentMainShell();
              } else {
                print('👶 Redirigiendo a ChildMainShell (role: $role)');
                return ChildMainShell();
              }
            },
          );
        }

        // No autenticado - mostrar pantalla de login
        print('❌ Usuario no autenticado');
        print('🔑 Mostrando pantalla de autenticación');
        return AuthScreen();
      },
    );
  }
}
