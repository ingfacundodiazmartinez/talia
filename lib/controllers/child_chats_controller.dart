import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'base_chats_controller.dart';
import '../models/chat_list_item_type.dart';
import '../services/contact_service.dart';
import '../services/user_role_service.dart';
import '../services/contact_alias_service.dart';
import '../services/search_service.dart';
import '../services/user_profile_cache_service.dart';
import '../utils/release_logger.dart';

/// Controller para la pantalla de chats de un niño
///
/// Responsabilidades:
/// - Obtener padre vinculado
/// - Verificar permisos de contactos
/// - Proveer acceso a alias
class ChildChatsController extends BaseChatsController with ChangeNotifier {
  final ContactService _contactService;
  final UserRoleService _userRoleService;
  final ContactAliasService _aliasService;
  final SearchService _searchService;

  ChildChatsController({
    required super.userId,
    super.firestore,
    super.chatService,
    super.groupChatService,
    ContactService? contactService,
    UserRoleService? userRoleService,
    ContactAliasService? aliasService,
    SearchService? searchService,
  })  : _contactService = contactService ?? ContactService(),
        _userRoleService = userRoleService ?? UserRoleService(),
        _aliasService = aliasService ?? ContactAliasService(),
        _searchService = searchService ?? SearchService();

  /// Stream de datos del usuario (usa singleton directamente para evitar null issues)
  @override
  Stream<DocumentSnapshot> getUserDataStream(String targetUserId) {
    return UserProfileCacheService().getUserDataStream(targetUserId);
  }

  /// Obtener ID del padre vinculado
  Future<String?> getLinkedParentId() async {
    try {
      final linkedParents = await _userRoleService.getLinkedParents(userId);
      return linkedParents.isNotEmpty ? linkedParents.first : null;
    } catch (e) {
      debugPrint('❌ Error obteniendo padre vinculado: $e');
      return null;
    }
  }

  /// Watch para el nombre display (con alias)
  Stream<String> watchDisplayName(String targetUserId, String realName) {
    return _aliasService.watchDisplayName(targetUserId, realName);
  }

  /// Watch para verificar si un chat está bloqueado
  Stream<bool> watchChatBlocked(String chatId) {
    return _contactService.watchChatBlocked(chatId);
  }

  /// Verificar si un contacto está revocado
  Future<bool> isContactRevoked(String contactId) async {
    return await _contactService.isContactRevoked(userId, contactId);
  }

  /// Inicializar controller
  Future<void> initialize() async {
    // Placeholder para inicialización futura si es necesaria
    notifyListeners();
  }

  /// Construye la lista de items para mostrar en la UI
  /// Combina chats y grupos ordenados por última actividad (igual que parent)
  /// Incluye grupos pendientes de aprobación con isPending=true
  List<ChatListItemType> buildListItems({
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
    List<QueryDocumentSnapshot> pendingGroups = const [],
  }) {
    // Crear lista combinada de items con timestamps para ordenar
    final List<_SortableItem> sortableItems = [];

    // Set de IDs de grupos activos para evitar duplicados
    final activeGroupIds = groups.map((g) => g.id).toSet();

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

    // Agregar grupos activos a la lista con su timestamp
    for (final groupDoc in groups) {
      final groupData = groupDoc.data() as Map<String, dynamic>;
      final timestamp = groupData['lastActivity'] as Timestamp? ??
          groupData['createdAt'] as Timestamp?;
      sortableItems.add(_SortableItem(
        item: GroupItem(groupId: groupDoc.id, groupData: groupData, isPending: false),
        timestamp: timestamp,
      ));
    }

    // Agregar grupos pendientes (si no están ya en activos)
    for (final groupDoc in pendingGroups) {
      if (!activeGroupIds.contains(groupDoc.id)) {
        final groupData = groupDoc.data() as Map<String, dynamic>;
        final timestamp = groupData['createdAt'] as Timestamp?;
        sortableItems.add(_SortableItem(
          item: GroupItem(groupId: groupDoc.id, groupData: groupData, isPending: true),
          timestamp: timestamp,
        ));
      }
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

  /// Buscar en mensajes de todos los chats
  /// Delega la búsqueda al SearchService
  Future<SearchResults> performMessageSearch({
    required String query,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    return await _searchService.performMessageSearch(
      query: query,
      currentUserId: userId,
      chatDocs: chatDocs,
      groups: groups,
    );
  }

  /// Obtener datos de chat para navegación
  Future<Map<String, dynamic>?> getChatDataForNavigation(String chatId) async {
    try {
      final snapshot = await getChatDataStream(chatId).first;
      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>?;
        if (data != null) {
          // Agregar contactId (el otro participante del chat)
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
      ReleaseLogger.error('Error obteniendo datos de chat $chatId: $e', tag: 'ChildChats');
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
