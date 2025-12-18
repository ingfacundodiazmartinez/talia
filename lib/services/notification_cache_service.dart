import 'package:hive_flutter/hive_flutter.dart';
import '../utils/release_logger.dart';

/// Servicio para cachear notificaciones localmente usando Hive
///
/// Responsabilidades:
/// - Guardar notificaciones en cache local persistente
/// - Recuperar notificaciones del cache
/// - Marcar como leídas
/// - Eliminar notificaciones viejas (cleanup automático)
///
/// Flujo:
/// 1. CF crea notificación en Firestore
/// 2. Trigger sendNotificationOnCreate envía push
/// 3. App recibe push o lee de Firestore
/// 4. App cachea localmente con este servicio
/// 5. App elimina de Firestore (ya no necesaria en DB)
/// 6. Dashboard lee del cache local
class NotificationCacheService {
  static final NotificationCacheService _instance = NotificationCacheService._internal();
  factory NotificationCacheService() => _instance;
  NotificationCacheService._internal();

  static const String _boxName = 'notifications_cache';
  static const int _maxNotificationsPerUser = 100; // Límite por usuario
  static const int _retentionDays = 30; // Retener notificaciones por 30 días

  Box? _notificationsBox;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  /// Inicializar Hive y abrir la box
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Hive ya debería estar inicializado en main.dart
      _notificationsBox = await Hive.openBox(_boxName);
      _isInitialized = true;

      // Ejecutar limpieza de notificaciones viejas
      await _cleanupOldNotifications();

