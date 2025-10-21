import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/remote_logger_service.dart';

/// Servicio para limpiar mensajes de chats
///
/// Responsabilidades:
/// - Eliminar todos los mensajes de un chat para un usuario específico
/// - Mantener el chat pero limpiar su historial
class ChatClearService {
  static final ChatClearService _instance = ChatClearService._internal();
  factory ChatClearService() => _instance;
  ChatClearService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Limpiar todos los mensajes de un chat para un usuario específico
  ///
  /// Parámetros:
  /// - chatId: ID del chat a limpiar
  /// - userId: ID del usuario que limpia el chat
  ///
  /// Retorna true si se limpió correctamente, false en caso de error
  Future<bool> clearChat({
    required String chatId,
    required String userId,
  }) async {
    try {
      appLogger.log('🧹 Limpiando chat $chatId para usuario $userId', level: 'INFO');

      // Marcar el chat como limpio para este usuario
      // En lugar de borrar físicamente los mensajes, marcamos desde qué momento
      // el usuario ha limpiado el chat
      // NOTA: Solo actualizamos el timestamp personal y reseteamos contador de no leídos
      // NO actualizamos lastMessage global para evitar que el otro usuario vea "Sin mensajes"
      await _firestore.collection('chats').doc(chatId).update({
        'clearedAt_$userId': FieldValue.serverTimestamp(),
        'unreadCount_$userId': 0, // Resetear contador de mensajes no leídos
      });

      appLogger.log('✅ Chat limpiado exitosamente', level: 'INFO');
      return true;
    } catch (e) {
      appLogger.log('❌ Error limpiando chat: $e', level: 'ERROR');
      return false;
    }
  }

  /// Obtener el timestamp desde cuando el usuario limpió el chat
  ///
  /// Parámetros:
  /// - chatId: ID del chat
  /// - userId: ID del usuario
  ///
  /// Retorna el timestamp o null si nunca se limpió
  Future<Timestamp?> getClearedAt({
    required String chatId,
    required String userId,
  }) async {
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return null;

      final data = chatDoc.data() as Map<String, dynamic>?;
      return data?['clearedAt_$userId'] as Timestamp?;
    } catch (e) {
      appLogger.log('❌ Error obteniendo clearedAt: $e', level: 'ERROR');
      return null;
    }
  }
}
