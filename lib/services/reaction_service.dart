import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:talia/utils/release_logger.dart';

/// ✅ V2 ARCHITECTURE: Modelo para reacción independiente
///
/// Las reacciones se almacenan en subcollection separada para:
/// - Sobrevivir eliminación del mensaje original
/// - Funcionar con mensajes en cache local
class Reaction {
  final String id;            // {messageId}_{userId}
  final String messageId;
  final String userId;
  final String reaction;      // Emoji
  final DateTime createdAt;

  Reaction({
    required this.id,
    required this.messageId,
    required this.userId,
    required this.reaction,
    required this.createdAt,
  });

  factory Reaction.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Reaction(
      id: doc.id,
      messageId: data['messageId'] ?? '',
      userId: data['userId'] ?? '',
      reaction: data['reaction'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
    'messageId': messageId,
    'userId': userId,
    'reaction': reaction,
    'createdAt': FieldValue.serverTimestamp(),
  };
}

class ReactionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static final ReactionService _instance = ReactionService._internal();
  factory ReactionService() => _instance;
  ReactionService._internal();

  /// ✅ V2: Agregar o quitar reacción usando subcollection separada
  ///
  /// Almacena en: {collection}/{chatId}/reactions/{messageId}_{userId}
  /// Esto permite que las reacciones sobrevivan a la eliminación del mensaje
  Future<void> toggleReactionV2({
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

      final collection = isGroup ? 'groups_v2' : 'chats';
      final reactionId = '${messageId}_${currentUser.uid}';

      final reactionRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('reactions')
          .doc(reactionId);

      final existingReaction = await reactionRef.get();

      if (existingReaction.exists) {
        final existingEmoji = existingReaction.data()?['reaction'];

        if (existingEmoji == reaction) {
          // Mismo emoji - eliminar reacción
          await reactionRef.delete();
          ReleaseLogger.log('✅ [ReactionV2] Reacción eliminada: $messageId');
        } else {
          // Diferente emoji - actualizar reacción
          await reactionRef.update({
            'reaction': reaction,
            'createdAt': FieldValue.serverTimestamp(),
          });
          ReleaseLogger.log('✅ [ReactionV2] Reacción actualizada: $messageId -> $reaction');
        }
      } else {
        // Nueva reacción
        await reactionRef.set({
          'messageId': messageId,
          'userId': currentUser.uid,
          'reaction': reaction,
          'createdAt': FieldValue.serverTimestamp(),
        });
        ReleaseLogger.log('✅ [ReactionV2] Nueva reacción: $messageId -> $reaction');
      }

      // ✅ También actualizar el campo reactions en el mensaje para compatibilidad
      // con la UI actual (opcional, puede eliminarse después de migración completa)
      await _updateLegacyReactions(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

    } catch (e) {
      ReleaseLogger.error('❌ [ReactionV2] Error: $e');
      rethrow;
    }
  }

  /// ✅ V2: Stream de reacciones para un chat
  ///
  /// Retorna un Map con estructura: messageId -> (emoji -> lista de userIds)
  Stream<Map<String, Map<String, List<String>>>> watchReactions({
    required String chatId,
    bool isGroup = false,
  }) {
    final collection = isGroup ? 'groups_v2' : 'chats';

    return _firestore
        .collection(collection)
        .doc(chatId)
        .collection('reactions')
        .snapshots()
        .map((snapshot) {
          final result = <String, Map<String, List<String>>>{};

          for (final doc in snapshot.docs) {
            final data = doc.data();
            final messageId = data['messageId'] as String? ?? '';
            final userId = data['userId'] as String? ?? '';
            final reaction = data['reaction'] as String? ?? '';

            if (messageId.isEmpty || userId.isEmpty || reaction.isEmpty) continue;

            result.putIfAbsent(messageId, () => {});
            result[messageId]!.putIfAbsent(reaction, () => []);
            result[messageId]![reaction]!.add(userId);
          }

          return result;
        });
  }

  /// ✅ V2: Obtener reacciones para un mensaje específico
  Future<Map<String, List<String>>> getReactionsForMessage({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      final snapshot = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('reactions')
          .where('messageId', isEqualTo: messageId)
          .get();

      final result = <String, List<String>>{};

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final userId = data['userId'] as String? ?? '';
        final reaction = data['reaction'] as String? ?? '';

        if (userId.isEmpty || reaction.isEmpty) continue;

        result.putIfAbsent(reaction, () => []);
        result[reaction]!.add(userId);
      }

      return result;
    } catch (e) {
      ReleaseLogger.error('❌ [ReactionV2] Error obteniendo reacciones: $e');
      return {};
    }
  }

  /// Actualizar campo legacy reactions en el mensaje (para compatibilidad)
  Future<void> _updateLegacyReactions({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      // Obtener todas las reacciones para este mensaje
      final reactions = await getReactionsForMessage(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      // Actualizar el mensaje con las reacciones agregadas
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();
      if (messageDoc.exists) {
        await messageRef.update({'reactions': reactions});
      }
    } catch (e) {
      // No es crítico si falla la actualización legacy
      ReleaseLogger.log('⚠️ [ReactionV2] No se pudo actualizar legacy reactions: $e');
    }
  }

  /// ⚠️ LEGACY: Agregar o quitar reacción a un mensaje (guarda en el mensaje)
  /// @deprecated Usar toggleReactionV2 para nueva arquitectura
  Future<void> toggleReaction({
    required String chatId,
    required String messageId,
    required String reaction,
    bool isGroup = false,
  }) async {
    // Usar V2 por defecto
    await toggleReactionV2(
      chatId: chatId,
      messageId: messageId,
      reaction: reaction,
      isGroup: isGroup,
    );
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
