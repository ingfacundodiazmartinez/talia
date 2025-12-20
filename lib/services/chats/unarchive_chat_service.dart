import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Desarchivar chat
///
/// Responsabilidad única: Remover chat de la lista de archivados
///
/// Nota: Operación local en cache (Hive), sin escritura a Firestore.
class UnarchiveChatService {
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  UnarchiveChatService({
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Desarchivar un chat
  ///
  /// [chatId] - ID del chat a desarchivar
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

      // Verificar si está archivado
      if (!_preferencesCache.isArchived(chatId)) {
        return (success: true, message: 'El chat no está archivado');
      }

      // Desarchivar en cache local
      await _preferencesCache.unarchiveChat(chatId);

      ReleaseLogger.log(
        'Chat desarchivado: $chatId',
        tag: 'UnarchiveChat',
      );

      return (success: true, message: 'Chat desarchivado');
    } catch (e) {
      ReleaseLogger.error('Error desarchivando chat: $e', tag: 'UnarchiveChat');
      return (success: false, message: 'Error al desarchivar chat');
    }
  }
}
