import 'dart:async';
import 'package:talia/services/remote_logger_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../widgets/custom_notification_banner.dart';
import '../screens/chat_detail_screen.dart';
import '../screens/story_approval_screen.dart';
import 'sound_service.dart';

/// Servicio que escucha mensajes nuevos en tiempo real cuando la app está en foreground
/// Reemplaza las notificaciones FCM en foreground para mayor velocidad y sincronización
class ForegroundMessageListener {
  static final ForegroundMessageListener _instance = ForegroundMessageListener._internal();
  factory ForegroundMessageListener() => _instance;
  ForegroundMessageListener._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// StreamSubscriptions activos
  StreamSubscription? _chatsSubscription;
  StreamSubscription? _groupsSubscription;
  StreamSubscription? _notificationsSubscription;

  /// Último mensaje procesado por chat (para evitar duplicados)
  final Map<String, String> _lastProcessedMessageIds = {};

  /// Últimas notificaciones procesadas (para evitar duplicados)
  final Set<String> _processedNotificationIds = {};

  /// Chat ID que el usuario está viendo actualmente (no mostrar banner para este chat)
  String? _currentOpenChatId;

  /// GlobalKey del Navigator para acceder al overlay
  GlobalKey<NavigatorState>? _navigatorKey;

  /// Timestamp de inicio del listener para ignorar mensajes antiguos
  DateTime? _startTime;

  /// Map de chats que fueron abiertos desde notificaciones background
  /// Key: chatId, Value: timestamp cuando se ignoró
  final Map<String, DateTime> _ignoredChatsFromNotifications = {};

  /// Inicializar el listener con el navigatorKey global de la app
  void initialize(GlobalKey<NavigatorState> navigatorKey) {
    appLogger.log('══════════════════════════════════════════════════════════════', level: 'INFO');
    appLogger.log('🚀 ForegroundMessageListener.initialize() LLAMADO', level: 'INFO');
    appLogger.log('══════════════════════════════════════════════════════════════', level: 'INFO');

    // Limpiar listeners anteriores si existen (hot restart)
    appLogger.log('🧹 Limpiando listeners antiguos si existen...', level: 'INFO');
    _chatsSubscription?.cancel();
    _groupsSubscription?.cancel();
    _notificationsSubscription?.cancel();
    _lastProcessedMessageIds.clear();
    _processedNotificationIds.clear();

    _navigatorKey = navigatorKey;
    _startTime = DateTime.now(); // ✅ Inicializar timestamp aquí, no en declaración

    appLogger.log('✅ Configuración completa:', level: 'INFO');
    appLogger.log('   - NavigatorKey: ${navigatorKey != null}', level: 'INFO');
    appLogger.log('   - NavigatorKey.currentState: ${navigatorKey.currentState != null}', level: 'INFO');
    appLogger.log('   - NavigatorKey.currentContext: ${navigatorKey.currentContext != null}', level: 'INFO');
    appLogger.log('   - Timestamp de inicio: $_startTime', level: 'INFO');
    appLogger.log('   - Usuario autenticado: ${_auth.currentUser != null}', level: 'INFO');
    appLogger.log('   - User UID: ${_auth.currentUser?.uid ?? "null"}', level: 'INFO');

    appLogger.log('', level: 'INFO');
    appLogger.log('🎯 Iniciando escucha de mensajes en Firestore...', level: 'INFO');
    _startListening();
    appLogger.log('══════════════════════════════════════════════════════════════', level: 'INFO');
  }

  /// Establecer el chat actualmente abierto (no mostrar banners para este chat)
  void setCurrentOpenChat(String? chatId) {
    _currentOpenChatId = chatId;
    appLogger.log('📖 Chat abierto: ${chatId ?? "ninguno"}', level: 'INFO');
  }

