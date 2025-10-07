import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class UnreadMessagesService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  /// Obtener contador de mensajes sin leer para un chat específico
  Future<int> getUnreadCount(String chatId) async {
    final user = _auth.currentUser;
    if (user == null) return 0;

    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return 0;

      final chatData = chatDoc.data() as Map<String, dynamic>;
      final unreadCount = chatData['unreadCount_${user.uid}'] ?? 0;

      return unreadCount is int ? unreadCount : 0;
    } catch (e) {
      print('❌ Error obteniendo unreadCount: $e');
      return 0;
    }
  }

  /// Stream de contador de mensajes sin leer para un chat específico
  Stream<int> watchUnreadCount(String chatId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(0);

    return _firestore
        .collection('chats')
        .doc(chatId)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) return 0;

      final chatData = snapshot.data() as Map<String, dynamic>;
      final unreadCount = chatData['unreadCount_${user.uid}'] ?? 0;

      return unreadCount is int ? unreadCount : 0;
    });
  }

  /// Incrementar contador de mensajes sin leer para el otro usuario
  Future<void> incrementUnreadCount(String chatId, String recipientUserId) async {
    try {
      final chatRef = _firestore.collection('chats').doc(chatId);

      await chatRef.update({
        'unreadCount_$recipientUserId': FieldValue.increment(1),
      });

      print('📬 Incrementado unreadCount para usuario $recipientUserId en chat $chatId');
    } catch (e) {
      print('❌ Error incrementando unreadCount: $e');
    }
  }

  /// Marcar todos los mensajes como leídos (resetear contador)
  Future<void> markAsRead(String chatId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final chatRef = _firestore.collection('chats').doc(chatId);

      await chatRef.update({
        'unreadCount_${user.uid}': 0,
      });

      print('✅ Mensajes marcados como leídos en chat $chatId');

      // Actualizar badge después de marcar como leído
      await updateBadgeCount();
    } catch (e) {
      print('❌ Error marcando mensajes como leídos: $e');
    }
  }

  /// Obtener total de mensajes sin leer en todos los chats
  Future<int> getTotalUnreadCount() async {
    final user = _auth.currentUser;
    if (user == null) return 0;

    try {
      final chatsSnapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      int totalUnread = 0;
      for (var chatDoc in chatsSnapshot.docs) {
        final chatData = chatDoc.data();
        final deletedBy = List<String>.from(chatData['deletedBy'] ?? []);

        // No contar chats eliminados
        if (deletedBy.contains(user.uid)) continue;

        final unreadCount = chatData['unreadCount_${user.uid}'] ?? 0;
        totalUnread += (unreadCount is int ? unreadCount : 0);
      }

      return totalUnread;
    } catch (e) {
      print('❌ Error obteniendo total de mensajes sin leer: $e');
      return 0;
    }
  }

  /// Stream de total de mensajes sin leer en todos los chats
  Stream<int> watchTotalUnreadCount() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(0);

    return _firestore
        .collection('chats')
        .where('participants', arrayContains: user.uid)
        .snapshots()
        .map((snapshot) {
      int totalUnread = 0;

      for (var chatDoc in snapshot.docs) {
        final chatData = chatDoc.data();
        final deletedBy = List<String>.from(chatData['deletedBy'] ?? []);

        // No contar chats eliminados
        if (deletedBy.contains(user.uid)) continue;

        final unreadCount = chatData['unreadCount_${user.uid}'] ?? 0;
        totalUnread += (unreadCount is int ? unreadCount : 0);
      }

      return totalUnread;
    });
  }

  /// Actualizar badge icon con el total de mensajes sin leer
  Future<void> updateBadgeCount() async {
    try {
      final totalUnread = await getTotalUnreadCount();

      // Actualizar badge en iOS
      await _localNotifications
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(badge: true);

      // En iOS, el badge se actualiza automáticamente cuando se muestra una notificación
      // Pero también podemos forzar la actualización
      print('🔔 Badge actualizado: $totalUnread mensajes sin leer');

      // TODO: En iOS necesitamos usar un método nativo para actualizar el badge
      // Por ahora, el badge se actualizará cuando lleguen notificaciones push
    } catch (e) {
      print('❌ Error actualizando badge: $e');
    }
  }

  /// Configurar listener automático para actualizar badge
  void startBadgeListener() {
    final user = _auth.currentUser;
    if (user == null) return;

    watchTotalUnreadCount().listen((totalUnread) {
      print('🔔 Total de mensajes sin leer: $totalUnread');
      updateBadgeCount();
    });
  }
}
