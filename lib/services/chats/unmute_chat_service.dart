import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Desilenciar chat
///
/// Remueve el mute tanto del cache local Hive como del map
/// `users/{uid}.mutedChats` en Firestore (para que el push server-side vuelva
/// a permitir notificaciones).
class UnmuteChatService {
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  UnmuteChatService({
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Desilenciar un chat
  ///
  /// [chatId] - ID del chat a desilenciar
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String chatId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      // Verificar si está silenciado
      if (!_preferencesCache.isMuted(chatId)) {
        return (success: true, message: 'El chat no está silenciado');
      }

      // Desilenciar en cache local
      await _preferencesCache.unmuteChat(chatId);

      // ✅ Audit #11: limpiar también en Firestore.
      try {
        await FirebaseFirestore.instance.collection('users').doc(userId).update({
          'mutedChats.$chatId': FieldValue.delete(),
        });
      } catch (e) {
        ReleaseLogger.warning(
          'Error limpiando mute en Firestore (local OK): $e',
          tag: 'UnmuteChat',
        );
      }

      ReleaseLogger.log(
        'Chat desilenciado: $chatId',
        tag: 'UnmuteChat',
      );

      return (success: true, message: 'Chat desilenciado');
    } catch (e) {
      ReleaseLogger.error('Error desilenciando chat: $e', tag: 'UnmuteChat');
      return (success: false, message: 'Error al desilenciar chat');
    }
  }
}