  /// Marcar un chat como abierto desde una notificación background
  /// Esto evita que se muestre un banner custom inmediatamente después
  void markChatOpenedFromNotification(String chatId) {
    _ignoredChatsFromNotifications[chatId] = DateTime.now();
    appLogger.log('🔕 Chat $chatId marcado como ignorado (abierto desde notificación)', level: 'INFO');

    // Limpiar después de 10 segundos
    Future.delayed(Duration(seconds: 10), () {
      _ignoredChatsFromNotifications.remove(chatId);
      appLogger.log('✅ Chat $chatId ya no está ignorado', level: 'INFO');
    });
  }

  /// Comenzar a escuchar chats y notificaciones del usuario
  void _startListening() {
    final user = _auth.currentUser;
    if (user == null) {
      appLogger.log('❌❌❌ CRÍTICO: No se puede iniciar listener - usuario NO autenticado', level: 'ERROR');
      return;
    }

    appLogger.log('🎯 Iniciando listeners para usuario: ${user.uid.substring(0, 8)}...', level: 'INFO');
    appLogger.log('   Timestamp de inicio: $_startTime', level: 'INFO');

    // ✅ LISTENER 1: CHATS - Para detectar mensajes nuevos en chats individuales
    _startChatsListener(user.uid);

    // ✅ LISTENER 2: GROUPS - Para detectar mensajes nuevos en chats grupales
    _startGroupsListener(user.uid);

    // ✅ LISTENER 3: NOTIFICATIONS - Para solicitudes de contacto, historias, etc.
    _startNotificationsListener(user.uid);
  }

