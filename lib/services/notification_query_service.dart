import 'package:cloud_firestore/cloud_firestore.dart';

/// Service para queries de notificaciones en Firestore
///
/// Responsabilidades:
/// - Proporcionar streams de notificaciones
/// - Filtrar notificaciones por usuario/hijo
class NotificationQueryService {
  static final NotificationQueryService _instance = NotificationQueryService._internal();
  factory NotificationQueryService() => _instance;
  NotificationQueryService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Stream de notificaciones no leidas para un usuario
  Stream<QuerySnapshot> watchUnreadNotifications(String userId) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('read', isEqualTo: false)
        .snapshots();
  }

  /// Stream de todas las notificaciones de un usuario
  Stream<QuerySnapshot> watchAllNotifications(String userId) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  /// Contar notificaciones no leidas relacionadas a un hijo especifico
  /// Excluye notificaciones de chat y solo cuenta las que tienen childId o senderId del hijo
  int countUnreadForChild(QuerySnapshot snapshot, String childId) {
    int count = 0;

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      final notifData = data['data'] as Map<String, dynamic>?;
      final type = data['type'] as String?;

      // Filtrar notificaciones de chat
      if (type == 'chat_message') {
        continue;
      }

      // Verificar si la notificacion esta relacionada con este hijo
      final isRelated = notifData?['childId'] == childId ||
          notifData?['senderId'] == childId;

      if (isRelated) {
        count++;
      }
    }

    return count;
  }
}
