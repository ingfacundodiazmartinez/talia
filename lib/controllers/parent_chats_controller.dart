import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart';
import 'base_chats_controller.dart';
import '../models/chat_list_item_type.dart';
import '../services/search_service.dart';
import '../services/user_profile_cache_service.dart';
import '../services/user_cache_service.dart';
import '../services/share_extension_cache_service.dart';
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

  /// Cachear lista de chats para iOS Share Extension
  /// Se llama cuando la lista de chats se actualiza
  Future<void> cacheChatsForShareExtension({
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    try {
      final List<CachedChatData> cachedChats = [];
      final userCacheService = UserCacheService();

      // Cachear chats individuales
      for (final chatDoc in chatDocs) {
        final chatData = chatDoc.data() as Map<String, dynamic>;
        final participants = List<String>.from(chatData['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != userId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) continue;

        // Obtener nombre del usuario (usa cache o Firestore)
        final userData = await userCacheService.getUserData(otherUserId);
        final displayName = userCacheService.getDisplayName(
          otherUserId,
          fallback: 'Usuario',
        );

        final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;

        cachedChats.add(CachedChatData(
          id: chatDoc.id,
          name: displayName,
          photoURL: userData?['photoURL'] as String?,
          isGroup: false,
          lastMessage: chatData['lastMessage'] as String?,
          lastMessageTime: lastMessageTime?.millisecondsSinceEpoch.toDouble(),
        ));
      }

      // Cachear grupos
      for (final groupDoc in groups) {
        final groupData = groupDoc.data() as Map<String, dynamic>;
        final lastMessageTime = groupData['lastActivity'] as Timestamp? ??
            groupData['lastMessageTime'] as Timestamp?;

        cachedChats.add(CachedChatData(
          id: groupDoc.id,
          name: groupData['name'] as String? ?? 'Grupo',
          photoURL: groupData['avatar'] as String?,
          isGroup: true,
          lastMessage: groupData['lastMessage'] as String?,
          lastMessageTime: lastMessageTime?.millisecondsSinceEpoch.toDouble(),
        ));
      }

      // Ordenar por última actividad (más reciente primero)
      cachedChats.sort((a, b) {
        final aTime = a.lastMessageTime ?? 0;
        final bTime = b.lastMessageTime ?? 0;
        return bTime.compareTo(aTime);
      });

      // Enviar al servicio de cache
      await ShareExtensionCacheService().cacheChats(cachedChats);
    } catch (e) {
      ReleaseLogger.error(
        'Error caching chats for Share Extension: $e',
        tag: 'ParentChats',
      );
    }
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
  /// Delega la búsqueda al SearchService
  Future<SearchResults> performMessageSearch({
    required String query,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    return await _searchService.performMessageSearch(
      query: query,
      currentUserId: currentUserId,
      chatDocs: chatDocs,
      groups: groups,
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
        final data = snapshot.data() as Map<String, dynamic>?;
        if (data != null) {
          // ✅ FIX: Agregar contactId (el otro participante del chat)
          final participants = data['participants'] as List<dynamic>?;
          if (participants != null) {
            final contactId = participants.firstWhere(
              (id) => id != userId,
              orElse: () => null,
            );
            if (contactId != null) {
              return {...data, 'contactId': contactId};
            }
          }
        }
        return data;
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
