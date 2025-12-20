import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Archivar chat
///
/// Responsabilidad única: Marcar chat como archivado para el usuario actual
///
/// Nota: El estado "archivado" se guarda SOLO en cache local (Hive),
/// NO en Firestore. Esto porque:
/// - Solo afecta la UI local del usuario
/// - No necesita sincronización entre dispositivos (preferencia menor)
/// - Reduce escrituras a Firestore = menos costo
/// - Operación instantánea sin latencia de red
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
