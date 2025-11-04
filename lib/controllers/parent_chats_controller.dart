import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart';
import 'base_chats_controller.dart';
import '../models/chat_list_item_type.dart';
import '../services/search_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio de Parent Chats
///
/// Responsabilidades:
/// - Proveer streams específicos de padre (linkedChildren)
/// - Construir lista de items de chat específica de padre
/// - Manejo de búsquedas en mensajes y chats
/// - Obtener datos de usuarios y navegación a chats
class ParentChatsController extends BaseChatsController {
  final firebase_auth.FirebaseAuth _auth;
  final SearchService _searchService;

  ParentChatsController({
    required super.userId,
    super.firestore,
    super.chatService,
    super.groupChatService,
    firebase_auth.FirebaseAuth? auth,
    SearchService? searchService,
  }) : _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _searchService = searchService ?? SearchService();

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

  /// Obtener ID del usuario actual
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Obtener datos de usuario por ID
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    try {
      final userDoc = await firestore.collection('users').doc(userId).get();
      if (userDoc.exists) {
        return userDoc.data();
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de usuario $userId: $e', tag: 'ParentChats');
      return null;
    }
  }

  /// Stream de datos de usuario
  Stream<DocumentSnapshot> getUserDataStream(String userId) {
    return firestore.collection('users').doc(userId).snapshots();
  }

  /// Buscar en mensajes de todos los chats
  Future<SearchResults> performMessageSearch({
    required String query,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    if (query.isEmpty) {
      return SearchResults(chatResults: [], messageResults: []);
    }

    final chatResults = <ChatSearchResult>[];
    final messageResults = <MessageSearchResult>[];

    // Buscar en chats directos
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final chatId = chatDoc.id;
      final participants = chatData['participants'] as List<dynamic>?;

      if (participants == null) continue;

      final otherUserId = participants.firstWhere(
        (id) => id != currentUserId,
        orElse: () => null,
      );

      if (otherUserId == null) continue;

      try {
        // Obtener datos del usuario
        final userData = await getUserData(otherUserId);
        if (userData == null) continue;

        final userName = userData['name'] ?? 'Usuario';
        final photoURL = userData['photoURL'] as String?;

        // Verificar si coincide por nombre
        if (_searchService.matchesQuery(userName, query)) {
          chatResults.add(
            ChatSearchResult(
              chatId: chatId,
              chatName: userName,
              chatPhotoUrl: photoURL,
              chatType: ChatType.direct,
            ),
          );
        }

        // Buscar en mensajes del chat
        final chatMessageResults = await _searchService.searchInChatMessages(
          chatId: chatId,
          query: query,
          chatName: userName,
          chatPhotoUrl: photoURL,
          chatType: ChatType.direct,
        );
        messageResults.addAll(chatMessageResults);
      } catch (e) {
        ReleaseLogger.error('Error buscando en chat $chatId: $e', tag: 'ParentChats');
      }
    }

    // Buscar en grupos
    for (final groupDoc in groups) {
      final groupData = groupDoc.data() as Map<String, dynamic>;
      final groupId = groupDoc.id;
      final groupName = groupData['name'] ?? 'Grupo';
      final avatar = groupData['avatar'] as String?;

      // Verificar si coincide por nombre
      if (_searchService.matchesQuery(groupName, query)) {
        chatResults.add(
          ChatSearchResult(
            chatId: groupId,
            chatName: groupName,
            chatPhotoUrl: avatar,
            chatType: ChatType.group,
          ),
        );
      }

      // Buscar en mensajes del grupo
      try {
        final groupMessageResults = await _searchService.searchInChatMessages(
          chatId: groupId,
          query: query,
          chatName: groupName,
          chatPhotoUrl: avatar,
          chatType: ChatType.group,
        );
        messageResults.addAll(groupMessageResults);
      } catch (e) {
        ReleaseLogger.error('Error buscando en grupo $groupId: $e', tag: 'ParentChats');
      }
    }

    return SearchResults(
      chatResults: chatResults,
      messageResults: messageResults,
    );
  }

  /// Obtener último mensaje de un chat
  Stream<QuerySnapshot> getLastMessageStream(String chatId, {bool isGroup = false}) {
    final collection = isGroup ? 'groups' : 'chats';
    return firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots();
  }

  /// Obtener datos de chat para navegación
  Future<Map<String, dynamic>?> getChatDataForNavigation(String chatId) async {
    try {
      final chatDoc = await firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return null;

      final participants = chatDoc.data()?['participants'] as List<dynamic>?;
      if (participants == null) return null;

      final contactId = participants.firstWhere(
        (id) => id != currentUserId,
        orElse: () => null,
      );

      if (contactId == null) return null;

      return {
        'chatId': chatId,
        'contactId': contactId,
        'participants': participants,
      };
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de chat $chatId: $e', tag: 'ParentChats');
      return null;
    }
  }
}
