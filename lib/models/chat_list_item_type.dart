import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo abstracto para items en la lista de chats
abstract class ChatListItemType {
  const ChatListItemType();
}

/// Header de sección
class HeaderItem extends ChatListItemType {
  final String title;
  final bool isChildrenHeader;

  const HeaderItem({
    required this.title,
    this.isChildrenHeader = false,
  });
}

/// Sección de historias
class StoriesItem extends ChatListItemType {
  const StoriesItem();
}

/// Barra de búsqueda
class SearchBarItem extends ChatListItemType {
  const SearchBarItem();
}

/// Item de chat individual
class ChatItem extends ChatListItemType {
  final String userId;
  final Map<String, dynamic> userData;
  final QueryDocumentSnapshot? chatDoc;

  const ChatItem({
    required this.userId,
    required this.userData,
    this.chatDoc,
  });
}

/// Item de grupo
class GroupItem extends ChatListItemType {
  final String groupId;
  final Map<String, dynamic> groupData;

  const GroupItem({
    required this.groupId,
    required this.groupData,
  });
}
