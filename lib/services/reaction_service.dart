import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ReactionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Agregar o quitar reacción a un mensaje
  Future<void> toggleReaction({
    required String chatId,
    required String messageId,
    required String reaction,
    bool isGroup = false,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        throw Exception('Usuario no autenticado');
      }

      final messageRef = _firestore
          .collection(isGroup ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(messageRef);

        if (!snapshot.exists) {
          throw Exception('Mensaje no encontrado');
        }

        final data = snapshot.data() as Map<String, dynamic>;
        final reactions = Map<String, List<String>>.from(
          data['reactions'] ?? {},
        );

        // Si el usuario ya reaccionó con este emoji, quitarlo
        if (reactions.containsKey(reaction)) {
          final users = List<String>.from(reactions[reaction]!);
          if (users.contains(currentUser.uid)) {
            users.remove(currentUser.uid);
            if (users.isEmpty) {
              reactions.remove(reaction);
            } else {
              reactions[reaction] = users;
            }
          } else {
            // Agregar reacción
            users.add(currentUser.uid);
            reactions[reaction] = users;
          }
        } else {
          // Primera reacción de este tipo
          reactions[reaction] = [currentUser.uid];
        }

        transaction.update(messageRef, {'reactions': reactions});
      });

      print('✅ Reacción actualizada: $reaction');
    } catch (e) {
      print('❌ Error actualizando reacción: $e');
      rethrow;
    }
  }

  /// Obtener reacciones de un mensaje
  Map<String, int> getReactionCounts(Map<String, dynamic>? reactions) {
    if (reactions == null) return {};

    final counts = <String, int>{};
    reactions.forEach((reaction, users) {
      if (users is List) {
        counts[reaction] = users.length;
      }
    });

    return counts;
  }

  /// Verificar si el usuario actual reaccionó con un emoji específico
  bool hasUserReacted({
    required Map<String, dynamic>? reactions,
    required String reaction,
  }) {
    if (reactions == null) return false;

    final currentUser = _auth.currentUser;
    if (currentUser == null) return false;

    final users = reactions[reaction];
    if (users is List) {
      return users.contains(currentUser.uid);
    }

    return false;
  }
}
