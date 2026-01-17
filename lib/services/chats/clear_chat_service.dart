import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Limpiar historial de chat
///
/// Responsabilidad única: Marcar timestamp desde el cual el usuario
/// no verá mensajes anteriores.
///
/// Nota: Este es un "clear" LOCAL:
/// - Los mensajes NO se eliminan de Firestore
/// - Solo se ocultan de la vista del usuario actual
/// - El otro participante sigue viendo todos los mensajes
/// - Se usa clearedAt timestamp para filtrar mensajes en queries
///
/// Uso en queries de mensajes:
/// ```dart
/// final clearedAt = ChatPreferencesCache().getClearedAt(chatId);
/// query.where('createdAt', isGreaterThan: clearedAt);
/// ```
class ClearChatService {
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  ClearChatService({
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Limpiar historial de un chat
  ///
  /// [chatId] - ID del chat a limpiar
  /// [fromDate] - Fecha desde la cual limpiar (default: ahora)
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String chatId,
    DateTime? fromDate,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final clearedAt = fromDate ?? DateTime.now();

      // Guardar timestamp de limpieza en cache local
      await _preferencesCache.setClearedAt(chatId, clearedAt);

      // También resetear contador de no leídos
      await _preferencesCache.markAsRead(chatId);

      ReleaseLogger.log(
        'Chat limpiado: $chatId desde $clearedAt',
        tag: 'ClearChat',
      );

      return (success: true, message: 'Historial limpiado');
    } catch (e) {
      ReleaseLogger.error('Error limpiando chat: $e', tag: 'ClearChat');
      return (success: false, message: 'Error al limpiar historial');
    }
  }

  /// Obtener timestamp de limpieza
  ///
  /// Retorna null si nunca se limpió el chat
  DateTime? getClearedAt(String chatId) {
    return _preferencesCache.getClearedAt(chatId);
  }

  /// Verificar si hay mensajes ocultos por limpieza
  bool hasClearedHistory(String chatId) {
    return _preferencesCache.getClearedAt(chatId) != null;
  }

  /// Restaurar historial completo (eliminar clearedAt)
  Future<({bool success, String message})> restoreHistory({
    required String chatId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      // Verificar si hay algo que restaurar
      if (_preferencesCache.getClearedAt(chatId) == null) {
        return (success: true, message: 'No hay historial oculto');
      }

      // Limpiar el timestamp
      await _preferencesCache.clearClearedAt(chatId);

      ReleaseLogger.log(
        'Historial restaurado: $chatId',
        tag: 'ClearChat',
      );

      return (success: true, message: 'Historial restaurado');
    } catch (e) {
      ReleaseLogger.error('Error restaurando historial: $e', tag: 'ClearChat');
      return (success: false, message: 'Error al restaurar historial');
    }
  }
}
