import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Silenciar chat
///
/// Responsabilidad única: Silenciar notificaciones de un chat.
///
/// El estado se guarda en DOS lugares:
/// - Hive local (lecturas instantáneas para la UI).
/// - Firestore `users/{uid}.mutedChats` (map chatId → expiresAt|null) para que
///   `sendNotificationOnCreate` skipee el push server-side y no gastemos quota
///   en notificaciones que el cliente igual va a filtrar.
class MuteChatService {
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  MuteChatService({
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Silenciar un chat
  ///
  /// [chatId] - ID del chat a silenciar
  /// [duration] - Duración del silencio (null = indefinido)
  ///
  /// Duraciones comunes:
  /// - 1 hora: Duration(hours: 1)
  /// - 8 horas: Duration(hours: 8)
  /// - 1 semana: Duration(days: 7)
  /// - Indefinido: null
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String chatId,
    Duration? duration,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      // Calcular fecha hasta cuando está silenciado
      final until = duration != null ? DateTime.now().add(duration) : null;

      // Silenciar en cache local
      await _preferencesCache.muteChat(chatId, until: until);

      // ✅ Audit #11: persistir también en Firestore para que el CF de push
      // filtre server-side.
      try {
        await FirebaseFirestore.instance.collection('users').doc(userId).set({
          'mutedChats': {
            chatId: until != null ? Timestamp.fromDate(until) : true,
          },
        }, SetOptions(merge: true));
      } catch (e) {
        // No fallar el flujo si Firestore falla — Hive local sigue funcionando.
        ReleaseLogger.warning(
          'Error persistiendo mute a Firestore (cliente sigue muteado local): $e',
          tag: 'MuteChat',
        );
      }

      final durationText = duration != null
          ? _formatDuration(duration)
          : 'indefinidamente';

      ReleaseLogger.log(
        'Chat silenciado: $chatId por $durationText',
        tag: 'MuteChat',
      );

      return (success: true, message: 'Chat silenciado $durationText');
    } catch (e) {
      ReleaseLogger.error('Error silenciando chat: $e', tag: 'MuteChat');
      return (success: false, message: 'Error al silenciar chat');
    }
  }

  /// Silenciar por 1 hora
  Future<({bool success, String message})> muteFor1Hour(String chatId) {
    return call(chatId: chatId, duration: const Duration(hours: 1));
  }

  /// Silenciar por 8 horas
  Future<({bool success, String message})> muteFor8Hours(String chatId) {
    return call(chatId: chatId, duration: const Duration(hours: 8));
  }

  /// Silenciar por 1 día
  Future<({bool success, String message})> muteFor1Day(String chatId) {
    return call(chatId: chatId, duration: const Duration(days: 1));
  }

  /// Silenciar por 1 semana
  Future<({bool success, String message})> muteFor1Week(String chatId) {
    return call(chatId: chatId, duration: const Duration(days: 7));
  }

  /// Silenciar indefinidamente
  Future<({bool success, String message})> muteIndefinitely(String chatId) {
    return call(chatId: chatId, duration: null);
  }

  /// Verificar si un chat está silenciado
  bool isMuted(String chatId) {
    return _preferencesCache.isMuted(chatId);
  }

  /// Obtener fecha hasta cuando está silenciado
  DateTime? getMutedUntil(String chatId) {
    return _preferencesCache.getMutedUntil(chatId);
  }

  /// Formatear duración para mensaje
  String _formatDuration(Duration duration) {
    if (duration.inDays > 0) {
      return 'por ${duration.inDays} día${duration.inDays > 1 ? 's' : ''}';
    } else if (duration.inHours > 0) {
      return 'por ${duration.inHours} hora${duration.inHours > 1 ? 's' : ''}';
    } else if (duration.inMinutes > 0) {
      return 'por ${duration.inMinutes} minuto${duration.inMinutes > 1 ? 's' : ''}';
    }
    return 'por un momento';
  }
}
