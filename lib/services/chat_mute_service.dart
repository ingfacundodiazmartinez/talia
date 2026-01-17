import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/remote_logger_service.dart';

/// Servicio para silenciar y desilenciar chats
///
/// Responsabilidades:
/// - Silenciar chats (deshabilitar notificaciones para un usuario específico)
/// - Desilenciar chats
/// - Verificar si un chat está silenciado
class ChatMuteService {
  static final ChatMuteService _instance = ChatMuteService._internal();
  factory ChatMuteService() => _instance;
  ChatMuteService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Silenciar un chat para un usuario específico
  ///
  /// Parámetros:
  /// - chatId: ID del chat a silenciar
  /// - userId: ID del usuario que silencia el chat
  ///
  /// Retorna true si se silenció correctamente, false en caso de error
  Future<bool> muteChat({
    required String chatId,
    required String userId,
  }) async {
    try {
      appLogger.log('🔕 Silenciando chat $chatId para usuario $userId', level: 'INFO');

      await _firestore.collection('chats').doc(chatId).update({
        'muted_$userId': true,
        'mutedAt_$userId': FieldValue.serverTimestamp(),
      });

      appLogger.log('✅ Chat silenciado exitosamente', level: 'INFO');
      return true;
    } catch (e) {
      appLogger.log('❌ Error silenciando chat: $e', level: 'ERROR');
      return false;
    }
  }

  /// Desilenciar un chat para un usuario específico
  ///
  /// Parámetros:
  /// - chatId: ID del chat a desilenciar
  /// - userId: ID del usuario que desilencia el chat
  ///
  /// Retorna true si se desilenció correctamente, false en caso de error
  Future<bool> unmuteChat({
    required String chatId,
    required String userId,
  }) async {
    try {
      appLogger.log('🔔 Desilenciando chat $chatId para usuario $userId', level: 'INFO');

      await _firestore.collection('chats').doc(chatId).update({
        'muted_$userId': false,
        'mutedAt_$userId': FieldValue.delete(),
      });

      appLogger.log('✅ Chat desilenciado exitosamente', level: 'INFO');
      return true;
    } catch (e) {
      appLogger.log('❌ Error desilenciando chat: $e', level: 'ERROR');
      return false;
    }
  }

  /// Verificar si un chat está silenciado para un usuario
  ///
  /// Parámetros:
  /// - chatId: ID del chat
  /// - userId: ID del usuario
  ///
  /// Retorna true si el chat está silenciado, false en caso contrario
  Future<bool> isChatMuted({
    required String chatId,
    required String userId,
  }) async {
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return false;

      final data = chatDoc.data();
      return data?['muted_$userId'] ?? false;
    } catch (e) {
      appLogger.log('❌ Error verificando si el chat está silenciado: $e', level: 'ERROR');
      return false;
    }
  }

  /// Stream para verificar si un chat está silenciado
  Stream<bool> watchChatMuted({
    required String chatId,
    required String userId,
  }) {
    return _firestore.collection('chats').doc(chatId).snapshots().map((snapshot) {
      if (!snapshot.exists) return false;
      final data = snapshot.data();
      return data?['muted_$userId'] ?? false;
    });
  }
}
