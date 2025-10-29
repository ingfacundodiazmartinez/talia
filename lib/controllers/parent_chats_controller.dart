import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'base_chats_controller.dart';
import '../models/chat_list_item_type.dart';

/// Controller para manejar la lógica de negocio de Parent Chats
///
/// Responsabilidades:
/// - Proveer streams específicos de padre (linkedChildren)
/// - Construir lista de items de chat específica de padre
class ParentChatsController extends BaseChatsController {
  ParentChatsController({
    required super.userId,
    super.firestore,
    super.chatService,
    super.groupChatService,
  });

  /// Stream de relaciones padre-hijo aprobadas
  /// Lee desde /users/{userId}.linkedChildrenIds por seguridad
  Stream<List<String>> getParentChildLinksStream() {
    return FirebaseFirestore.instance.collection('users').doc(userId).snapshots().map((
      snapshot,
    ) {
      if (!snapshot.exists) {
        debugPrint('⚠️ [ParentChatsController] Usuario $userId no existe');
        return <String>[];
      }

      final userData = snapshot.data();
      if (userData == null) {
        debugPrint('⚠️ [ParentChatsController] userData es null para $userId');
        return <String>[];
      }

      // Verificar que el usuario tenga rol 'parent' o 'adult'
      final role = userData['role'] as String?;
      if (role != 'parent' && role != 'adult') {
        debugPrint(
          '⚠️ [ParentChatsController] Usuario $userId tiene rol "$role" (esperado: "parent" o "adult")',
        );
        return <String>[];
      }

      // Si es 'adult', no tiene hijos vinculados, retornar lista vacía
      if (role == 'adult') {
        debugPrint(
          'ℹ️ [ParentChatsController] Usuario $userId es "adult" (padre sin hijos vinculados)',
        );
        return <String>[];
      }

      final linkedChildren = userData['linkedChildrenIds'];
      if (linkedChildren == null) {
        debugPrint(
          'ℹ️ [ParentChatsController] Usuario $userId no tiene linkedChildrenIds',
        );
        return <String>[];
      }

      return List<String>.from(linkedChildren);
    });
  }

  /// Construye la lista de items para mostrar en la UI
  /// Todos los chats tienen la misma jerarquía (sin agrupación)
  List<ChatListItemType> buildListItems({
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) {
    final List<ChatListItemType> items = [];

    // Ordenar chats por última actividad
    sortChatsByLastActivity(chatDocs);

    // Agregar chats a la lista
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != userId,
        orElse: () => '',
      );

      if (otherUserId.isNotEmpty) {
        items.add(
          ChatItem(userId: otherUserId, userData: {}, chatDoc: chatDoc),
        );
      }
    }

    // Add groups
    for (final groupDoc in groups) {
      final groupData = groupDoc.data() as Map<String, dynamic>;
      items.add(GroupItem(groupId: groupDoc.id, groupData: groupData));
    }

    return items;
  }
}
