import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'constants/notification_types.dart';
import 'services/notification_filter.dart';

// Manejador de mensajes en segundo plano (debe estar fuera de la clase)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('📩 Mensaje en segundo plano: ${message.notification?.title}');
  print('📦 Tipo: ${message.data['type']}');
  print('📦 Data: ${message.data}');

  // Las notificaciones de llamadas se manejan automáticamente por el sistema
  // No necesitamos mostrar notificación local aquí porque FCM ya lo hace
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

  String? _fcmToken;
  bool _isInitialized = false;
  String? _activeChatId; // ID del chat actualmente abierto

  // Stream para notificar videollamadas entrantes
  final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingCallStream => _incomingCallController.stream;

  // Stream para notificar cuando se toca una notificación de chat
  final _chatNotificationTapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get chatNotificationTapStream => _chatNotificationTapController.stream;

  // Stream para notificar cuando se toca una notificación de emergencia
  final _emergencyNotificationTapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get emergencyNotificationTapStream => _emergencyNotificationTapController.stream;

  // Establecer el chat activo (para filtrar notificaciones)
  void setActiveChatId(String? chatId) {
    _activeChatId = chatId;
    print('🔔 Chat activo actualizado: ${chatId ?? 'ninguno'}');
  }

  // Método público para emitir llamadas entrantes al stream
  void emitIncomingCall(Map<String, dynamic> callData) {
    _incomingCallController.add(callData);
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

  // Inicializar servicio de notificaciones
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 1. Configurar manejador de mensajes en segundo plano
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );

      // 2. Solicitar permisos
      await _requestPermissions();

      // 3. Configurar notificaciones locales
      await _initializeLocalNotifications();

      // 4. Obtener token FCM
      await _getFCMToken();

      // 5. Configurar listeners
      _setupListeners();

      _isInitialized = true;
      print('✅ Servicio de notificaciones inicializado');
    } catch (e) {
      print('❌ Error inicializando notificaciones: $e');
    }
  }

  // Solicitar permisos de notificaciones
  Future<void> _requestPermissions() async {
    try {
      print('🔔 Solicitando permisos de notificaciones...');
      final settings = await _fcm.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      print('📱 Permisos de notificaciones: ${settings.authorizationStatus}');
      print('   Alert: ${settings.alert}');
      print('   Badge: ${settings.badge}');
      print('   Sound: ${settings.sound}');

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        print('✅ Permisos concedidos');
      } else if (settings.authorizationStatus ==
          AuthorizationStatus.provisional) {
        print('⚠️ Permisos provisionales');
      } else {
        print('❌ Permisos denegados o no decididos');
        print('   Status: ${settings.authorizationStatus}');
        print('⚠️ Para habilitar notificaciones:');
        print('   1. Ve a Ajustes > Talia > Notificaciones');
        print('   2. Activa "Permitir notificaciones"');
      }
    } catch (e) {
      print('❌ Error solicitando permisos: $e');
      print('   Stack trace: ${StackTrace.current}');
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
      print('🔄 Obteniendo FCM token...');
      _fcmToken = await _fcm.getToken();

      if (_fcmToken == null) {
        print('❌ No se pudo obtener el FCM token');
        print('   Esto puede ocurrir si:');
        print('   - Los permisos de notificaciones están denegados');
        print('   - No hay conexión a internet');
        print('   - El dispositivo no está registrado en APNs (iOS)');
        return;
      }

      print('🔑 FCM Token obtenido: ${_fcmToken!.substring(0, 20)}...');

      if (_auth.currentUser != null) {
        print('💾 Guardando FCM token en Firestore...');
        // Guardar token en Firestore (upsert)
        await _upsertUserData({
          'fcmToken': _fcmToken,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        });
        print('✅ FCM token guardado exitosamente');
      } else {
        print('⚠️ No hay usuario autenticado, no se guardó el FCM token');
      }

      // Escuchar cambios de token
      _fcm.onTokenRefresh.listen((newToken) {
        print('🔄 FCM token actualizado');
        _fcmToken = newToken;
        if (_auth.currentUser != null) {
          _upsertUserData({
            'fcmToken': newToken,
            'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      print('❌ Error obteniendo token: $e');
      print('   Stack trace: ${StackTrace.current}');
    }
  }

  // Configurar listeners de mensajes
  void _setupListeners() {
    // Mensajes cuando la app está en primer plano
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print(
        '📨 Mensaje recibido en primer plano: ${message.notification?.title}',
      );

      // Verificar si es una videollamada o llamada de audio
      if (message.data['type'] == 'video_call' || message.data['type'] == 'audio_call') {
        print('📞 ${message.data['type'] == 'video_call' ? 'Videollamada' : 'Llamada de audio'} entrante detectada');
        _incomingCallController.add(message.data);
      } else if (message.data['type'] == 'chat_message') {
        // Mostrar notificación de mensaje solo si no está en el chat activo
        final messageChatId = message.data['chatId'];
        if (messageChatId != null && messageChatId == _activeChatId) {
          print('💬 Mensaje del chat activo - no mostrar notificación');
          return;
        }
        print('💬 Mensaje de chat recibido en primer plano - mostrando notificación');
        _showLocalNotification(message);
      } else {
        // Mostrar notificación normal para otros tipos
        _showLocalNotification(message);
      }
    });

    // Mensajes cuando se toca la notificación (app en segundo plano)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('🔔 Notificación tocada: ${message.notification?.title}');
      _handleNotificationTap(message.data);
    });

    // Verificar si la app se abrió desde una notificación
    _fcm.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print(
          '🚀 App abierta desde notificación: ${message.notification?.title}',
        );
        _handleNotificationTap(message.data);
      }
    });
  }

  // Mostrar notificación local
  Future<void> _showLocalNotification(RemoteMessage message) async {
    try {
      // Verificar usuario actual
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        print('⚠️ No hay usuario autenticado');
        return;
      }

      // Obtener tipo de notificación
      final notificationType = message.data['type'] ?? 'unknown';
      final senderId = message.data['senderId'];

      print('📨 Procesando notificación local:');
      print('   Tipo: $notificationType');
      print('   Usuario: ${currentUser.uid.substring(0, 8)}...');

      // Verificar si se debe mostrar la notificación
      final decision = await _filter.shouldSendNotification(
        userId: currentUser.uid,
        notificationType: notificationType,
        senderId: senderId,
      );

      if (!decision.shouldSend) {
        print('🚫 Notificación bloqueada: ${decision.reason}');
        return;
      }

      print('✅ Notificación permitida: ${decision.reason}');

      // Obtener configuración de sonido
      final soundConfig = await _filter.getSoundConfig(currentUser.uid);

      // Obtener la URL de la foto del remitente
      final senderPhotoUrl = message.data['senderPhotoUrl'];

      // Preparar la foto del remitente para Android
      String? largeIconPath;

      // Solo para Android: descargar foto del remitente como largeIcon
      if (Platform.isAndroid && senderPhotoUrl != null && senderPhotoUrl.isNotEmpty && senderPhotoUrl != 'null') {
        try {
          print('📥 [Android] Descargando foto del remitente: $senderPhotoUrl');
          final response = await http.get(Uri.parse(senderPhotoUrl)).timeout(Duration(seconds: 5));

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            // Guardar directamente sin procesamiento
            final directory = await getTemporaryDirectory();
            final filePath = '${directory.path}/sender_photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
            final file = File(filePath);
            await file.writeAsBytes(response.bodyBytes);

            if (await file.exists()) {
              largeIconPath = filePath;
              print('✅ [Android] Foto del remitente guardada: $largeIconPath');
            }
          } else {
            print('⚠️ [Android] Respuesta inválida: ${response.statusCode}, bytes: ${response.bodyBytes.length}');
          }
        } catch (e) {
          print('⚠️ [Android] Error descargando foto de perfil: $e');
        }
      }

      // Si no hay foto del remitente en Android, usar logo de la app
      if (Platform.isAndroid && largeIconPath == null) {
        try {
          print('📥 [Android] Cargando logo de fallback...');
          final ByteData logoData = await rootBundle.load('assets/images/logo.png');

          // Guardar directamente sin procesamiento
          final directory = await getTemporaryDirectory();
          final filePath = '${directory.path}/app_logo.png';
          final file = File(filePath);
          await file.writeAsBytes(logoData.buffer.asUint8List());

          if (await file.exists()) {
            largeIconPath = filePath;
            print('✅ [Android] Logo guardado: $largeIconPath');
          }
        } catch (e) {
          print('⚠️ [Android] Error cargando logo de la app: $e');
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
        print('⚠️ Error codificando payload: $e');
      }

      await _localNotifications.show(
        message.hashCode,
        message.notification?.title ?? 'Talia',
        message.notification?.body ?? '',
        details,
        payload: payload,
      );
    } catch (e) {
      print('❌ Error mostrando notificación local: $e');
    }
  }

  // Guardar imagen en archivo temporal con orientación corregida
  Future<String> _saveImageToFile(List<int> bytes, String fileName) async {
    try {
      // Convertir a Uint8List
      final imageBytes = Uint8List.fromList(bytes);

      // Decodificar la imagen
      img.Image? image = img.decodeImage(imageBytes);

      if (image == null) {
        // Si no se puede decodificar, guardar los bytes originales
        print('⚠️ No se pudo decodificar la imagen, guardando bytes originales');
        final directory = await getTemporaryDirectory();
        final filePath = '${directory.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        return filePath;
      }

      // Corregir orientación automáticamente basándose en metadatos EXIF
      // La función bakeOrientation corrige la orientación y elimina el flag EXIF
      image = img.bakeOrientation(image);

      // Codificar la imagen corregida como JPG
      final correctedBytes = img.encodeJpg(image, quality: 90);

      // Guardar la imagen corregida
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(correctedBytes);

      print('✅ Imagen guardada con orientación corregida: $filePath');
      return filePath;
    } catch (e) {
      print('❌ Error procesando imagen: $e');
      // En caso de error, guardar bytes originales
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      return filePath;
    }
  }

  // Manejar tap en notificación local
  void _onNotificationTapped(NotificationResponse response) {
    print('👆 Notificación local tocada: ${response.payload}');

    if (response.payload != null && response.payload!.isNotEmpty) {
      try {
        // Parsear el JSON del payload
        final data = jsonDecode(response.payload!) as Map<String, dynamic>;
        print('📦 Datos parseados: $data');

        // Manejar según el tipo
        _handleNotificationTap(data);
      } catch (e) {
        print('❌ Error parseando payload: $e');
      }
    }
  }

  // Manejar tap en notificación
  void _handleNotificationTap(Map<String, dynamic> data) {
    print('📍 Navegando según tipo: ${data['type']}');

    // Si es una videollamada o llamada de audio, emitir evento para mostrar el diálogo
    if (data['type'] == 'video_call' || data['type'] == 'audio_call') {
      print('📞 Notificación de ${data['type'] == 'video_call' ? 'videollamada' : 'llamada de audio'} tocada, mostrando diálogo');
      _incomingCallController.add(data);
    } else if (data['type'] == 'chat_message') {
      print('💬 Notificación de chat tocada, navegando al chat');
      _chatNotificationTapController.add(data);
    } else if (data['type'] == 'emergency') {
      print('🆘 Notificación de emergencia tocada, navegando a detalles');
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
        print('🚫 Notificación bloqueada para usuario ${userId.substring(0, 8)}...: ${decision.reason}');
        return false;
      }

      // Crear notificación en Firestore
      final priority = NotificationTypes.getPriority(notificationType);

      await _firestore.collection('notifications').add({
        'userId': userId,
        'senderId': senderId,
        'type': notificationType,
        'title': title,
        'body': body,
        'imageUrl': imageUrl,
        'data': data,
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'priority': priority,
      });

      print('✅ Notificación creada para usuario ${userId.substring(0, 8)}... (tipo: $notificationType)');
      return true;
    } catch (e) {
      print('❌ Error creando notificación: $e');
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

      print('✅ Notificación de solicitud de grupo enviada al padre: $parentId');
    } catch (e) {
      print('❌ Error enviando notificación de grupo: $e');
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

      print('✅ Notificación de membresía aprobada enviada a: $userId');
    } catch (e) {
      print('❌ Error enviando notificación de membresía: $e');
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

      print('✅ Notificaciones de grupo enviadas a ${recipientIds.length} miembros');
    } catch (e) {
      print('❌ Error enviando notificaciones de grupo: $e');
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

      print('✅ Recordatorio de grupo enviado al padre: $parentId');
    } catch (e) {
      print('❌ Error enviando recordatorio de grupo: $e');
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
      print('📤 Enviando notificación de mensaje:');
      print('   - Destinatario: $recipientId');
      print('   - Remitente: $senderId ($senderName)');
      print('   - Chat ID: $chatId');
      print('   - Mensaje: ${messageText.substring(0, messageText.length > 50 ? 50 : messageText.length)}...');

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
        print('   → La Cloud Function debería enviarla automáticamente');
      }
    } catch (e) {
      print('❌ Error enviando notificación de mensaje: $e');
      print('   Stack trace: ${StackTrace.current}');
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
      print('❌ Error enviando notificación de solicitud: $e');
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
      print('❌ Error enviando notificación de aprobación: $e');
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

      print('✅ Notificación de aprobación automática enviada al padre');
    } catch (e) {
      print('❌ Error enviando notificación de aprobación automática: $e');
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
      print('⚠️ Alerta de bullying enviada/verificada');
    } catch (e) {
      print('❌ Error enviando alerta de bullying: $e');
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

      print('📊 Notificación de reporte enviada');
    } catch (e) {
      print('❌ Error enviando notificación: $e');
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
      print('📸 Notificación de historia pendiente enviada/verificada');
    } catch (e) {
      print('❌ Error enviando notificación de historia: $e');
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
      print('✅ Notificación de historia aprobada enviada/verificada');
    } catch (e) {
      print('❌ Error enviando notificación de aprobación: $e');
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
      print('❌ Notificación de historia rechazada enviada/verificada');
    } catch (e) {
      print('❌ Error enviando notificación de rechazo: $e');
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
      print('❌ Error marcando como leída: $e');
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
      print('✅ Todas las notificaciones marcadas como leídas');
    } catch (e) {
      print('❌ Error marcando todas como leídas: $e');
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
      print('🗑️ Token FCM limpiado');
    } catch (e) {
      print('❌ Error limpiando token: $e');
    }
  }
}