  /// Listener de CHATS - Detecta mensajes nuevos directamente
  void _startChatsListener(String userId) {
    appLogger.log('', level: 'INFO');
    appLogger.log('🎯 1️⃣ Iniciando listener de CHATS (mensajes)...', level: 'INFO');

    _chatsSubscription = _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .snapshots()
        .listen((chatsSnapshot) {
      appLogger.log('', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('💬 SNAPSHOT DE CHATS RECIBIDO', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('   Total chats: ${chatsSnapshot.docs.length}', level: 'INFO');
      appLogger.log('   Cambios: ${chatsSnapshot.docChanges.length}', level: 'INFO');

      // Procesar TODOS los cambios para diagnosticar
      for (var change in chatsSnapshot.docChanges) {
        final chatDoc = change.doc;
        final chatId = chatDoc.id;

        appLogger.log('   🔍 Cambio detectado en chat ${chatId.substring(0, 8)}...', level: 'INFO');
        appLogger.log('      Tipo: ${change.type}', level: 'INFO');

        if (change.type == DocumentChangeType.modified) {
          final chatData = chatDoc.data() as Map<String, dynamic>;
          appLogger.log('   📝 Chat modificado: ${chatId.substring(0, 8)}...', level: 'INFO');
          _handleChatUpdate(chatId, chatData);
        } else if (change.type == DocumentChangeType.added) {
          appLogger.log('   ➕ Chat nuevo agregado (ignorando)', level: 'INFO');
        } else if (change.type == DocumentChangeType.removed) {
          appLogger.log('   ➖ Chat eliminado (ignorando)', level: 'INFO');
        }
      }

      appLogger.log('✅ Snapshot de chats procesado', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('', level: 'INFO');
    }, onError: (error) {
      appLogger.log('❌❌❌ ERROR en listener de chats: $error', level: 'ERROR');
    });

    appLogger.log('✅ Listener de chats configurado', level: 'INFO');
  }

  /// Listener de GROUPS - Detecta mensajes nuevos en grupos
  void _startGroupsListener(String userId) {
    appLogger.log('', level: 'INFO');
    appLogger.log('🎯 2️⃣ Iniciando listener de GROUPS (mensajes de grupo)...', level: 'INFO');

    _groupsSubscription = _firestore
        .collection('groups')
        .where('members', arrayContains: userId)
        .snapshots()
        .listen((groupsSnapshot) {
      appLogger.log('', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('👥 SNAPSHOT DE GROUPS RECIBIDO', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('   Total grupos: ${groupsSnapshot.docs.length}', level: 'INFO');
      appLogger.log('   Cambios: ${groupsSnapshot.docChanges.length}', level: 'INFO');

      // Procesar TODOS los cambios
      for (var change in groupsSnapshot.docChanges) {
        final groupDoc = change.doc;
        final groupId = groupDoc.id;

        appLogger.log('   🔍 Cambio detectado en grupo ${groupId.substring(0, 8)}...', level: 'INFO');
        appLogger.log('      Tipo: ${change.type}', level: 'INFO');

        if (change.type == DocumentChangeType.modified) {
          final groupData = groupDoc.data() as Map<String, dynamic>;
          appLogger.log('   📝 Grupo modificado: ${groupId.substring(0, 8)}...', level: 'INFO');
          _handleGroupUpdate(groupId, groupData);
        } else if (change.type == DocumentChangeType.added) {
          appLogger.log('   ➕ Grupo nuevo agregado (ignorando)', level: 'INFO');
        } else if (change.type == DocumentChangeType.removed) {
          appLogger.log('   ➖ Grupo eliminado (ignorando)', level: 'INFO');
        }
      }

      appLogger.log('✅ Snapshot de grupos procesado', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('', level: 'INFO');
    }, onError: (error) {
      appLogger.log('❌❌❌ ERROR en listener de grupos: $error', level: 'ERROR');
    });

    appLogger.log('✅ Listener de grupos configurado', level: 'INFO');
  }

  /// Listener de NOTIFICATIONS - Para eventos no relacionados con mensajes
  void _startNotificationsListener(String userId) {
    appLogger.log('', level: 'INFO');
    appLogger.log('🎯 2️⃣ Iniciando listener de NOTIFICATIONS (eventos)...', level: 'INFO');
    appLogger.log('   Eventos: solicitudes de contacto, historias agregadas, etc.', level: 'INFO');

    _notificationsSubscription = _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('read', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots()
        .listen((notificationsSnapshot) {
      appLogger.log('', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('🔔 SNAPSHOT DE NOTIFICATIONS RECIBIDO', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('   Total notificaciones: ${notificationsSnapshot.docs.length}', level: 'INFO');
      appLogger.log('   Cambios: ${notificationsSnapshot.docChanges.length}', level: 'INFO');

      // Procesar solo NUEVAS notificaciones
      for (var change in notificationsSnapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final notificationDoc = change.doc;
          final notificationData = notificationDoc.data() as Map<String, dynamic>;
          final notificationId = notificationDoc.id;

          // Ignorar notificaciones de tipo mensaje (ya se procesan en chats)
          final type = notificationData['type'] as String?;
          if (type == 'chat_message' || type == 'group_message') {
            appLogger.log('   ⏭️ Notificación de mensaje ignorada (se procesa en chats): $notificationId', level: 'INFO');
            continue;
          }

          appLogger.log('   🆕 Nueva notificación: ${notificationId.substring(0, 8)}... (tipo: $type)', level: 'INFO');

          _handleNewNotification(notificationId, notificationData);
        }
      }

      appLogger.log('✅ Snapshot de notifications procesado', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      appLogger.log('', level: 'INFO');
    }, onError: (error) {
      appLogger.log('❌❌❌ ERROR en listener de notifications: $error', level: 'ERROR');
    });

    appLogger.log('✅ Listener de notifications configurado', level: 'INFO');
  }

  /// Manejar actualización de un grupo (mensaje nuevo)
  Future<void> _handleGroupUpdate(
    String groupId,
    Map<String, dynamic> groupData,
  ) async {
    appLogger.log('🔍 Procesando actualización de grupo $groupId', level: 'INFO');

    final user = _auth.currentUser;
    if (user == null) {
      appLogger.log('❌ Usuario no autenticado', level: 'ERROR');
      return;
    }

    // Leer lastMessage del documento del grupo
    final lastMessageText = groupData['lastMessage'] as String?;
    final lastMessageTime = groupData['lastMessageTime'] as Timestamp?;
    final lastMessageSender = groupData['lastMessageSender'] as String?;

    appLogger.log('📩 Último mensaje:', level: 'INFO');
    appLogger.log('   Text: ${lastMessageText ?? "null"}', level: 'INFO');
    appLogger.log('   Time: ${lastMessageTime?.toDate()}', level: 'INFO');
    appLogger.log('   Sender: ${lastMessageSender ?? "null"}', level: 'INFO');

    // Validar datos básicos
    if (lastMessageText == null || lastMessageTime == null || lastMessageSender == null) {
      appLogger.log('⚠️ No hay último mensaje válido', level: 'WARNING');
      return;
    }

    // Crear ID único del mensaje
    final messageId = '${lastMessageTime.millisecondsSinceEpoch}_$lastMessageSender';

    // Si ya procesamos este mensaje, ignorar
    if (_lastProcessedMessageIds[groupId] == messageId) {
      appLogger.log('⏭️ Mensaje ya procesado, SALTANDO', level: 'INFO');
      return;
    }

    // Marcar como procesado
    _lastProcessedMessageIds[groupId] = messageId;
    appLogger.log('✅ Mensaje marcado como procesado', level: 'INFO');

    // Ignorar mensajes del usuario actual
    if (lastMessageSender == user.uid) {
      appLogger.log('❌ Mensaje ignorado: es del usuario actual', level: 'ERROR');
      return;
    }

    // Ignorar mensajes anteriores al inicio del listener
    if (_startTime != null && lastMessageTime.toDate().isBefore(_startTime!)) {
      appLogger.log('❌ Mensaje ignorado: anterior al inicio del listener', level: 'ERROR');
      return;
    }

    // Ignorar si el usuario está viendo este grupo
    if (_currentOpenChatId == groupId) {
      appLogger.log('📖 Mensaje ignorado: usuario está viendo el grupo', level: 'INFO');
      return;
    }

    // Ignorar si el grupo fue abierto recientemente desde una notificación background
    if (_ignoredChatsFromNotifications.containsKey(groupId)) {
      final ignoredAt = _ignoredChatsFromNotifications[groupId]!;
      final secondsSinceIgnored = DateTime.now().difference(ignoredAt).inSeconds;
      appLogger.log('🔕 Mensaje ignorado: grupo abierto desde notificación hace $secondsSinceIgnored segundos', level: 'INFO');
      return;
    }

    // Verificar si el grupo está silenciado para el usuario actual
    final isMuted = groupData['muted_${user.uid}'] as bool? ?? false;
    if (isMuted) {
      appLogger.log('🔕 Mensaje ignorado: grupo silenciado para el usuario', level: 'INFO');
      return;
    }

    appLogger.log('🔔 Nuevo mensaje detectado en grupo $groupId', level: 'INFO');

    // Obtener información del remitente
    final senderDoc = await _firestore.collection('users').doc(lastMessageSender).get();
    final senderData = senderDoc.data();
    final senderName = senderData?['name'] as String? ?? 'Usuario';
    final senderPhotoUrl = senderData?['photoURL'] as String?;

    // Obtener nombre del grupo
    final groupName = groupData['name'] as String? ?? 'Grupo';

    // Preview del mensaje (formato: "NombreUsuario: mensaje")
    final messagePreview = '$senderName: $lastMessageText';

    // Mostrar banner con el nombre del grupo
    _showBanner(
      senderName: groupName,
      messagePreview: messagePreview,
      senderPhotoUrl: groupData['avatar'] as String?, // Usar avatar del grupo
      chatId: groupId,
      senderId: lastMessageSender,
      isGroupChat: true, // Indicar que es un grupo
    );
  }

  /// Manejar actualización de un chat (mensaje nuevo)
  Future<void> _handleChatUpdate(
    String chatId,
    Map<String, dynamic> chatData,
  ) async {
    appLogger.log('🔍 Procesando actualización de chat $chatId', level: 'INFO');

    final user = _auth.currentUser;
    if (user == null) {
      appLogger.log('❌ Usuario no autenticado', level: 'ERROR');
      return;
    }

    // Leer lastMessage del documento del chat
    final lastMessageText = chatData['lastMessage'] as String?;
    final lastMessageTime = chatData['lastMessageTime'] as Timestamp?; // ✅ CAMPO CORRECTO
    final lastMessageSender = chatData['lastMessageSender'] as String?;

    appLogger.log('📩 Último mensaje:', level: 'INFO');
    appLogger.log('   Text: ${lastMessageText ?? "null"}', level: 'INFO');
    appLogger.log('   Time: ${lastMessageTime?.toDate()}', level: 'INFO');
    appLogger.log('   Sender: ${lastMessageSender ?? "null"}', level: 'INFO');

    // Validar datos básicos
    if (lastMessageText == null || lastMessageTime == null || lastMessageSender == null) {
      appLogger.log('⚠️ No hay último mensaje válido', level: 'WARNING');
      return;
    }

    // Crear ID único del mensaje
    final messageId = '${lastMessageTime.millisecondsSinceEpoch}_$lastMessageSender';

    // Si ya procesamos este mensaje, ignorar
    if (_lastProcessedMessageIds[chatId] == messageId) {
      appLogger.log('⏭️ Mensaje ya procesado, SALTANDO', level: 'INFO');
      return;
    }

    // Marcar como procesado
    _lastProcessedMessageIds[chatId] = messageId;
    appLogger.log('✅ Mensaje marcado como procesado', level: 'INFO');

    // Ignorar mensajes del usuario actual
    if (lastMessageSender == user.uid) {
      appLogger.log('❌ Mensaje ignorado: es del usuario actual', level: 'ERROR');
      return;
    }

    // Ignorar mensajes anteriores al inicio del listener
    if (_startTime != null && lastMessageTime.toDate().isBefore(_startTime!)) {
      appLogger.log('❌ Mensaje ignorado: anterior al inicio del listener', level: 'ERROR');
      return;
    }

    // Ignorar si el usuario está viendo este chat
    if (_currentOpenChatId == chatId) {
      appLogger.log('📖 Mensaje ignorado: usuario está viendo el chat', level: 'INFO');
      return;
    }

    // Ignorar si el chat fue abierto recientemente desde una notificación background
    if (_ignoredChatsFromNotifications.containsKey(chatId)) {
      final ignoredAt = _ignoredChatsFromNotifications[chatId]!;
      final secondsSinceIgnored = DateTime.now().difference(ignoredAt).inSeconds;
      appLogger.log('🔕 Mensaje ignorado: chat abierto desde notificación hace $secondsSinceIgnored segundos', level: 'INFO');
      return;
    }

    // Verificar si el chat está silenciado para el usuario actual
    final isMuted = chatData['muted_${user.uid}'] as bool? ?? false;
    if (isMuted) {
      appLogger.log('🔕 Mensaje ignorado: chat silenciado para el usuario', level: 'INFO');
      return;
    }

    // Nota: No tenemos lastMessageType guardado en el documento del chat
    // Las llamadas se ignoran automáticamente porque el texto será diferente

    appLogger.log('🔔 Nuevo mensaje detectado en chat $chatId', level: 'INFO');

    // Obtener información del remitente
    final senderDoc = await _firestore.collection('users').doc(lastMessageSender).get();
    final senderData = senderDoc.data();
    final senderName = senderData?['name'] as String? ?? 'Usuario';
    final senderPhotoUrl = senderData?['photoURL'] as String?;

    // Preview del mensaje (ya viene formateado desde el chat)
    final messagePreview = lastMessageText;

    // Mostrar banner (siempre, incluso si está bloqueado)
    _showBanner(
      senderName: senderName,
      messagePreview: messagePreview,
      senderPhotoUrl: senderPhotoUrl,
      chatId: chatId,
      senderId: lastMessageSender,
    );
  }

  /// Manejar una notificación de evento (solicitud de contacto, historia, etc.)
  Future<void> _handleNewNotification(
    String notificationId,
    Map<String, dynamic> notificationData,
  ) async {
    appLogger.log('🔍 Procesando notificación de evento: $notificationId', level: 'INFO');

    final user = _auth.currentUser;
    if (user == null) {
      appLogger.log('❌ Usuario no autenticado', level: 'ERROR');
      return;
    }

    // Extraer datos de la notificación
    final type = notificationData['type'] as String?;
    final senderId = notificationData['senderId'] as String?;
    final senderName = notificationData['senderName'] as String?;
    final senderPhotoUrl = notificationData['senderPhotoUrl'] as String?;
    final title = notificationData['title'] as String?;
    final body = notificationData['body'] as String?;
    final timestamp = notificationData['timestamp'] as Timestamp?;
    final data = notificationData['data'] as Map<String, dynamic>?;

    appLogger.log('📋 Datos de notificación:', level: 'INFO');
    appLogger.log('   Type: $type', level: 'INFO');
    appLogger.log('   SenderId: $senderId', level: 'INFO');
    appLogger.log('   SenderName: $senderName', level: 'INFO');
    appLogger.log('   Title: $title', level: 'INFO');
    appLogger.log('   Body: $body', level: 'INFO');
    appLogger.log('   Data: $data', level: 'INFO');
    appLogger.log('   Timestamp: ${timestamp?.toDate()}', level: 'INFO');

    // Validar datos básicos
    if (type == null || timestamp == null) {
      appLogger.log('❌ Notificación ignorada: datos básicos faltantes', level: 'ERROR');
      return;
    }

    // Ignorar notificaciones anteriores al inicio del listener
    if (_startTime != null && timestamp.toDate().isBefore(_startTime!)) {
      appLogger.log('❌ Notificación ignorada: anterior al inicio del listener', level: 'ERROR');
      return;
    }

    // Ignorar si ya procesamos esta notificación
    if (_processedNotificationIds.contains(notificationId)) {
      appLogger.log('⏭️ Notificación $notificationId ya fue procesada, SALTANDO', level: 'INFO');
      return;
    }

    // Marcar como procesada
    _processedNotificationIds.add(notificationId);
    appLogger.log('✅ Notificación $notificationId marcada como procesada', level: 'INFO');

    appLogger.log('🔔 Nueva notificación de evento detectada: $type', level: 'INFO');

    // Preparar datos para mostrar
    final displayName = title ?? 'Talia';
    final displayMessage = body ?? 'Nueva notificación';

    // Mostrar banner con navegación específica según el tipo
    _showBanner(
      senderName: displayName,
      messagePreview: displayMessage,
      senderPhotoUrl: senderPhotoUrl,
      chatId: null, // No hay chatId para eventos
      senderId: senderId,
      notificationType: type,
      notificationData: data,
    );
  }

  /// Mostrar banner de notificación
  void _showBanner({
    required String senderName,
    required String messagePreview,
    String? senderPhotoUrl,
    String? chatId,
    String? senderId,
    String? notificationType,
    Map<String, dynamic>? notificationData,
    bool isGroupChat = false,
  }) {
    appLogger.log('', level: 'INFO');
    appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
    appLogger.log('🎨 PREPARANDO MOSTRAR BANNER DE NOTIFICACIÓN', level: 'INFO');
    appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
    appLogger.log('   Título: $senderName', level: 'INFO');
    appLogger.log('   Cuerpo: $messagePreview', level: 'INFO');
    appLogger.log('   Foto: ${senderPhotoUrl ?? "sin foto"}', level: 'INFO');
    appLogger.log('   Tipo: $notificationType', level: 'INFO');
    appLogger.log('   NavigatorKey válido: ${_navigatorKey != null}', level: 'INFO');
    appLogger.log('   NavigatorState disponible: ${_navigatorKey?.currentState != null}', level: 'INFO');
    appLogger.log('   OverlayState disponible: ${_navigatorKey?.currentState?.overlay != null}', level: 'INFO');

    final navigatorState = _navigatorKey?.currentState;
    final overlay = navigatorState?.overlay;
    final context = _navigatorKey?.currentContext;

    if (overlay != null && context != null && context.mounted) {
      appLogger.log('✅ Overlay obtenido directamente del NavigatorState', level: 'INFO');
      try {
        // Reproducir sonido de recepción
        SoundService().playReceiveSound();
        appLogger.log('🔊 Sonido de recepción reproducido', level: 'INFO');

        // Determinar la acción al tocar según el tipo de notificación
        VoidCallback? onTapAction;

        if (chatId != null && isGroupChat) {
          // Navegación a chat grupal
          onTapAction = () {
            appLogger.log('👆 Usuario tocó el banner, navegando al grupo...', level: 'INFO');
            Navigator.pushNamed(
              context,
              '/group_chat',
              arguments: {
                'groupId': chatId,
                'groupName': senderName,
              },
            );
          };
        } else if (chatId != null && senderId != null) {
          // Navegación a chat individual
          onTapAction = () {
            appLogger.log('👆 Usuario tocó el banner, navegando al chat...', level: 'INFO');
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChatDetailScreen(
                  chatId: chatId,
                  contactId: senderId,
                  contactName: senderName,
                ),
              ),
            );
          };
        } else if (notificationType == 'story_approval_request') {
          // Navegación a pantalla de aprobación de historias
          onTapAction = () {
            appLogger.log('👆 Usuario tocó el banner de historia, navegando a aprobación de historias...', level: 'INFO');
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const StoryApprovalScreen(),
              ),
            );
          };
        }

        CustomNotificationBanner.showWithOverlay(
          overlay,
          context,
          title: senderName,
          body: messagePreview,
          imageUrl: senderPhotoUrl,
          onTap: onTapAction,
        );
        appLogger.log('✅✅✅ BANNER MOSTRADO EXITOSAMENTE ✅✅✅', level: 'INFO');
        appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
        appLogger.log('', level: 'INFO');
      } catch (e, stack) {
        appLogger.log('❌❌❌ ERROR MOSTRANDO BANNER: $e', level: 'ERROR');
        appLogger.log('   Stack trace: $stack', level: 'INFO');
        appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
      }
    } else {
      appLogger.log('❌❌❌ NO SE PUEDE MOSTRAR BANNER - Overlay o Context no válido', level: 'ERROR');
      appLogger.log('   NavigatorKey null?: ${_navigatorKey == null}', level: 'INFO');
      appLogger.log('   NavigatorState null?: ${navigatorState == null}', level: 'INFO');
      appLogger.log('   OverlayState null?: ${overlay == null}', level: 'INFO');
      appLogger.log('   Context null?: ${context == null}', level: 'INFO');
      appLogger.log('   Context mounted?: ${context?.mounted ?? false}', level: 'INFO');
      appLogger.log('═══════════════════════════════════════════════════════════', level: 'INFO');
    }
  }


  /// Obtener preview del mensaje según su tipo
  String _getMessagePreview(Map<String, dynamic> messageData) {
    final type = messageData['type'] as String?;
    final text = messageData['text'] as String?;

    switch (type) {
      case 'image':
        return '📷 Imagen';
      case 'video':
        return '🎥 Video';
      case 'audio':
        return '🎤 Audio';
      case 'story_reply':
        return '💬 Respuesta a historia';
      case 'location':
        return '📍 Ubicación';
      case 'text':
      default:
        return text ?? 'Mensaje nuevo';
    }
  }

  /// Detener todos los listeners
  void dispose() {
    appLogger.log('🛑 Deteniendo todos los listeners', level: 'INFO');
    _chatsSubscription?.cancel();
    _groupsSubscription?.cancel();
    _notificationsSubscription?.cancel();
    _lastProcessedMessageIds.clear();
    _processedNotificationIds.clear();
    _navigatorKey = null;
  }

  /// Pausar listeners (cuando la app va a background)
  void pause() {
    appLogger.log('⏸️ Pausando listeners de foreground', level: 'INFO');
    dispose();
  }

  /// Reanudar listeners (cuando la app vuelve a foreground)
  void resume(GlobalKey<NavigatorState> navigatorKey) {
    appLogger.log('▶️ Reanudando listeners de foreground', level: 'INFO');
    initialize(navigatorKey);
  }
}
