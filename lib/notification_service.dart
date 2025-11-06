import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'constants/notification_types.dart';
import 'services/notification_filter.dart';
import 'services/callkit_service.dart';
import 'services/foreground_message_listener.dart';
import 'utils/release_logger.dart';

// Manejador de mensajes en segundo plano (debe estar fuera de la clase)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  ReleaseLogger.log('🔥 ============================================', tag: 'NotificationService');
  ReleaseLogger.log('📩 BACKGROUND MESSAGE HANDLER EJECUTADO', tag: 'NotificationService');
  ReleaseLogger.log('🔥 ============================================', tag: 'NotificationService');
  ReleaseLogger.log('📩 Notification title: ${message.notification?.title}', tag: 'NotificationService');
  ReleaseLogger.log('📩 Notification body: ${message.notification?.body}', tag: 'NotificationService');
  ReleaseLogger.log('📦 Tipo: ${message.data['type']}', tag: 'NotificationService');
  ReleaseLogger.log('📦 Data completa: ${message.data}', tag: 'NotificationService');
  ReleaseLogger.log('🔥 ============================================', tag: 'NotificationService');

  // Inicializar Firebase si no está inicializado
  // Esto es necesario para que el background handler funcione en iOS
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      ReleaseLogger.log('✅ Firebase inicializado en background handler', tag: 'NotificationService');
    }
  } catch (e) {
    ReleaseLogger.error('Error inicializando Firebase en background: $e', tag: 'NotificationService');
  }

  // Si es una llamada, mostrar CallKit en pantalla completa
  if (message.data['type'] == 'video_call' ||
      message.data['type'] == 'audio_call' ||
      message.data['type'] == 'group_video_call' ||
      message.data['type'] == 'group_audio_call' ||
      message.data['type'] == 'emergency_call') {
    ReleaseLogger.log('📞 LLAMADA ENTRANTE DETECTADA EN SEGUNDO PLANO', tag: 'NotificationService');
    ReleaseLogger.log('📞 Tipo de llamada: ${message.data['type']}', tag: 'NotificationService');
    ReleaseLogger.log('📞 Call ID: ${message.data['callId']}', tag: 'NotificationService');
    ReleaseLogger.log('📞 Caller Name: ${message.data['callerName']}', tag: 'NotificationService');
    ReleaseLogger.log('📞 Caller ID: ${message.data['callerId']}', tag: 'NotificationService');

    try {
      final callKit = CallKitService();
      await callKit.showIncomingCall(
        callId: message.data['callId'] ?? message.messageId ?? '',
        callerName: message.data['callerName'] ?? 'Usuario',
        callerId: message.data['callerId'] ?? message.data['senderId'] ?? '',
        callerPhotoUrl: message.data['callerPhotoURL'] ?? message.data['senderPhotoUrl'],
        callType: (message.data['type'] == 'audio_call' || message.data['type'] == 'group_audio_call') ? 'audio' : 'video',
        isEmergency: message.data['isEmergency'] == 'true' || message.data['isEmergency'] == true,
        extraData: message.data,
      );
      ReleaseLogger.log('✅ CallKit mostrado exitosamente', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('ERROR mostrando CallKit: $e', tag: 'NotificationService');
      ReleaseLogger.error('Stack trace: ${StackTrace.current}', tag: 'NotificationService');
    }
  }

  // Las demás notificaciones se manejan automáticamente por FCM
  ReleaseLogger.log('🔥 ============================================', tag: 'NotificationService');
  ReleaseLogger.log('📩 BACKGROUND HANDLER FINALIZADO', tag: 'NotificationService');
  ReleaseLogger.log('🔥 ============================================', tag: 'NotificationService');
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final NotificationFilter _filter = NotificationFilter();
  final CallKitService _callKit = CallKitService();

  String? _fcmToken;
  bool _isInitialized = false;

  // Trackear el chat actual para suprimir notificaciones solo cuando estás dentro de él
  String? _currentChatId;

  // Stream para notificar videollamadas entrantes
  final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingCallStream => _incomingCallController.stream;

  // Stream para notificar cuando se toca una notificación de chat
  final _chatNotificationTapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get chatNotificationTapStream => _chatNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de emergencia
  final _emergencyNotificationTapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get emergencyNotificationTapStream => _emergencyNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de solicitud de contacto
  final _contactRequestNotificationTapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get contactRequestNotificationTapStream => _contactRequestNotificationTapController.stream;

  // Método público para emitir llamadas entrantes al stream
  void emitIncomingCall(Map<String, dynamic> callData) {
    _incomingCallController.add(callData);
  }

  // Establecer el chat actual (para suprimir notificaciones solo de ese chat)
  void setCurrentChat(String chatId) {
    _currentChatId = chatId;
    ReleaseLogger.log('📍 Chat actual establecido: $chatId', tag: 'NotificationService');
  }

  // Limpiar el chat actual (cuando sales del chat)
  void clearCurrentChat() {
    ReleaseLogger.log('📍 Chat actual limpiado: $_currentChatId', tag: 'NotificationService');
    _currentChatId = null;
  }

  // Helper para upsert de datos de usuario
  Future<void> _upsertUserData(Map<String, dynamic> data) async {
    final userId = _auth.currentUser?.uid;
    if (userId != null) {
      await _firestore.collection('users').doc(userId).set(
        data,
        SetOptions(merge: true),
      );
    }
  }

  /// Inicializar token FCM después del login exitoso
  /// Debe llamarse desde el flujo de autenticación para asegurar que el token se guarde
  Future<void> initializeFCMTokenAfterLogin() async {
    ReleaseLogger.log('🔄 Inicializando FCM token después del login...', tag: 'NotificationService');
    await _getFCMToken();
  }

  /// Limpiar tokens FCM duplicados de otros usuarios
  /// Esto previene que las notificaciones lleguen a usuarios anteriores del mismo dispositivo
  Future<void> _cleanupDuplicateTokens(String newToken) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      ReleaseLogger.log('🧹 Verificando tokens FCM duplicados para: ${newToken.substring(0, 20)}...', tag: 'NotificationService');

      // Buscar otros usuarios que tengan el mismo token FCM
      final duplicateUsersQuery = await _firestore
          .collection('users')
          .where('fcmToken', isEqualTo: newToken)
          .get();

      int cleanedCount = 0;
      for (final doc in duplicateUsersQuery.docs) {
        final userId = doc.id;

        // No limpiar el token del usuario actual
        if (userId == currentUserId) continue;

        // Limpiar token del usuario anterior
        await _firestore.collection('users').doc(userId).update({
          'fcmToken': FieldValue.delete(),
          'fcmTokenClearedAt': FieldValue.serverTimestamp(),
          'fcmTokenClearedReason': 'duplicate_token_cleanup',
        });

        cleanedCount++;
        ReleaseLogger.log('🗑️ Token FCM limpiado del usuario anterior: $userId', tag: 'NotificationService');
      }

      if (cleanedCount > 0) {
        ReleaseLogger.log('✅ Se limpiaron $cleanedCount tokens FCM duplicados', tag: 'NotificationService');
      } else {
        ReleaseLogger.log('✅ No se encontraron tokens FCM duplicados', tag: 'NotificationService');
      }
    } catch (e) {
      ReleaseLogger.error('Error limpiando tokens duplicados: $e', tag: 'NotificationService');
      // No hacer throw para no bloquear el flujo principal de registro
    }
  }

  // Inicializar servicio de notificaciones
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 1. Configurar manejador de mensajes en segundo plano
      // IMPORTANTE: Registrar en iOS Y Android para mostrar CallKit
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );
      ReleaseLogger.log('✅ Background handler de Flutter registrado', tag: 'NotificationService');

      // 2. Solicitar permisos
      await _requestPermissions();

      // 2.1. Desactivar notificaciones push en foreground (iOS)
      // Las custom notifications in-app se encargan de mostrar los mensajes
      await _fcm.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
      ReleaseLogger.log('✅ Notificaciones push desactivadas en foreground (solo custom notifications)', tag: 'NotificationService');

      // 3. Configurar notificaciones locales
      await _initializeLocalNotifications();

      // 4. Obtener token FCM
      await _getFCMToken();

      // 5. Inicializar CallKit
      _initializeCallKit();

      // 6. Configurar listeners
      _setupListeners();

      _isInitialized = true;
      ReleaseLogger.log('✅ Servicio de notificaciones inicializado', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('Error inicializando notificaciones: $e', tag: 'NotificationService');
    }
  }

  // Solicitar permisos de notificaciones
  Future<void> _requestPermissions() async {
    try {
      ReleaseLogger.log('🔔 Solicitando permisos de notificaciones...', tag: 'NotificationService');
      final settings = await _fcm.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      ReleaseLogger.log('📱 Permisos de notificaciones: ${settings.authorizationStatus}', tag: 'NotificationService');
      ReleaseLogger.log('   Alert: ${settings.alert}', tag: 'NotificationService');
      ReleaseLogger.log('   Badge: ${settings.badge}', tag: 'NotificationService');
      ReleaseLogger.log('   Sound: ${settings.sound}', tag: 'NotificationService');

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        ReleaseLogger.log('✅ Permisos concedidos', tag: 'NotificationService');
      } else if (settings.authorizationStatus ==
          AuthorizationStatus.provisional) {
        ReleaseLogger.log('⚠️ Permisos provisionales', tag: 'NotificationService');
      } else {
        ReleaseLogger.log('❌ Permisos denegados o no decididos', tag: 'NotificationService');
        ReleaseLogger.log('   Status: ${settings.authorizationStatus}', tag: 'NotificationService');
        ReleaseLogger.log('⚠️ Para habilitar notificaciones:', tag: 'NotificationService');
        ReleaseLogger.log('   1. Ve a Ajustes > Talia > Notificaciones', tag: 'NotificationService');
        ReleaseLogger.log('   2. Activa "Permitir notificaciones"', tag: 'NotificationService');
      }
    } catch (e) {
      ReleaseLogger.error('Error solicitando permisos: $e', tag: 'NotificationService');
      ReleaseLogger.error('   Stack trace: ${StackTrace.current}', tag: 'NotificationService');
    }
  }

  // Configurar notificaciones locales
  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Crear canales de notificaciones para Android
    if (Platform.isAndroid) {
      // Canal para notificaciones normales
      const androidChannel = AndroidNotificationChannel(
        'high_importance_channel',
        'Notificaciones Importantes',
        description: 'Canal para notificaciones importantes de Talia',
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      );

      // Canal especial para llamadas (máxima prioridad)
      const callsChannel = AndroidNotificationChannel(
        'calls_channel',
        'Llamadas',
        description: 'Canal para llamadas entrantes',
        importance: Importance.max,
        enableVibration: true,
        playSound: true,
        enableLights: true,
      );

      final plugin = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      await plugin?.createNotificationChannel(androidChannel);
      await plugin?.createNotificationChannel(callsChannel);
    }
  }

  // Obtener token FCM
  Future<void> _getFCMToken() async {
    try {
      ReleaseLogger.log('🔄 Verificando estado de autenticación...', tag: 'NotificationService');
      if (_auth.currentUser == null) {
        ReleaseLogger.log('⚠️ No hay usuario autenticado, FCM token se obtendrá después del login', tag: 'NotificationService');
        return;
      }

      ReleaseLogger.log('🔄 Obteniendo FCM token...', tag: 'NotificationService');
      _fcmToken = await _fcm.getToken();

      if (_fcmToken == null) {
        ReleaseLogger.error('❌ No se pudo obtener el FCM token', tag: 'NotificationService');
        ReleaseLogger.error('   Esto puede ocurrir si:', tag: 'NotificationService');
        ReleaseLogger.error('   - Los permisos de notificaciones están denegados', tag: 'NotificationService');
        ReleaseLogger.error('   - No hay conexión a internet', tag: 'NotificationService');
        ReleaseLogger.error('   - El dispositivo no está registrado en APNs (iOS)', tag: 'NotificationService');
        return;
      }

      ReleaseLogger.log('🔑 FCM Token obtenido: ${_fcmToken!.substring(0, 20)}...', tag: 'NotificationService');
      ReleaseLogger.log('💾 Guardando FCM token en Firestore...', tag: 'NotificationService');

      // IMPORTANTE: Limpiar token duplicado de otros usuarios antes de registrar
      await _cleanupDuplicateTokens(_fcmToken!);

      // Guardar token en Firestore (upsert)
      await _upsertUserData({
        'fcmToken': _fcmToken,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      });
      ReleaseLogger.log('✅ FCM token guardado exitosamente', tag: 'NotificationService');

      // Escuchar cambios de token
      _fcm.onTokenRefresh.listen((newToken) async {
        ReleaseLogger.log('🔄 FCM token actualizado', tag: 'NotificationService');
        _fcmToken = newToken;
        if (_auth.currentUser != null) {
          // Limpiar token duplicado de otros usuarios antes de registrar el nuevo
          await _cleanupDuplicateTokens(newToken);

          _upsertUserData({
            'fcmToken': newToken,
            'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      ReleaseLogger.error('Error obteniendo token: $e', tag: 'NotificationService');
      ReleaseLogger.error('   Stack trace: ${StackTrace.current}', tag: 'NotificationService');
    }
  }

  // Inicializar CallKit para llamadas en pantalla completa
  void _initializeCallKit() {
    _callKit.initialize(
      onCallAccepted: (callData) {
        ReleaseLogger.log('✅ CallKit: Llamada aceptada', tag: 'NotificationService');
        // Emitir evento para que la app navegue a la pantalla de llamada
        _incomingCallController.add(callData);
      },
      onCallDeclined: (callId) {
        ReleaseLogger.log('❌ CallKit: Llamada rechazada - $callId', tag: 'NotificationService');
        // Aquí podrías enviar una notificación al llamador de que se rechazó
      },
      onCallEnded: (callId) {
        ReleaseLogger.log('🔚 CallKit: Llamada finalizada - $callId', tag: 'NotificationService');
        // Limpiar recursos si es necesario
      },
    );
    ReleaseLogger.log('✅ CallKit inicializado correctamente', tag: 'NotificationService');
  }

  // Configurar listeners de mensajes
  void _setupListeners() {
    // Mensajes cuando la app está en primer plano
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      ReleaseLogger.log('📨 Mensaje recibido en primer plano: ${message.notification?.title}', tag: 'NotificationService');

      // Verificar si es una videollamada o llamada de audio
      if (message.data['type'] == 'video_call' ||
          message.data['type'] == 'audio_call' ||
          message.data['type'] == 'group_video_call' ||
          message.data['type'] == 'group_audio_call' ||
          message.data['type'] == 'emergency_call') {
        ReleaseLogger.log('📞 ${message.data['type']} entrante detectada en FOREGROUND', tag: 'NotificationService');
        ReleaseLogger.log('📞 Mostrando CallKit incluso en foreground para experiencia nativa', tag: 'NotificationService');

        try {
          if (Platform.isAndroid) {
            // Android usa CallKit
            await _callKit.showIncomingCall(
              callId: message.data['callId'] ?? message.messageId ?? '',
              callerName: message.data['callerName'] ?? 'Usuario',
              callerId: message.data['callerId'] ?? message.data['senderId'] ?? '',
              callerPhotoUrl: message.data['callerPhotoURL'] ?? message.data['senderPhotoUrl'],
              callType: (message.data['type'] == 'audio_call' || message.data['type'] == 'group_audio_call') ? 'audio' : 'video',
              isEmergency: message.data['isEmergency'] == 'true' || message.data['isEmergency'] == true,
              extraData: message.data,
            );
            ReleaseLogger.log('✅ CallKit (Android) mostrado exitosamente en foreground', tag: 'NotificationService');
          } else if (Platform.isIOS) {
            // iOS usa VoIP nativo - las notificaciones VoIP se manejan automáticamente por el sistema
            ReleaseLogger.log('✅ iOS VoIP - las llamadas se manejan automáticamente por el sistema', tag: 'NotificationService');
            // En iOS, las notificaciones VoIP push aparecen automáticamente como CallKit
            // No necesitamos hacer nada adicional aquí
          }
        } catch (e) {
          ReleaseLogger.error('ERROR mostrando notificación nativa en foreground: $e', tag: 'NotificationService');
        }
        return;
      } else {
        // ✅ NO mostrar notificaciones push cuando la app está en foreground
        // Las custom notifications (ForegroundMessageListener) se encargan de mostrar los mensajes
        ReleaseLogger.log('✅ App en foreground - mensaje manejado por custom notifications (no push)', tag: 'NotificationService');
        return;
      }
    });

    // Mensajes cuando se toca la notificación (app en segundo plano)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      ReleaseLogger.log('🔔 Notificación tocada: ${message.notification?.title}', tag: 'NotificationService');
      _handleNotificationTap(message.data);
    });

    // Verificar si la app se abrió desde una notificación
    _fcm.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        ReleaseLogger.log('🚀 App abierta desde notificación: ${message.notification?.title}', tag: 'NotificationService');
        // Delay para dar tiempo a que los shells se inicialicen y agreguen sus listeners
        Future.delayed(Duration(milliseconds: 500), () {
          _handleNotificationTap(message.data);
        });
      }
    });
  }

  // Mostrar notificación local
  Future<void> _showLocalNotification(RemoteMessage message) async {
    try {
      // Verificar usuario actual
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.log('⚠️ No hay usuario autenticado', tag: 'NotificationService');
        return;
      }

      // Obtener tipo de notificación
      final notificationType = message.data['type'] ?? 'unknown';
      final senderId = message.data['senderId'];

      ReleaseLogger.log('📨 Procesando notificación local:', tag: 'NotificationService');
      ReleaseLogger.log('   Tipo: $notificationType', tag: 'NotificationService');
      ReleaseLogger.log('   Usuario: ${currentUser.uid.substring(0, 8)}...', tag: 'NotificationService');

      // Verificar si se debe mostrar la notificación
      final decision = await _filter.shouldSendNotification(
        userId: currentUser.uid,
        notificationType: notificationType,
        senderId: senderId,
      );

      if (!decision.shouldSend) {
        ReleaseLogger.log('🚫 Notificación bloqueada: ${decision.reason}', tag: 'NotificationService');
        return;
      }

      ReleaseLogger.log('✅ Notificación permitida: ${decision.reason}', tag: 'NotificationService');

      // Obtener configuración de sonido
      final soundConfig = await _filter.getSoundConfig(currentUser.uid);

      // Obtener la URL de la foto del remitente
      final senderPhotoUrl = message.data['senderPhotoUrl'];

      // Preparar la foto del remitente para Android
      String? largeIconPath;

      // Solo para Android: descargar y procesar foto del remitente como largeIcon
      if (Platform.isAndroid && senderPhotoUrl != null && senderPhotoUrl.isNotEmpty && senderPhotoUrl != 'null') {
        try {
          ReleaseLogger.log('📥 [Android] Descargando foto del remitente: $senderPhotoUrl', tag: 'NotificationService');
          final response = await http.get(Uri.parse(senderPhotoUrl)).timeout(Duration(seconds: 5));

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            // Decodificar la imagen
            final originalImage = img.decodeImage(response.bodyBytes);

            if (originalImage != null) {
              // Redimensionar a 192x192 (tamaño óptimo para largeIcon en Android)
              final resizedImage = img.copyResize(
                originalImage,
                width: 192,
                height: 192,
                interpolation: img.Interpolation.linear,
              );

              // Convertir a PNG para asegurar compatibilidad
              final pngBytes = img.encodePng(resizedImage);

              // Guardar la imagen procesada
              final directory = await getTemporaryDirectory();
              final filePath = '${directory.path}/sender_photo_${DateTime.now().millisecondsSinceEpoch}.png';
              final file = File(filePath);
              await file.writeAsBytes(pngBytes);

              if (await file.exists()) {
                largeIconPath = filePath;
                ReleaseLogger.log('✅ [Android] Foto del remitente procesada y guardada: $largeIconPath', tag: 'NotificationService');
              }
            } else {
              ReleaseLogger.log('⚠️ [Android] No se pudo decodificar la imagen', tag: 'NotificationService');
            }
          } else {
            ReleaseLogger.log('⚠️ [Android] Respuesta inválida: ${response.statusCode}, bytes: ${response.bodyBytes.length}', tag: 'NotificationService');
          }
        } catch (e) {
          ReleaseLogger.error('⚠️ [Android] Error descargando/procesando foto de perfil: $e', tag: 'NotificationService');
        }
      }

      // Si no hay foto del remitente en Android, usar logo de la app
      if (Platform.isAndroid && largeIconPath == null) {
        try {
          ReleaseLogger.log('📥 [Android] Cargando y procesando logo de fallback...', tag: 'NotificationService');
          final ByteData logoData = await rootBundle.load('assets/images/logo.png');
          final logoBytes = logoData.buffer.asUint8List();

          // Decodificar y procesar el logo igual que la foto de perfil
          final logoImage = img.decodeImage(logoBytes);

          if (logoImage != null) {
            // Redimensionar a 192x192
            final resizedLogo = img.copyResize(
              logoImage,
              width: 192,
              height: 192,
              interpolation: img.Interpolation.linear,
            );

            // Convertir a PNG
            final pngBytes = img.encodePng(resizedLogo);

            // Guardar
            final directory = await getTemporaryDirectory();
            final filePath = '${directory.path}/app_logo_processed.png';
            final file = File(filePath);
            await file.writeAsBytes(pngBytes);

            if (await file.exists()) {
              largeIconPath = filePath;
              ReleaseLogger.log('✅ [Android] Logo procesado y guardado: $largeIconPath', tag: 'NotificationService');
            }
          }
        } catch (e) {
          ReleaseLogger.error('⚠️ [Android] Error cargando/procesando logo de la app: $e', tag: 'NotificationService');
        }
      }

      // Configuración para Android con foto circular (largeIcon)
      AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'high_importance_channel',
        'Notificaciones Importantes',
        channelDescription: 'Canal para notificaciones importantes',
        importance: Importance.high,
        priority: Priority.high,
        enableVibration: soundConfig.vibrationEnabled,
        playSound: soundConfig.soundEnabled,
        icon: '@mipmap/ic_launcher',
        // largeIcon circular (se muestra como círculo en Android)
        largeIcon: largeIconPath != null ? FilePathAndroidBitmap(largeIconPath) : null,
      );

      // Configuración para iOS SIN attachments
      // En iOS, el ícono de la app siempre aparece a la izquierda
      // NO agregamos attachments para evitar que la foto aparezca a la derecha
      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundConfig.soundEnabled,
        // Sin attachments para que no aparezca nada a la derecha
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Convertir data a JSON para poder parsearlo después
      String payload = '';
      try {
        payload = message.data.isNotEmpty ? jsonEncode(message.data) : '';
      } catch (e) {
        ReleaseLogger.error('⚠️ Error codificando payload: $e', tag: 'NotificationService');
      }

      await _localNotifications.show(
        message.hashCode,
        message.notification?.title ?? 'Talia',
        message.notification?.body ?? '',
        details,
        payload: payload,
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error mostrando notificación local: $e', tag: 'NotificationService');
    }
  }

  // Manejar tap en notificación local
  void _onNotificationTapped(NotificationResponse response) {
    ReleaseLogger.log('👆 Notificación local tocada: ${response.payload}', tag: 'NotificationService');

    if (response.payload != null && response.payload!.isNotEmpty) {
      try {
        // Parsear el JSON del payload
        final data = jsonDecode(response.payload!) as Map<String, dynamic>;
        ReleaseLogger.log('📦 Datos parseados: $data', tag: 'NotificationService');

        // Manejar según el tipo
        _handleNotificationTap(data);
      } catch (e) {
        ReleaseLogger.error('❌ Error parseando payload: $e', tag: 'NotificationService');
      }
    }
  }

  // Manejar tap en notificación
  void _handleNotificationTap(Map<String, dynamic> data) {
    ReleaseLogger.log('📍 Navegando según tipo: ${data['type']}', tag: 'NotificationService');

    // Si es una videollamada o llamada de audio, emitir evento para mostrar el diálogo
    if (data['type'] == 'video_call' || data['type'] == 'audio_call') {
      ReleaseLogger.log('📞 Notificación de ${data['type'] == 'video_call' ? 'videollamada' : 'llamada de audio'} tocada, mostrando diálogo', tag: 'NotificationService');
      // Marcar como originado desde tap de notificación (no CallKit acceptance)
      data['fromNotificationTap'] = true;
      _incomingCallController.add(data);
    } else if (data['type'] == 'chat_message' || data['type'] == 'group_message') {
      ReleaseLogger.log('💬 Notificación de ${data['type'] == 'group_message' ? 'mensaje grupal' : 'chat'} tocada, navegando', tag: 'NotificationService');

      // Marcar el chat como ignorado en el ForegroundMessageListener
      // para evitar que se muestre un banner custom inmediatamente
      final chatId = data['chatId'] as String?;
      if (chatId != null) {
        ReleaseLogger.log('🔕 Marcando chat $chatId como ignorado en ForegroundMessageListener', tag: 'NotificationService');
        ForegroundMessageListener().markChatOpenedFromNotification(chatId);
      }

      _chatNotificationTapController.add(data);
    } else if (data['type'] == 'contact_request') {
      ReleaseLogger.log('👥 Notificación de solicitud de contacto tocada, navegando a contactos', tag: 'NotificationService');
      _contactRequestNotificationTapController.add(data);
    } else if (data['type'] == 'emergency') {
      ReleaseLogger.log('🆘 Notificación de emergencia tocada, navegando a detalles', tag: 'NotificationService');
      _emergencyNotificationTapController.add(data);
    }
  }

  // ==================== ENVIAR NOTIFICACIONES ====================

  /// Helper para crear notificación en Firestore después de verificar filtros
  ///
  /// Retorna true si la notificación fue creada, false si fue bloqueada
  Future<bool> _createNotificationIfAllowed({
    required String userId,
    required String notificationType,
    required String title,
    required String body,
    required Map<String, dynamic> data,
    String? senderId,
    String? imageUrl,
  }) async {
    try {
      // Verificar si se debe enviar
      final decision = await _filter.shouldSendNotification(
        userId: userId,
        notificationType: notificationType,
        senderId: senderId,
      );

      if (!decision.shouldSend) {
        ReleaseLogger.log('🚫 Notificación bloqueada para usuario ${userId.substring(0, 8)}...: ${decision.reason}', tag: 'NotificationService');
        return false;
      }

      // ⚠️ NOTA: Las notificaciones son creadas por Cloud Functions, no por el cliente
      // Las Cloud Functions tienen permisos de administrador y pueden crear notificaciones de forma segura
      // El cliente solo envía mensajes, y las Cloud Functions detectan esos mensajes y crean las notificaciones

      // CÓDIGO COMENTADO - Las Cloud Functions se encargan de crear las notificaciones
      // final priority = NotificationTypes.getPriority(notificationType);
      // await _firestore.collection('notifications').add({
      //   'userId': userId,
      //   'senderId': senderId,
      //   'type': notificationType,
      //   'title': title,
      //   'body': body,
      //   'imageUrl': imageUrl,
      //   'data': data,
      //   'timestamp': FieldValue.serverTimestamp(),
      //   'read': false,
      //   'priority': priority,
      // });

      ReleaseLogger.log('✅ Notificación delegada a Cloud Functions para usuario ${userId.substring(0, 8)}... (tipo: $notificationType)', tag: 'NotificationService');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error creando notificación: $e', tag: 'NotificationService');
      return false;
    }
  }

  // Enviar notificación de solicitud de permiso para grupo
  Future<void> sendGroupInvitationPermissionRequest({
    required String parentId,
    required String childName,
    required String groupName,
    required String contactName,
    required String inviterName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'group_permission_request',
        'title': '🔒 Solicitud de Grupo para $childName',
        'body': '$inviterName quiere agregar a $childName al grupo "$groupName". Necesita aprobar el contacto con $contactName.',
        'data': {
          'type': 'group_permission_request',
          'childName': childName,
          'groupName': groupName,
          'contactName': contactName,
          'inviterName': inviterName,
        },
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': 'high',
      });

      ReleaseLogger.log('✅ Notificación de solicitud de grupo enviada al padre: $parentId', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de grupo: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de membresía aprobada
  Future<void> sendGroupMembershipApproved({
    required String userId,
    required String groupName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': userId,
        'type': 'group_membership_approved',
        'title': '🎉 ¡Te agregaron al grupo!',
        'body': 'Ya puedes chatear en el grupo "$groupName"',
        'data': {
          'type': 'group_membership_approved',
          'groupName': groupName,
        },
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': 'normal',
      });

      ReleaseLogger.log('✅ Notificación de membresía aprobada enviada a: $userId', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de membresía: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de nuevo mensaje en grupo
  Future<void> sendGroupMessageNotification({
    required String groupId,
    required String groupName,
    required String senderName,
    required String messageText,
    required List<String> memberIds,
    required String senderId,
  }) async {
    try {
      // Enviar a todos los miembros excepto al remitente
      final recipientIds = memberIds.where((id) => id != senderId).toList();

      for (final recipientId in recipientIds) {
        await _firestore.collection('notifications').add({
          'userId': recipientId,
          'type': 'group_message',
          'title': '💬 $groupName',
          'body': '$senderName: $messageText',
          'data': {
            'type': 'group_message',
            'groupId': groupId,
            'groupName': groupName,
            'senderId': senderId,
            'senderName': senderName,
          },
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
          'priority': 'normal',
        });
      }

      ReleaseLogger.log('✅ Notificaciones de grupo enviadas a ${recipientIds.length} miembros', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificaciones de grupo: $e', tag: 'NotificationService');
    }
  }

  // Enviar recordatorio a padres sobre solicitudes pendientes
  Future<void> sendGroupPermissionReminder({
    required String parentId,
    required String childName,
    required String groupName,
    required int pendingDays,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'group_permission_reminder',
        'title': '⏰ Recordatorio: Solicitud de Grupo Pendiente',
        'body': 'Hace $pendingDays días que $childName está esperando unirse al grupo "$groupName". ¿Puedes revisar la solicitud?',
        'data': {
          'type': 'group_permission_reminder',
          'childName': childName,
          'groupName': groupName,
          'pendingDays': pendingDays,
        },
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': 'normal',
      });

      ReleaseLogger.log('✅ Recordatorio de grupo enviado al padre: $parentId', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando recordatorio de grupo: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de nuevo mensaje de chat
  Future<void> sendChatMessageNotification({
    required String recipientId,
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required String messageText,
    required String chatId,
    bool isGroup = false,
    String? groupName,
  }) async {
    try {
      ReleaseLogger.log('📤 Enviando notificación de mensaje:', tag: 'NotificationService');
      ReleaseLogger.log('   - Destinatario: $recipientId', tag: 'NotificationService');
      ReleaseLogger.log('   - Remitente: $senderId ($senderName)', tag: 'NotificationService');
      ReleaseLogger.log('   - Chat ID: $chatId', tag: 'NotificationService');
      ReleaseLogger.log('   - Mensaje: ${messageText.substring(0, messageText.length > 50 ? 50 : messageText.length)}...', tag: 'NotificationService');

      // Preparar datos
      final messagePreview = messageText.length > 100
          ? '${messageText.substring(0, 100)}...'
          : messageText;

      final title = isGroup ? '👥 $groupName' : '💬 $senderName';
      final body = isGroup ? '$senderName: $messagePreview' : messagePreview;

      final data = {
        'type': NotificationTypes.chatMessage,
        'senderId': senderId,
        'senderName': senderName,
        'senderPhotoUrl': senderPhotoUrl ?? '',
        'chatId': chatId,
        'messagePreview': messageText,
        'isGroup': isGroup,
        'groupName': groupName ?? '',
      };

      // Crear notificación si está permitida
      final created = await _createNotificationIfAllowed(
        userId: recipientId,
        notificationType: NotificationTypes.chatMessage,
        title: title,
        body: body,
        data: data,
        senderId: senderId,
        imageUrl: senderPhotoUrl,
      );

      if (created) {
        ReleaseLogger.log('   → La Cloud Function debería enviarla automáticamente', tag: 'NotificationService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de mensaje: $e', tag: 'NotificationService');
      ReleaseLogger.error('   Stack trace: ${StackTrace.current}', tag: 'NotificationService');
    }
  }

  // Enviar notificación de nueva solicitud de contacto
  Future<void> sendContactRequestNotification({
    required String parentId,
    required String childName,
    required String contactName,
    String? childId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: parentId,
        notificationType: NotificationTypes.contactRequest,
        title: '🔔 Nueva solicitud de contacto',
        body: '$childName quiere agregar a $contactName',
        data: {
          'type': NotificationTypes.contactRequest,
          'childName': childName,
          'contactName': contactName,
          'childId': childId,
        },
        senderId: childId,
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de solicitud: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de contacto aprobado
  Future<void> sendContactApprovedNotification({
    required String childId,
    required String contactName,
    String? parentId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: childId,
        notificationType: NotificationTypes.contactApproved,
        title: '✅ Contacto aprobado',
        body: 'Tus padres aprobaron a $contactName. Ya puedes chatear!',
        data: {
          'type': NotificationTypes.contactApproved,
          'contactName': contactName,
        },
        senderId: parentId,
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de aprobación: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de aprobación automática al padre
  Future<void> sendAutoApprovalNotification({
    required String parentId,
    required String childId,
    required String contactName,
  }) async {
    try {
      // Obtener el nombre del hijo
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childName = childDoc.data()?['name'] ?? 'Tu hijo';

      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'auto_approval',
        'title': '🤖 Aprobación automática',
        'body': 'Se aprobó automáticamente a "$contactName" para $childName',
        'data': {
          'type': 'auto_approval',
          'childId': childId,
          'childName': childName,
          'contactName': contactName,
        },
        'read': false,
        'timestamp': FieldValue.serverTimestamp(),
        'priority': 'normal',
      });

      ReleaseLogger.log('✅ Notificación de aprobación automática enviada al padre', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de aprobación automática: $e', tag: 'NotificationService');
    }
  }

  // Enviar alerta de bullying
  Future<void> sendBullyingAlert({
    required String parentId,
    required String childName,
    required double severity,
    String? childId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: parentId,
        notificationType: NotificationTypes.bullyingAlert,
        title: '⚠️ ALERTA: Posible bullying detectado',
        body: 'Se detectó contenido preocupante en mensajes de $childName',
        data: {
          'type': NotificationTypes.bullyingAlert,
          'childName': childName,
          'severity': severity,
          'childId': childId,
        },
        senderId: childId,
      );
      ReleaseLogger.log('⚠️ Alerta de bullying enviada/verificada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando alerta de bullying: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de reporte disponible
  Future<void> sendReportReadyNotification({
    required String parentId,
    required String childName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': parentId,
        'type': 'report_ready',
        'title': '📊 Reporte semanal disponible',
        'body': 'El reporte de $childName está listo para revisar',
        'data': {'type': 'report_ready', 'childName': childName},
        'read': false,
        'timestamp': FieldValue.serverTimestamp(),
        'priority': 'normal',
      });

      ReleaseLogger.log('📊 Notificación de reporte enviada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de historia pendiente de aprobación
  Future<void> sendStoryApprovalRequestNotification({
    required String parentId,
    required String childName,
    required String storyId,
    String? childId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: parentId,
        notificationType: NotificationTypes.storyApprovalRequest,
        title: '📸 Nueva historia pendiente',
        body: '$childName quiere compartir una historia. ¡Revísala y apruébala!',
        data: {
          'type': NotificationTypes.storyApprovalRequest,
          'childName': childName,
          'storyId': storyId,
          'childId': childId,
        },
        senderId: childId,
      );
      ReleaseLogger.log('📸 Notificación de historia pendiente enviada/verificada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de historia: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de historia aprobada
  Future<void> sendStoryApprovedNotification({
    required String childId,
    String? parentId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: childId,
        notificationType: NotificationTypes.storyApproved,
        title: '✅ Historia aprobada',
        body: '¡Genial! Tus padres aprobaron tu historia. Ya está visible para tus contactos.',
        data: {
          'type': NotificationTypes.storyApproved,
        },
        senderId: parentId,
      );
      ReleaseLogger.log('✅ Notificación de historia aprobada enviada/verificada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de aprobación: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de historia rechazada
  Future<void> sendStoryRejectedNotification({
    required String childId,
    String? reason,
    String? parentId,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: childId,
        notificationType: NotificationTypes.storyRejected,
        title: '❌ Historia rechazada',
        body: reason != null && reason.isNotEmpty
            ? 'Tus padres rechazaron tu historia: $reason'
            : 'Tus padres rechazaron tu historia. Intenta con otro contenido.',
        data: {
          'type': NotificationTypes.storyRejected,
          'reason': reason,
        },
        senderId: parentId,
      );
      ReleaseLogger.log('❌ Notificación de historia rechazada enviada/verificada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de rechazo: $e', tag: 'NotificationService');
    }
  }

  // Enviar notificación de respuesta a historia
  Future<void> sendStoryReplyNotification({
    required String userId,
    required String replierName,
    required String replyText,
  }) async {
    try {
      await _createNotificationIfAllowed(
        userId: userId,
        notificationType: NotificationTypes.storyReply,
        title: '💬 Nueva respuesta a tu historia',
        body: '$replierName respondió: $replyText',
        data: {
          'type': NotificationTypes.storyReply,
          'replierName': replierName,
          'replyText': replyText,
        },
      );
      ReleaseLogger.log('💬 Notificación de respuesta a historia enviada/verificada', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando notificación de respuesta: $e', tag: 'NotificationService');
    }
  }

  // Obtener notificaciones no leídas
  Stream<QuerySnapshot> getUnreadNotifications(String userId) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('read', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  // Marcar notificación como leída
  Future<void> markAsRead(String notificationId) async {
    try {
      await _firestore.collection('notifications').doc(notificationId).update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error('❌ Error marcando como leída: $e', tag: 'NotificationService');
    }
  }

  // Marcar todas como leídas
  Future<void> markAllAsRead(String userId) async {
    try {
      final batch = _firestore.batch();
      final notifications = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .where('read', isEqualTo: false)
          .get();

      for (var doc in notifications.docs) {
        batch.update(doc.reference, {
          'read': true,
          'readAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
      ReleaseLogger.log('✅ Todas las notificaciones marcadas como leídas', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error marcando todas como leídas: $e', tag: 'NotificationService');
    }
  }

  // Obtener contador de notificaciones no leídas
  Stream<int> getUnreadCount(String userId) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('read', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  // Limpiar token al cerrar sesión
  Future<void> clearToken() async {
    try {
      if (_auth.currentUser != null) {
        await _firestore.collection('users').doc(_auth.currentUser!.uid).update(
          {'fcmToken': FieldValue.delete()},
        );
      }
      _fcmToken = null;
      ReleaseLogger.log('🗑️ Token FCM limpiado', tag: 'NotificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error limpiando token: $e', tag: 'NotificationService');
    }
  }

  /// Limpia todas las notificaciones de un chat específico (1-1 o grupo)
  Future<void> clearChatNotifications(String chatId, {bool isGroup = false}) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      ReleaseLogger.log('🗑️ Limpiando notificaciones para chat: $chatId (isGroup: $isGroup)', tag: 'NotificationService');

      // Buscar todas las notificaciones del usuario para este chat
      final query = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: user.uid)
          .where('chatId', isEqualTo: chatId)
          .get();

      if (query.docs.isEmpty) {
        ReleaseLogger.log('ℹ️ No hay notificaciones para limpiar en chat: $chatId', tag: 'NotificationService');
        return;
      }

      // Borrar todas las notificaciones encontradas
      final batch = _firestore.batch();
      for (final doc in query.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      ReleaseLogger.log('✅ Limpiadas ${query.docs.length} notificaciones para chat: $chatId', tag: 'NotificationService');

      // Opcional: También limpiar notificaciones locales del sistema
      if (Platform.isAndroid || Platform.isIOS) {
        // Nota: No hay forma directa de limpiar notificaciones específicas del sistema
        // sin un ID específico, pero las nuevas notificaciones no aparecerán
        await _localNotifications.cancelAll();
        ReleaseLogger.log('🗑️ Notificaciones locales limpiadas', tag: 'NotificationService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error limpiando notificaciones del chat $chatId: $e', tag: 'NotificationService');
    }
  }

  /// Limpia todas las notificaciones de un grupo específico (alias para claridad)
  Future<void> clearGroupNotifications(String groupId) async {
    return clearChatNotifications(groupId, isGroup: true);
  }
}
