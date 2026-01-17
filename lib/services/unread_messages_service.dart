import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'local_unread_count_service.dart';

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
    } catch (e) {
      // Silently handle error
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

      // Actualizar badge después de marcar como leído
      await updateBadgeCount();
    } catch (e) {
      // Silently handle error
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
        .snapshots(includeMetadataChanges: false)
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
  /// ✅ OPTIMIZADO: Usa LocalUnreadCountService para mensajes no leídos
  Future<void> updateBadgeCount() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // 1. Obtener total de mensajes no leídos desde LocalUnreadCountService
      final totalUnreadMessages = LocalUnreadCountService().getTotalUnreadCount();

      // 2. Obtener IDs de hijos vinculados (solo para padres)
      // ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds por seguridad
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();
      final childrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);

      // 3. Contar historias pendientes de los hijos
      // ACTUALIZADO: Usar story_approval_requests en lugar de stories
      // FIX: Filtrar también por expiresAt para no contar requests expirados
      int pendingStoriesCount = 0;
      final storiesSnapshot = await _firestore
          .collection('story_approval_requests')
          .where('parentId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'pending')
          .get();

      // Filtrar localmente los que no han expirado
      final now = DateTime.now();
      pendingStoriesCount = storiesSnapshot.docs.where((doc) {
        final data = doc.data();
        final expiresAt = data['expiresAt'];
        if (expiresAt == null) return true; // Si no tiene expiresAt, contar
        if (expiresAt is Timestamp) {
          return expiresAt.toDate().isAfter(now);
        }
        return true;
      }).length;

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

      // 5. Solicitudes de contacto: YA NO se cuentan aquí
      // ✅ FIX: El badge de contactos pendientes se muestra en la sección Whitelist
      // No duplicar en el app icon badge

      // Calcular total (suma de todos los badges del bottom nav)
      final totalBadgeCount = totalUnreadMessages + pendingStoriesCount + unresolvedEmergenciesCount;

      // Verificar si el dispositivo soporta badges
      final isSupported = await AppBadgePlus.isSupported();

      if (isSupported) {
        if (totalBadgeCount > 0) {
          await AppBadgePlus.updateBadge(totalBadgeCount);
        } else {
          await AppBadgePlus.updateBadge(0);
        }
      }
    } catch (e) {
      // Silently handle error
    }
  }

  /// Configurar listener automático para actualizar badge
  /// ✅ OPTIMIZADO: Usa LocalUnreadCountService en lugar de Firestore
  void startBadgeListener() {
    final user = _auth.currentUser;
    if (user == null) return;

    // Escuchar cambios en LocalUnreadCountService
    LocalUnreadCountService().addListener(() {
      updateBadgeCount();
    });
  }

  /// Limpiar el badge del icono de la app (poner en 0)
  /// Llamar cuando la app se abre o vuelve a foreground
  Future<void> clearBadge() async {
    try {
      final isSupported = await AppBadgePlus.isSupported();
      if (isSupported) {
        await AppBadgePlus.updateBadge(0);
      }
    } catch (e) {
      // Silently handle error
    }
  }
}
