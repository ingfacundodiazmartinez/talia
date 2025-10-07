import 'dart:io';
import 'package:flutter/material.dart';
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
import 'notification_service.dart';
import 'widgets/incoming_call_dialog.dart';
import 'theme_service.dart';
import 'services/two_factor_session_service.dart';
import 'services/app_config_service.dart';
import 'dart:async';

// IMPORTANTE: Después de ejecutar 'flutterfire configure',
// descomenta la siguiente línea:
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  print('🚀 Iniciando aplicación Talia...');

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
  await FirebaseAppCheck.instance.activate(
    // Android: Play Integrity API (para apps de Play Store)
    androidProvider: AndroidProvider.playIntegrity,
    // iOS: Device Check (para apps de App Store)
    appleProvider: AppleProvider.deviceCheck,
    // Web: reCAPTCHA v3
    webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
  );
  print('✅ Firebase App Check activado con Play Integrity y Device Check');

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

class _TaliaAppState extends State<TaliaApp> {
  StreamSubscription<Map<String, dynamic>>? _incomingCallSubscription;
  StreamSubscription<DocumentSnapshot>? _userRoleSubscription;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  String? _currentUserRole;

  @override
  void initState() {
    super.initState();
    _setupIncomingCallListener();
    _setupRoleListener();
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

  @override
  void dispose() {
    _incomingCallSubscription?.cancel();
    _userRoleSubscription?.cancel();
    super.dispose();
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

      // Obtener el contexto del navegador
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

    return MaterialApp(
      key: ValueKey('app_${_currentUserRole ?? "unknown"}'),
      navigatorKey: _navigatorKey,
      title: 'Talia',
      debugShowCheckedModeBanner: false,
      theme: themeService.currentTheme,
      home: const AuthWrapper(),
    );
  }
}

// Wrapper para manejar autenticación
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

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

          // Actualizar estado en línea solo si el usuario lo permite
          FirebaseFirestore.instance
              .collection('users')
              .doc(snapshot.data!.uid)
              .get()
              .then((userDoc) {
                final userData = userDoc.data();
                final showOnlineStatus = userData?['showOnlineStatus'] ?? true;

                FirebaseFirestore.instance
                    .collection('users')
                    .doc(snapshot.data!.uid)
                    .set({
                      'isOnline':
                          showOnlineStatus, // Respetar configuración del usuario
                      'lastSeen': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true))
                    .catchError((e) {
                      print('⚠️ Error actualizando isOnline: $e');
                    });
              });

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

                // Verificar si ya lo verificó en esta sesión
                final sessionService = TwoFactorSessionService();
                final isVerified = sessionService.isVerified(userId);

                if (!isVerified) {
                  print(
                    '⚠️ 2FA no verificado en esta sesión, mostrando pantalla de verificación',
                  );
                  return TwoFactorVerificationScreen(
                    userId: userId,
                    role: role,
                  );
                } else {
                  print('✅ 2FA ya verificado en esta sesión');
                }
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