      ReleaseLogger.log('NotificationCacheService inicializado', tag: 'NotifCache');
    } catch (e) {
      ReleaseLogger.error('Error inicializando NotificationCacheService: $e', tag: 'NotifCache');
    }
  }

  /// Guardar una notificación en el cache
  Future<bool> saveNotification({
    required String notificationId,
    required String userId,
    required String type,
    required String title,
    required String body,
    Map<String, dynamic>? data,
    String? priority,
    String? childId,
  }) async {
    if (_notificationsBox == null) {
      await initialize();
    }
    if (_notificationsBox == null) return false;

    try {
      final key = '${userId}_$notificationId';
      final now = DateTime.now();

      final notificationData = {
        'id': notificationId,
        'userId': userId,
        'type': type,
        'title': title,
        'body': body,
        'data': data,
        'priority': priority ?? 'normal',
        'childId': childId ?? data?['childId'],
        'read': false,
        'createdAt': now.millisecondsSinceEpoch,
        'cachedAt': now.millisecondsSinceEpoch,
      };

      await _notificationsBox!.put(key, notificationData);

      ReleaseLogger.log('Notificación cacheada: $notificationId (tipo: $type)', tag: 'NotifCache');

      // Limpiar si excedemos el límite
      await _enforceLimit(userId);

      return true;
    } catch (e) {
      ReleaseLogger.error('Error guardando notificación en cache: $e', tag: 'NotifCache');
      return false;
    }
  }

  /// Guardar notificación desde un Map (útil para datos de Firestore)
  Future<bool> saveNotificationFromMap(String notificationId, Map<String, dynamic> data) async {
    return saveNotification(
      notificationId: notificationId,
      userId: data['userId'] as String? ?? '',
      type: data['type'] as String? ?? 'unknown',
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      data: data['data'] as Map<String, dynamic>?,
      priority: data['priority'] as String?,
      childId: data['childId'] as String?,
    );
  }

  /// Obtener todas las notificaciones de un usuario
  List<Map<String, dynamic>> getNotificationsForUser(String userId) {
    if (_notificationsBox == null) return [];

    try {
      final notifications = <Map<String, dynamic>>[];

      for (final key in _notificationsBox!.keys) {
        if (key.toString().startsWith('${userId}_')) {
          final data = _notificationsBox!.get(key);
          if (data != null && data is Map) {
            notifications.add(Map<String, dynamic>.from(data));
          }
        }
      }

      // Ordenar por fecha de creación (más recientes primero)
      notifications.sort((a, b) {
        final aTime = a['createdAt'] as int? ?? 0;
        final bTime = b['createdAt'] as int? ?? 0;
        return bTime.compareTo(aTime);
      });

      return notifications;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo notificaciones del cache: $e', tag: 'NotifCache');
      return [];
    }
  }

  /// Obtener notificaciones filtradas por childId
  List<Map<String, dynamic>> getNotificationsForChild(String userId, String childId) {
    final allNotifications = getNotificationsForUser(userId);

    return allNotifications.where((notif) {
      final notifChildId = notif['childId'] as String?;
      final notifData = notif['data'] as Map<String, dynamic>?;
      final dataChildId = notifData?['childId'] as String?;
      final dataSenderId = notifData?['senderId'] as String?;

      return notifChildId == childId ||
          dataChildId == childId ||
          dataSenderId == childId;
    }).toList();
  }

  /// Obtener conteo de notificaciones no leídas para un usuario
  int getUnreadCount(String userId) {
    final notifications = getNotificationsForUser(userId);
    return notifications.where((n) => n['read'] != true).length;
  }

  /// Obtener conteo de no leídas para un hijo específico
  int getUnreadCountForChild(String userId, String childId) {
    final notifications = getNotificationsForChild(userId, childId);
    return notifications.where((n) => n['read'] != true).length;
  }

  /// Marcar notificación como leída
  Future<bool> markAsRead(String userId, String notificationId) async {
    if (_notificationsBox == null) return false;

    try {
      final key = '${userId}_$notificationId';
      final data = _notificationsBox!.get(key);

      if (data != null && data is Map) {
        final updatedData = Map<String, dynamic>.from(data);
        updatedData['read'] = true;
        updatedData['readAt'] = DateTime.now().millisecondsSinceEpoch;

        await _notificationsBox!.put(key, updatedData);
        ReleaseLogger.log('Notificación marcada como leída: $notificationId', tag: 'NotifCache');
        return true;
      }

      return false;
    } catch (e) {
      ReleaseLogger.error('Error marcando notificación como leída: $e', tag: 'NotifCache');
      return false;
    }
  }

  /// Marcar todas las notificaciones de un hijo como leídas
  Future<int> markAllAsReadForChild(String userId, String childId) async {
    if (_notificationsBox == null) return 0;

    try {
      final notifications = getNotificationsForChild(userId, childId);
      int count = 0;

      for (final notif in notifications) {
        if (notif['read'] != true) {
          final success = await markAsRead(userId, notif['id'] as String);
          if (success) count++;
        }
      }

      ReleaseLogger.log('$count notificaciones marcadas como leídas para hijo $childId', tag: 'NotifCache');
      return count;
    } catch (e) {
      ReleaseLogger.error('Error marcando todas como leídas: $e', tag: 'NotifCache');
      return 0;
    }
  }

  /// Eliminar una notificación del cache
  Future<bool> deleteNotification(String userId, String notificationId) async {
    if (_notificationsBox == null) return false;

    try {
      final key = '${userId}_$notificationId';
      await _notificationsBox!.delete(key);
      ReleaseLogger.log('Notificación eliminada del cache: $notificationId', tag: 'NotifCache');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error eliminando notificación: $e', tag: 'NotifCache');
      return false;
    }
  }

  /// Verificar si una notificación ya está cacheada
  bool isNotificationCached(String userId, String notificationId) {
    if (_notificationsBox == null) return false;

    final key = '${userId}_$notificationId';
    return _notificationsBox!.containsKey(key);
  }

  /// Limpiar todas las notificaciones de un usuario
  Future<void> clearAllForUser(String userId) async {
    if (_notificationsBox == null) return;

    try {
      final keysToDelete = <String>[];

      for (final key in _notificationsBox!.keys) {
        if (key.toString().startsWith('${userId}_')) {
          keysToDelete.add(key.toString());
        }
      }

      for (final key in keysToDelete) {
        await _notificationsBox!.delete(key);
      }

      ReleaseLogger.log('${keysToDelete.length} notificaciones eliminadas para usuario $userId', tag: 'NotifCache');
    } catch (e) {
      ReleaseLogger.error('Error limpiando notificaciones: $e', tag: 'NotifCache');
    }
  }

  /// Limpiar notificaciones viejas (más de _retentionDays días)
  Future<void> _cleanupOldNotifications() async {
    if (_notificationsBox == null) return;

    try {
      final cutoff = DateTime.now()
          .subtract(Duration(days: _retentionDays))
          .millisecondsSinceEpoch;

      final keysToDelete = <String>[];

      for (final key in _notificationsBox!.keys) {
        final data = _notificationsBox!.get(key);
        if (data != null && data is Map) {
          final createdAt = data['createdAt'] as int? ?? 0;
          if (createdAt < cutoff) {
            keysToDelete.add(key.toString());
          }
        }
      }

      for (final key in keysToDelete) {
        await _notificationsBox!.delete(key);
      }

      if (keysToDelete.isNotEmpty) {
        ReleaseLogger.log('Limpieza: ${keysToDelete.length} notificaciones viejas eliminadas', tag: 'NotifCache');
      }
    } catch (e) {
      ReleaseLogger.error('Error en limpieza de notificaciones: $e', tag: 'NotifCache');
    }
  }

  /// Enforce límite de notificaciones por usuario
  Future<void> _enforceLimit(String userId) async {
    if (_notificationsBox == null) return;

    try {
      final notifications = getNotificationsForUser(userId);

      if (notifications.length > _maxNotificationsPerUser) {
        // Eliminar las más viejas (ya están ordenadas por fecha desc)
        final toDelete = notifications.sublist(_maxNotificationsPerUser);

        for (final notif in toDelete) {
          final id = notif['id'] as String?;
          if (id != null) {
            await deleteNotification(userId, id);
          }
        }

        ReleaseLogger.log('Límite enforced: ${toDelete.length} notificaciones viejas eliminadas', tag: 'NotifCache');
      }
    } catch (e) {
      ReleaseLogger.error('Error enforcing límite: $e', tag: 'NotifCache');
    }
  }

  /// Cerrar el servicio
  Future<void> close() async {
    try {
      await _notificationsBox?.close();
      _isInitialized = false;
      ReleaseLogger.log('NotificationCacheService cerrado', tag: 'NotifCache');
    } catch (e) {
      ReleaseLogger.error('Error cerrando NotificationCacheService: $e', tag: 'NotifCache');
    }
  }
}
