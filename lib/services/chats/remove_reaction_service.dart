import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Servicio atómico: Remover reacción de mensaje
///
/// Responsabilidad única: Quitar emoji de reacción de un mensaje
class RemoveReactionService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RemoveReactionService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Remover reacción de un mensaje
  ///
  /// [chatId] - ID del chat
  /// [messageId] - ID del mensaje
  /// [emoji] - Emoji de reacción a quitar (ej: "❤️")
  /// [isGroup] - true si es grupo
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String chatId,
    required String messageId,
    required String emoji,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();

      if (!messageDoc.exists) {
        return (success: false, message: 'Mensaje no encontrado');
      }

      // Obtener reacciones actuales
      final data = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
      final emojiUsers = List<String>.from(reactions[emoji] ?? []);

      // Verificar si el usuario tiene la reacción
      if (!emojiUsers.contains(userId)) {
        return (success: true, message: 'No tienes esta reacción');
      }

      // Remover usuario de la reacción
      emojiUsers.remove(userId);

      // Si no quedan usuarios, eliminar el emoji completamente
      if (emojiUsers.isEmpty) {
        reactions.remove(emoji);
      } else {
        reactions[emoji] = emojiUsers;
      }

      // Actualizar en Firestore
      await messageRef.update({
        'reactions': reactions,
      });

      ReleaseLogger.log(
        'Reacción removida: $emoji de mensaje $messageId',
        tag: 'RemoveReaction',
      );

      return (success: true, message: 'Reacción removida');
    } catch (e) {
      ReleaseLogger.error('Error removiendo reacción: $e', tag: 'RemoveReaction');
      return (success: false, message: 'Error al remover reacción');
    }
  }

  /// Remover todas las reacciones del usuario actual de un mensaje
  Future<({bool success, String message})> removeAll({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();

      if (!messageDoc.exists) {
        return (success: false, message: 'Mensaje no encontrado');
      }

      // Obtener y limpiar reacciones del usuario
      final data = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
      bool changed = false;

      for (final emoji in reactions.keys.toList()) {
        final users = List<String>.from(reactions[emoji] ?? []);
        if (users.contains(userId)) {
          users.remove(userId);
          changed = true;
          if (users.isEmpty) {
            reactions.remove(emoji);
          } else {
            reactions[emoji] = users;
          }
        }
      }

      if (!changed) {
        return (success: true, message: 'No tenías reacciones');
      }

      // Actualizar en Firestore
      await messageRef.update({
        'reactions': reactions,
      });

      ReleaseLogger.log(
        'Todas las reacciones removidas de mensaje $messageId',
        tag: 'RemoveReaction',
      );

      return (success: true, message: 'Reacciones removidas');
    } catch (e) {
      ReleaseLogger.error('Error removiendo reacciones: $e', tag: 'RemoveReaction');
      return (success: false, message: 'Error al remover reacciones');
    }
  }
}
