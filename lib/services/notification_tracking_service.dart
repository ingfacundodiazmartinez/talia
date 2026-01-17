import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/release_logger.dart';

/// Servicio simplificado para limpiar TODAS las notificaciones al entrar a la app
class NotificationTrackingService {
  static final NotificationTrackingService _instance = NotificationTrackingService._internal();
  factory NotificationTrackingService() => _instance;
  NotificationTrackingService._internal();

  FlutterLocalNotificationsPlugin? _localNotifications;

  static const _channel = MethodChannel('com.talia.chat/notifications');

  /// Inicializar con referencia al plugin de notificaciones
  void initialize(FlutterLocalNotificationsPlugin localNotifications) {
    _localNotifications = localNotifications;
    ReleaseLogger.log(
      '✅ [NotificationTracking] Servicio inicializado',
      tag: 'NotificationTracking',
    );
  }

  /// ✅ MÉTODO PRINCIPAL: Limpiar TODAS las notificaciones al entrar a la app
  Future<void> clearAllNotifications() async {
    try {
      ReleaseLogger.log(
        '🧹 [NotificationTracking] Limpiando TODAS las notificaciones...',
        tag: 'NotificationTracking',
      );

      // 1. Limpiar via flutter_local_notifications
      if (_localNotifications != null) {
        await _localNotifications!.cancelAll();
      }

      // 2. Limpiar notificaciones nativas via platform channel
      if (Platform.isAndroid) {
        try {
          await _channel.invokeMethod('cancelAllNotifications');
          ReleaseLogger.log(
            '🤖 [NotificationTracking] Android: cancelAllNotifications OK',
            tag: 'NotificationTracking',
          );
        } catch (e) {
          ReleaseLogger.log(
            '⚠️ [NotificationTracking] Android error: $e',
            tag: 'NotificationTracking',
          );
        }
      } else if (Platform.isIOS) {
        try {
          await _channel.invokeMethod('removeAllDeliveredNotifications');
          ReleaseLogger.log(
            '📱 [NotificationTracking] iOS: removeAllDeliveredNotifications OK',
            tag: 'NotificationTracking',
          );
        } catch (e) {
          ReleaseLogger.log(
            '⚠️ [NotificationTracking] iOS error: $e',
            tag: 'NotificationTracking',
          );
        }
      }

      ReleaseLogger.log(
        '✅ [NotificationTracking] Todas las notificaciones limpiadas',
        tag: 'NotificationTracking',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [NotificationTracking] Error: $e',
        tag: 'NotificationTracking',
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Métodos legacy (mantenidos por compatibilidad)
  // ══════════════════════════════════════════════════════════════════

  Future<void> dismissNotificationsForContext({
    required String type,
    required String contextId,
  }) async {
    await clearAllNotifications();
  }

  Future<void> trackNotification({
    required String type,
    required String contextId,
    required int notificationId,
  }) async {
    // No-op
  }

  static int generateNotificationId(String type, String contextId, {String? messageId}) {
    final key = messageId != null
        ? '${type}_${contextId}_$messageId'
        : '${type}_$contextId';
    return key.hashCode.abs() % 2147483647;
  }
}

/// Tipos de contexto (mantenido por compatibilidad)
class NotificationContext {
  static const String chat = 'chat';
  static const String group = 'group';
  static const String story = 'story';
  static const String storyApproval = 'story_approval';
  static const String groupApproval = 'group_approval';
  static const String contactRequest = 'contact_request';
  static const String emergency = 'emergency';
  static const String alert = 'alert';
  static const String report = 'report';
}
