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
import 'notification_service.dart';
import 'widgets/incoming_call_dialog.dart';
import 'theme_service.dart';
import 'services/two_factor_session_service.dart';
import 'services/app_config_service.dart';
import 'services/message_cache_service.dart';
import 'services/device_session_service.dart';
import 'services/online_status_service.dart';
import 'services/voip_service.dart';
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

  print('🚀 Iniciando aplicación Talia...');

  // Inicializar MessageCacheService (Hive)
  try {
    await MessageCacheService().initialize();
    print('✅ MessageCacheService inicializado');
  } catch (e) {
    print('❌ Error inicializando MessageCacheService: $e');
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
    print('⚠️ Error inicializando App Config: $e (continuando con valores por defecto)');
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
      // App regresó de background, verificar llamadas pendientes
      _checkPendingCall();
    }
  }

  /// Escuchar stream de llamadas pendientes de VoIP
  void _setupPendingCallListener() {
    if (!Platform.isIOS) return;

    _pendingCallSubscription = VoIPService().pendingCallStream.listen((callData) {
      print('📞 [Main] Llamada pendiente recibida del stream: $callData');
      _navigateToCall(callData);
    });
  }

  Future<void> _checkPendingCall() async {
    if (!Platform.isIOS) return;

    await Future.delayed(const Duration(milliseconds: 500)); // Pequeño delay para que Flutter esté listo

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

    print('🚀 [Main] Navegando a pantalla de llamada:');
    print('   - Call ID: $callId');
    print('   - Channel: $channelName');
    print('   - Type: $callType');
    print('   - UID: $uid');

    if (_navigatorKey.currentContext != null) {
      if (callType == 'audio') {
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
        Navigator.of(_navigatorKey.currentContext!).push(
          MaterialPageRoute(
            builder: (context) => VideoCallScreen(
              callId: callId,
              channelName: channelName,
              token: token,
              uid: uid,
              isCaller: false, // Estamos recibiendo la llamada
              remoteName: callerName,
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

                if (_currentUserRole != null && _currentUserRole != newRole) {
                  print(
                    '🔄 Role cambió de $_currentUserRole a $newRole - Reconstruyendo navegación',
                  );

                  // Actualizar role primero
                  setState(() {
                    _currentUserRole = newRole;
                  });

                  // Forzar navegación completa al home con el nuevo role
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final navigator = _navigatorKey.currentState;
                    if (navigator != null) {
                      navigator.pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => AuthWrapper()),
                        (route) => false,
                      );
                    }
                  });
                } else if (_currentUserRole == null) {
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
      }
    });
  }

  void _setupIncomingCallListener() {
    _incomingCallSubscription = NotificationService().incomingCallStream.listen((
      callData,
    ) {
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

      // En iOS, CallKit maneja todas las llamadas entrantes
      // No mostramos el diálogo para evitar duplicación con CallKit
      if (Platform.isIOS) {
        print('📱 [iOS] CallKit manejará esta llamada, omitiendo diálogo de Flutter');
        return;
      }

      // Obtener el contexto del navegador (solo Android)
      final context = _navigatorKey.currentContext;
      if (context != null) {
        // Navegar a pantalla completa de llamada entrante
        Navigator.of(context).push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (context) => IncomingCallDialog(
              callId: callData['callId'] ?? '',
              callerId: callData['callerId'] ?? '',
              callerName: callData['callerName'] ?? 'Usuario desconocido',
              callerPhotoURL: callData['callerPhotoURL'],
              channelName: callData['channelName'] ?? '',
              callType: callType,
              isEmergency: isEmergency,
            ),
          ),
        );
      } else {
        print('❌ No se pudo obtener el contexto del navegador');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);

    return GestureDetector(
      onTap: () {
        // Cerrar teclado al tocar fuera de cualquier input
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: MaterialApp(
        key: ValueKey('app_${_currentUserRole ?? "unknown"}'),
        navigatorKey: _navigatorKey,
        title: 'Talia',
        debugShowCheckedModeBanner: false,
        theme: themeService.currentTheme,
        home: const AnimatedSplashScreen(
          nextScreen: AuthWrapper(),
        ),
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
          _deviceSessionService.registerDeviceSession(snapshot.data!.uid).catchError((e) {
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
              if (userSnapshot.connectionState == ConnectionState.waiting) {
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
                // En caso de error, mostrar pantalla de autenticación
                return AuthScreen();
              }

              if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                print(
                  '❌ Usuario no existe en Firestore: ${snapshot.data!.uid}',
                );
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
              final role =
                  userData?['role'] ??
                  'child'; // Por defecto 'child' si no existe
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
                      print('👶 Redirigiendo a ChildMainShell');
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
