import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

// Importa tus pantallas
import 'auth_screen.dart';
import 'parent_home_screen.dart';
import 'child_home_screen.dart';
import 'profile_completion_screen.dart';
import 'notification_service.dart';
import 'widgets/incoming_call_dialog.dart';
import 'dart:async';

// IMPORTANTE: Después de ejecutar 'flutterfire configure',
// descomenta la siguiente línea:
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  print('🚀 Iniciando aplicación Talia...');

  // Inicializar Firebase solo si no está inicializado
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    print('✅ Firebase inicializado');
  } else {
    print('✅ Firebase ya estaba inicializado');
  }

  // Inicializar servicio de notificaciones
  print('📲 Inicializando servicio de notificaciones...');
  await NotificationService().initialize();
  print('✅ Servicio de notificaciones completado');

  // Configurar Firebase App Check para dispositivos físicos
  print('🔧 Configurando Firebase App Check para dispositivos físicos');
  if (kDebugMode) {
    // En modo debug, usar debug provider para dispositivos físicos
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
    );
    print('🔐 App Check configurado en modo debug');
  } else {
    // En producción usar providers reales
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.playIntegrity,
      appleProvider: AppleProvider.appAttestWithDeviceCheckFallback,
    );
    print('🔐 App Check configurado para producción');
  }

  runApp(const SmartConvoApp());
}

class SmartConvoApp extends StatefulWidget {
  const SmartConvoApp({super.key});

  @override
  State<SmartConvoApp> createState() => _SmartConvoAppState();
}

class _SmartConvoAppState extends State<SmartConvoApp> {
  StreamSubscription<Map<String, dynamic>>? _incomingCallSubscription;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _setupIncomingCallListener();
  }

  @override
  void dispose() {
    _incomingCallSubscription?.cancel();
    super.dispose();
  }

  void _setupIncomingCallListener() {
    _incomingCallSubscription =
        NotificationService().incomingCallStream.listen((callData) {
      final callType = callData['type'] ?? 'video_call';
      final isAudioCall = callType == 'audio_call';

      print('📞 ${isAudioCall ? 'Llamada de audio' : 'Videollamada'} entrante recibida en main.dart');
      print('📦 Datos: $callData');

      // Obtener el contexto del navegador
      final context = _navigatorKey.currentContext;
      if (context != null) {
        // Mostrar el diálogo de llamada entrante
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => IncomingCallDialog(
            callId: callData['callId'] ?? '',
            callerId: callData['callerId'] ?? '',
            callerName: callData['callerName'] ?? 'Usuario desconocido',
            channelName: callData['channelName'] ?? '',
            callType: isAudioCall ? 'audio' : 'video',
          ),
        );
      } else {
        print('❌ No se pudo obtener el contexto del navegador');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'SmartConvo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Poppins',
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(0xFF9D7FE8),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFF9D7FE8),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
        ),
      ),
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

          // Actualizar estado en línea (upsert)
          FirebaseFirestore.instance
              .collection('users')
              .doc(snapshot.data!.uid)
              .set({
                'isOnline': true,
                'lastSeen': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true)).catchError((e) {
                print('⚠️ Error actualizando isOnline: $e');
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
                print('📝 Mostrando ProfileCompletionScreen para completar registro');
                return ProfileCompletionScreen(
                  phoneNumber: snapshot.data!.phoneNumber ?? 'Sin teléfono',
                );
              }

              final userData =
                  userSnapshot.data!.data() as Map<String, dynamic>?;
              final role = userData?['role'] ?? 'child'; // Por defecto 'child' si no existe
              final userEmail = snapshot.data!.email;
              final userPhone = snapshot.data!.phoneNumber;

              print('✅ Usuario encontrado en Firestore:');
              print('   Email: $userEmail');
              print('   Phone: $userPhone');
              print('   Role: $role');
              print('   🔑 Timestamp: ${DateTime.now().millisecondsSinceEpoch}');

              // Redirigir según el rol: solo 'parent' va a ParentHomeScreen, el resto va a ChildHomeScreen
              if (role == 'parent') {
                print('👔 Redirigiendo a ParentHomeScreen');
                return ParentHomeScreen();
              } else {
                print('👶 Redirigiendo a ChildHomeScreen (role: $role)');
                return ChildHomeScreen();
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
