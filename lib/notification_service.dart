import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import 'dart:async';

// Manejador de mensajes en segundo plano (debe estar fuera de la clase)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('📩 Mensaje en segundo plano: ${message.notification?.title}');
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

  String? _fcmToken;
  bool _isInitialized = false;

  // Stream para notificar videollamadas entrantes
  final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingCallStream => _incomingCallController.stream;

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

    // Crear canal de notificaciones para Android
    if (Platform.isAndroid) {
      const androidChannel = AndroidNotificationChannel(
        'high_importance_channel',
        'Notificaciones Importantes',
        description: 'Canal para notificaciones importantes de SmartConvo',
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(androidChannel);
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
      const androidDetails = AndroidNotificationDetails(
        'high_importance_channel',
        'Notificaciones Importantes',
        channelDescription: 'Canal para notificaciones importantes',
        importance: Importance.high,
        priority: Priority.high,
        enableVibration: true,
        playSound: true,
        icon: '@mipmap/ic_launcher',
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _localNotifications.show(
        message.hashCode,
        message.notification?.title ?? 'SmartConvo',
        message.notification?.body ?? '',
        details,
        payload: message.data.toString(),
      );
    } catch (e) {
      print('❌ Error mostrando notificación local: $e');
    }
  }

  // Manejar tap en notificación local
  void _onNotificationTapped(NotificationResponse response) {
    print('👆 Notificación local tocada: ${response.payload}');
    // Aquí puedes navegar a pantallas específicas
  }

  // Manejar tap en notificación
  void _handleNotificationTap(Map<String, dynamic> data) {
    print('📍 Navegando según tipo: ${data['type']}');

    // Si es una videollamada, emitir evento para mostrar el diálogo
    if (data['type'] == 'video_call') {
      print('📞 Notificación de videollamada tocada, mostrando diálogo');
      _incomingCallController.add(data);
    }
  }

  // ==================== ENVIAR NOTIFICACIONES ====================

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

  // Enviar notificación de nueva solicitud de contacto
  Future<void> sendContactRequestNotification({
    required String parentId,
    required String childName,
    required String contactName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'contact_request',
        'recipientId': parentId,
        'title': '🔔 Nueva solicitud de contacto',
        'body': '$childName quiere agregar a $contactName',
        'data': {
          'type': 'contact_request',
          'childName': childName,
          'contactName': contactName,
        },
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('✅ Notificación de solicitud enviada');
    } catch (e) {
      print('❌ Error enviando notificación: $e');
    }
  }

  // Enviar notificación de contacto aprobado
  Future<void> sendContactApprovedNotification({
    required String childId,
    required String contactName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'contact_approved',
        'recipientId': childId,
        'title': '✅ Contacto aprobado',
        'body': 'Tus padres aprobaron a $contactName. Ya puedes chatear!',
        'data': {'type': 'contact_approved', 'contactName': contactName},
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('✅ Notificación de aprobación enviada');
    } catch (e) {
      print('❌ Error enviando notificación: $e');
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
        'type': 'auto_approval',
        'recipientId': parentId,
        'title': '🤖 Aprobación automática',
        'body': 'Se aprobó automáticamente a "$contactName" para $childName',
        'data': {
          'type': 'auto_approval',
          'childId': childId,
          'childName': childName,
          'contactName': contactName,
        },
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
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
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'bullying_alert',
        'recipientId': parentId,
        'title': '⚠️ ALERTA: Posible bullying detectado',
        'body': 'Se detectó contenido preocupante en mensajes de $childName',
        'data': {
          'type': 'bullying_alert',
          'childName': childName,
          'severity': severity,
          'priority': 'high',
        },
        'isRead': false,
        'priority': 'high',
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('⚠️ Alerta de bullying enviada');
    } catch (e) {
      print('❌ Error enviando alerta: $e');
    }
  }

  // Enviar notificación de reporte disponible
  Future<void> sendReportReadyNotification({
    required String parentId,
    required String childName,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'report_ready',
        'recipientId': parentId,
        'title': '📊 Reporte semanal disponible',
        'body': 'El reporte de $childName está listo para revisar',
        'data': {'type': 'report_ready', 'childName': childName},
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
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
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'story_approval_request',
        'recipientId': parentId,
        'title': '📸 Nueva historia pendiente',
        'body': '$childName quiere compartir una historia. ¡Revísala y apruébala!',
        'data': {
          'type': 'story_approval_request',
          'childName': childName,
          'storyId': storyId,
        },
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('📸 Notificación de historia pendiente enviada');
    } catch (e) {
      print('❌ Error enviando notificación de historia: $e');
    }
  }

  // Enviar notificación de historia aprobada
  Future<void> sendStoryApprovedNotification({
    required String childId,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'story_approved',
        'recipientId': childId,
        'title': '✅ Historia aprobada',
        'body': '¡Genial! Tus padres aprobaron tu historia. Ya está visible para tus contactos.',
        'data': {
          'type': 'story_approved',
        },
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('✅ Notificación de historia aprobada enviada');
    } catch (e) {
      print('❌ Error enviando notificación de aprobación: $e');
    }
  }

  // Enviar notificación de historia rechazada
  Future<void> sendStoryRejectedNotification({
    required String childId,
    String? reason,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'type': 'story_rejected',
        'recipientId': childId,
        'title': '❌ Historia rechazada',
        'body': reason != null && reason.isNotEmpty
            ? 'Tus padres rechazaron tu historia: $reason'
            : 'Tus padres rechazaron tu historia. Intenta con otro contenido.',
        'data': {
          'type': 'story_rejected',
          'reason': reason,
        },
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('❌ Notificación de historia rechazada enviada');
    } catch (e) {
      print('❌ Error enviando notificación de rechazo: $e');
    }
  }

  // Obtener notificaciones no leídas
  Stream<QuerySnapshot> getUnreadNotifications(String userId) {
    return _firestore
        .collection('notifications')
        .where('recipientId', isEqualTo: userId)
        .where('isRead', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  // Marcar notificación como leída
  Future<void> markAsRead(String notificationId) async {
    try {
      await _firestore.collection('notifications').doc(notificationId).update({
        'isRead': true,
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
          .where('recipientId', isEqualTo: userId)
          .where('isRead', isEqualTo: false)
          .get();

      for (var doc in notifications.docs) {
        batch.update(doc.reference, {
          'isRead': true,
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
        .where('recipientId', isEqualTo: userId)
        .where('isRead', isEqualTo: false)
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
