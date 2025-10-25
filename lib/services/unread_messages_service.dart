import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:app_badge_plus/app_badge_plus.dart';

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

  /// Actualizar badge icon con el total de mensajes sin leer y notificaciones relevantes
  /// ✅ SOLO cuenta: chats no leídos + historias pendientes + emergencias no resueltas + solicitudes de contacto
  Future<void> updateBadgeCount() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // 1. Obtener total de mensajes no leídos
      final totalUnreadMessages = await getTotalUnreadCount();

      // 2. Obtener IDs de hijos vinculados (solo para padres)
      final linksSnapshot = await _firestore
          .collection('parentChildLinks')
          .where('parentId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'approved')
          .get();

      final childrenIds = linksSnapshot.docs
          .map((doc) => doc.data()['childId'] as String)
          .toList();

      // 3. Contar historias pendientes de los hijos
      int pendingStoriesCount = 0;
      if (childrenIds.isNotEmpty) {
        final storiesSnapshot = await _firestore
            .collection('stories')
            .where('userId', whereIn: childrenIds)
            .where('status', isEqualTo: 'pending')
            .get();
        pendingStoriesCount = storiesSnapshot.docs.length;
      }

      // 4. Contar emergencias no resueltas de los hijos
      int unresolvedEmergenciesCount = 0;
      if (childrenIds.isNotEmpty) {
        final emergenciesSnapshot = await _firestore
            .collection('emergencies')
            .where('childId', whereIn: childrenIds)
            .get();

        // Filtrar manualmente las que no están resueltas (whereNotIn no funciona bien con un solo valor)
        unresolvedEmergenciesCount = emergenciesSnapshot.docs
            .where((doc) => doc.data()['status'] != 'resolved')
            .length;
      }

      // 5. Contar solicitudes de contacto pendientes (notificaciones)
      final contactRequestsSnapshot = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: user.uid)
          .where('read', isEqualTo: false)
          .where('type', isEqualTo: 'contact_request')
          .get();
      final contactRequestsCount = contactRequestsSnapshot.docs.length;

      // Calcular total (suma de todos los badges del bottom nav)
      final totalBadgeCount = totalUnreadMessages + pendingStoriesCount + unresolvedEmergenciesCount + contactRequestsCount;

      // Verificar si el dispositivo soporta badges
      final isSupported = await AppBadgePlus.isSupported();

      if (isSupported) {
        if (totalBadgeCount > 0) {
          await AppBadgePlus.updateBadge(totalBadgeCount);
          print('🔔 Badge del ícono actualizado: $totalBadgeCount ($totalUnreadMessages chats + $pendingStoriesCount historias + $unresolvedEmergenciesCount emergencias + $contactRequestsCount contactos)');
        } else {
          await AppBadgePlus.updateBadge(0);
          print('🔔 Badge del ícono removido (no hay mensajes ni notificaciones)');
        }
      } else {
        print('⚠️ Este dispositivo no soporta app badges');
      }
    } catch (e) {
      print('❌ Error actualizando badge del ícono: $e');
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
