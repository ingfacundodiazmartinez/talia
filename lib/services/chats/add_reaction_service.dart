import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Servicio atómico: Agregar reacción a mensaje
///
/// Responsabilidad única: Agregar emoji de reacción a un mensaje
///
/// Estructura de reacciones en Firestore:
/// reactions: {
///   "❤️": ["userId1", "userId2"],
///   "😂": ["userId3"],
///   "👍": ["userId1"]
/// }
class AddReactionService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  AddReactionService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Agregar reacción a un mensaje
  ///
  /// [chatId] - ID del chat
  /// [messageId] - ID del mensaje
  /// [emoji] - Emoji de reacción (ej: "❤️", "👍", "😂")
  /// [isGroup] - true si es grupo
  ///
  /// Nota: Si el usuario ya reaccionó con otro emoji, primero se quita
  /// la reacción anterior.
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

      if (emoji.isEmpty) {
        return (success: false, message: 'Emoji no válido');
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

      // Remover usuario de cualquier otra reacción
      for (final key in reactions.keys.toList()) {
        final users = List<String>.from(reactions[key] ?? []);
        if (users.contains(userId)) {
          users.remove(userId);
          if (users.isEmpty) {
            reactions.remove(key);
          } else {
            reactions[key] = users;
          }
        }
      }

      // Agregar nueva reacción
      final emojiUsers = List<String>.from(reactions[emoji] ?? []);
      if (!emojiUsers.contains(userId)) {
        emojiUsers.add(userId);
      }
      reactions[emoji] = emojiUsers;

      // Actualizar en Firestore
      await messageRef.update({
        'reactions': reactions,
      });

      ReleaseLogger.log(
        'Reacción agregada: $emoji a mensaje $messageId',
        tag: 'AddReaction',
      );

      return (success: true, message: 'Reacción agregada');
    } catch (e) {
      ReleaseLogger.error('Error agregando reacción: $e', tag: 'AddReaction');
      return (success: false, message: 'Error al agregar reacción');
    }
  }

  /// Toggle de reacción (agregar si no existe, quitar si existe)
  Future<({bool success, bool added, String message})> toggle({
    required String chatId,
    required String messageId,
    required String emoji,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          added: false,
          message: 'Usuario no autenticado',
        );
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();

      if (!messageDoc.exists) {
        return (
          success: false,
          added: false,
          message: 'Mensaje no encontrado',
        );
      }

      final data = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
      final emojiUsers = List<String>.from(reactions[emoji] ?? []);

      bool added;
      if (emojiUsers.contains(userId)) {
        // Quitar reacción
        emojiUsers.remove(userId);
        added = false;
        if (emojiUsers.isEmpty) {
          reactions.remove(emoji);
        } else {
          reactions[emoji] = emojiUsers;
        }
      } else {
        // Agregar reacción
        emojiUsers.add(userId);
        reactions[emoji] = emojiUsers;
        added = true;
      }

      await messageRef.update({
        'reactions': reactions,
      });

      return (
        success: true,
        added: added,
        message: added ? 'Reacción agregada' : 'Reacción removida',
      );
    } catch (e) {
      ReleaseLogger.error('Error toggle reacción: $e', tag: 'AddReaction');
      return (
        success: false,
        added: false,
        message: 'Error al cambiar reacción',
      );
    }
  }

  /// Verificar si el usuario actual reaccionó con un emoji
  Future<bool> hasReacted({
    required String chatId,
    required String messageId,
    required String emoji,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return false;

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageDoc = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get();

      if (!messageDoc.exists) return false;

      final data = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
      final emojiUsers = List<String>.from(reactions[emoji] ?? []);

      return emojiUsers.contains(userId);
    } catch (e) {
      return false;
    }
  }
}
