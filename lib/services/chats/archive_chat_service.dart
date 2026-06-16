import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Archivar chat
///
/// Responsabilidad única: Marcar chat como archivado para el usuario actual.
///
/// El estado se guarda en DOS lugares:
/// - Hive local (lecturas instantáneas para la UI, fuente principal).
/// - Firestore `users/{uid}.archivedChats` (map chatId → timestamp) para que
///   `sendNotificationOnCreate` skipee el push server-side. Sin esto, el
///   usuario recibe banners/FCM de chats archivados aunque no quiera verlos.
class ArchiveChatService {
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  ArchiveChatService({
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Archivar un chat
  ///
  /// [chatId] - ID del chat a archivar
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

      // Verificar si ya está archivado
      if (_preferencesCache.isArchived(chatId)) {
        return (success: true, message: 'El chat ya está archivado');
      }

      // Archivar en cache local
      await _preferencesCache.archiveChat(chatId);

      // 🔒 Persistir en Firestore para que la CF de push haga skip server-side.
      // Best-effort: si falla, el cliente sigue archivado local. La consecuencia
      // de un fail acá es que el user podría recibir un push de un chat
      // archivado hasta que vuelva a archivarlo o sincronice.
      try {
        await FirebaseFirestore.instance.collection('users').doc(userId).set({
          'archivedChats': {
            chatId: FieldValue.serverTimestamp(),
          },
        }, SetOptions(merge: true));
      } catch (e) {
        ReleaseLogger.warning(
          'Error persistiendo archive a Firestore (cliente sigue archivado local): $e',
          tag: 'ArchiveChat',
        );
      }

      ReleaseLogger.log(
        'Chat archivado: $chatId',
        tag: 'ArchiveChat',
      );

      return (success: true, message: 'Chat archivado');
    } catch (e) {
      ReleaseLogger.error('Error archivando chat: $e', tag: 'ArchiveChat');
      return (success: false, message: 'Error al archivar chat');
    }
  }

  /// Verificar si un chat está archivado
  bool isArchived(String chatId) {
    return _preferencesCache.isArchived(chatId);
  }

  /// Obtener lista de chats archivados
  Set<String> getArchivedChats() {
    return _preferencesCache.getArchivedChats();
  }
}
