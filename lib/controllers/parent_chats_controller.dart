import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart';
import 'base_chats_controller.dart';
import '../models/chat_list_item_type.dart';
import '../services/search_service.dart';
import '../services/user_profile_cache_service.dart';
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
  final UserProfileCacheService _userProfileService;

  ParentChatsController({
    required super.userId,
    super.firestore,
    super.chatService,
    super.groupChatService,
    firebase_auth.FirebaseAuth? auth,
    SearchService? searchService,
    UserProfileCacheService? userProfileService,
  }) : _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _searchService = searchService ?? SearchService(),
       _userProfileService = userProfileService ?? UserProfileCacheService();

  /// Stream de relaciones padre-hijo aprobadas
  /// Lee desde /users/{userId}.linkedChildrenIds por seguridad
  Stream<List<String>> getParentChildLinksStream() {
    // ✅ CODING_RULES: Delegando a UserProfileCacheService
    return _userProfileService.getUserDataStream(userId).map((
      snapshot,
    ) {
      if (!snapshot.exists) {
        debugPrint('⚠️ [ParentChatsController] Usuario $userId no existe');
        return <String>[];
      }

      final userData = snapshot.data() as Map<String, dynamic>?;
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
  /// Combina chats y grupos ordenados por última actividad
  List<ChatListItemType> buildListItems({
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) {
    // Crear lista combinada de items con timestamps para ordenar
    final List<_SortableItem> sortableItems = [];

    // Agregar chats a la lista con su timestamp
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != userId,
        orElse: () => '',
      );

      if (otherUserId.isNotEmpty) {
        final timestamp = chatData['lastMessageTime'] as Timestamp? ??
            chatData['createdAt'] as Timestamp?;
        sortableItems.add(_SortableItem(
          item: ChatItem(userId: otherUserId, userData: {}, chatDoc: chatDoc),
          timestamp: timestamp,
        ));
      }
    }

    // Agregar grupos a la lista con su timestamp
    for (final groupDoc in groups) {
      final groupData = groupDoc.data() as Map<String, dynamic>;
      final timestamp = groupData['lastActivity'] as Timestamp? ??
          groupData['createdAt'] as Timestamp?;
      sortableItems.add(_SortableItem(
        item: GroupItem(groupId: groupDoc.id, groupData: groupData),
        timestamp: timestamp,
      ));
    }

    // Ordenar todos los items juntos por timestamp (más reciente primero)
    sortableItems.sort((a, b) {
      if (a.timestamp == null && b.timestamp == null) return 0;
      if (a.timestamp == null) return 1;
      if (b.timestamp == null) return -1;
      return b.timestamp!.compareTo(a.timestamp!);
    });

    // Extraer solo los items ordenados
    return sortableItems.map((s) => s.item).toList();
  }

  /// Obtener ID del usuario actual
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Obtener datos de usuario por ID
  @override
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    try {
      return await _userProfileService.getUserProfile(userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de usuario $userId: $e', tag: 'ParentChats');
      return null;
    }
  }

  /// Stream de datos de usuario
  @override
  Stream<DocumentSnapshot> getUserDataStream(String userId) {
    return _userProfileService.getUserDataStream(userId);
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
    // ✅ CODING_RULES: Usando métodos del BaseChatsController
    if (isGroup) {
      return getGroupLastMessageStream(chatId);
    } else {
      return getChatLastMessageStream(chatId);
    }
  }

  /// Obtener datos de chat para navegación
  Future<Map<String, dynamic>?> getChatDataForNavigation(String chatId) async {
    try {
      // ✅ CODING_RULES: Usando métodos del BaseChatsController
      final snapshot = await getChatDataStream(chatId).first;
      if (snapshot.exists) {
        return snapshot.data() as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de chat $chatId: $e', tag: 'ParentChats');
      return null;
    }
  }
}

/// Helper class para ordenar chats y grupos juntos por timestamp
class _SortableItem {
  final ChatListItemType item;
  final Timestamp? timestamp;

  _SortableItem({required this.item, this.timestamp});
}
