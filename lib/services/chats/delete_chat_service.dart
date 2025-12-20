import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Eliminar chat (soft delete local)
///
/// Responsabilidad única: Marcar chat como eliminado para el usuario actual
///
/// Nota: Este es un SOFT DELETE LOCAL:
/// - El chat NO se elimina de Firestore
/// - Solo se oculta de la lista del usuario actual
/// - El otro participante sigue viendo el chat
/// - Se puede restaurar con RestoreChatService
///
/// Para eliminar permanentemente un chat (hard delete), se requiere
/// una Cloud Function que verifique que ambos usuarios lo eliminaron.
class DeleteChatService {
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  DeleteChatService({
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Eliminar un chat (soft delete local)
  ///
  /// [chatId] - ID del chat a eliminar
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

      // Verificar si ya está eliminado
      if (_preferencesCache.isDeleted(chatId)) {
        return (success: true, message: 'El chat ya está eliminado');
      }

      // Marcar como eliminado en cache local
      await _preferencesCache.deleteChat(chatId);

      // También limpiar otras preferencias relacionadas
      await _preferencesCache.markAsRead(chatId);

      ReleaseLogger.log(
        'Chat eliminado (soft delete local): $chatId',
        tag: 'DeleteChat',
      );

      return (success: true, message: 'Chat eliminado');
    } catch (e) {
      ReleaseLogger.error('Error eliminando chat: $e', tag: 'DeleteChat');
      return (success: false, message: 'Error al eliminar chat');
    }
  }

  /// Restaurar un chat eliminado
  ///
  /// [chatId] - ID del chat a restaurar
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> restore({
    required String chatId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      // Verificar si está eliminado
      if (!_preferencesCache.isDeleted(chatId)) {
        return (success: true, message: 'El chat no está eliminado');
      }

      // Restaurar en cache local
      await _preferencesCache.restoreChat(chatId);

      ReleaseLogger.log(
        'Chat restaurado: $chatId',
        tag: 'DeleteChat',
      );

      return (success: true, message: 'Chat restaurado');
    } catch (e) {
      ReleaseLogger.error('Error restaurando chat: $e', tag: 'DeleteChat');
      return (success: false, message: 'Error al restaurar chat');
    }
  }

  /// Verificar si un chat está eliminado
  bool isDeleted(String chatId) {
    return _preferencesCache.isDeleted(chatId);
  }

  /// Obtener lista de chats eliminados
  Set<String> getDeletedChats() {
    return _preferencesCache.getDeletedChats();
  }
}
