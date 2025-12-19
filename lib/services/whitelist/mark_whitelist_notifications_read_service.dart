import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/release_logger.dart';
import '../../constants/notification_types.dart';

/// Service atómico: Marcar notificaciones de whitelist como leídas
///
/// Responsabilidad única: Marcar como leídas todas las notificaciones
/// relacionadas con la lista blanca para un padre específico
class MarkWhitelistNotificationsReadService {
  final FirebaseFirestore _firestore;

  MarkWhitelistNotificationsReadService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Marcar todas las notificaciones de whitelist como leídas para un padre
  Future<int> call(String parentId) async {
    try {
      // Query para obtener notificaciones no leídas de whitelist
      final snapshot = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: parentId)
          .where('read', isEqualTo: false)
          .where('type', whereIn: [
            NotificationTypes.contactRequest,
            NotificationTypes.whitelistChange,
            NotificationTypes.groupPermissionRequest,
          ])
          .get();

      if (snapshot.docs.isEmpty) {
        ReleaseLogger.log(
          'No hay notificaciones de whitelist pendientes',
          tag: 'MarkWhitelistNotificationsRead',
        );
        return 0;
      }

      // Marcar todas como leídas en batch
      final batch = _firestore.batch();
      final now = FieldValue.serverTimestamp();

      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {
          'read': true,
          'readAt': now,
        });
      }

      await batch.commit();

      ReleaseLogger.log(
        'Marcadas ${snapshot.docs.length} notificaciones como leídas',
        tag: 'MarkWhitelistNotificationsRead',
      );

      return snapshot.docs.length;
    } catch (e) {
      ReleaseLogger.error(
        'Error marcando notificaciones como leídas: $e',
        tag: 'MarkWhitelistNotificationsRead',
      );
      return 0;
    }
  }
}
