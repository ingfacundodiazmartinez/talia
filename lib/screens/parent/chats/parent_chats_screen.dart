import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/block_service.dart';
import '../../../services/message_status_helper.dart';
import '../../../models/chat_message.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/create_group_widget.dart';
import '../../../utils/chat_utils.dart';
import '../../../models/chat_list_item_type.dart';
import '../../../controllers/parent_chats_controller.dart';
import '../../../theme_service.dart';
import 'widgets/chat_list_item.dart';
import 'widgets/group_chat_list_item.dart';
import 'widgets/parent_chat_header.dart';
import 'widgets/chat_search_bar.dart';

/// Pantalla de chats para padres
///
/// Responsabilidades:
/// - Mostrar lista de chats (hijos y otros contactos)
/// - Mostrar grupos
/// - Permitir búsqueda de chats
/// - Proveer acceso a creación de grupos
///
/// NO contiene lógica de negocio (manejada por ParentChatsController)
class ParentChatsScreen extends StatefulWidget {
  const ParentChatsScreen({super.key});

  @override
  State<ParentChatsScreen> createState() => _ParentChatsScreenState();
}

class _ParentChatsScreenState extends State<ParentChatsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ContactAliasService _aliasService = ContactAliasService();
  final BlockService _blockService = BlockService();
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');
  late ParentChatsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ParentChatsController(userId: _auth.currentUser!.uid);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchQuery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.customColors.gradientStart,
              context.customColors.gradientEnd,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chats 💬',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Conversaciones con tus contactos',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.group_add,
                        color: Colors.white,
                        size: 26,
                      ),
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => CreateGroupWidget(
                            onGroupCreated: () {
                              setState(() {});
                            },
                          ),
                        );
                      },
                      padding: EdgeInsets.all(8),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Historias (estáticas, no se rebuildeean con búsqueda)
                      Column(
                        children: [
                          StoriesHeader(),
                          StoriesSection(),
                          SizedBox(height: 16),
                        ],
                      ),
                      // Buscador (estático, no se rebuildea)
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: ChatSearchBar(
                          controller: _searchController,
                          onChanged: (value) => _searchQuery.value = value,
                        ),
                      ),
                      // Lista de chats (filtrable)
                      Expanded(
                        child: StreamBuilder<List<String>>(
                          stream: _blockService.getBlockedContactsStream(),
                          builder: (context, blockedSnapshot) {
                            final blockedContacts = blockedSnapshot.data ?? [];

                            return StreamBuilder<QuerySnapshot>(
                              stream: _controller.getChatsStream(),
                              builder: (context, snapshot) {
                                // En caso de error, continuar con lista vacía de chats pero buscar grupos
                                if (snapshot.hasError) {
                                  debugPrint(
                                    '⚠️ Error en stream de chats (continuando con grupos): ${snapshot.error}',
                                  );
                                }

                                // Solo mostrar spinner si está esperando Y no hay datos
                                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                                  return Center(child: CircularProgressIndicator());
                                }

                                return StreamBuilder<QuerySnapshot>(
                                  stream: _controller.getParentChildLinksStream(),
                                  builder: (context, linksSnapshot) {
                                    // Solo mostrar spinner si está esperando Y no hay datos
                                    if (linksSnapshot.connectionState == ConnectionState.waiting && !linksSnapshot.hasData) {
                                      return Center(child: CircularProgressIndicator());
                                    }

                                    final childrenLinks = linksSnapshot.data?.docs ?? [];
                                    final childrenIds = _controller.extractChildrenIds(childrenLinks);

                                    // Filtrar solo chats eliminados (NO filtrar bloqueados)
                                    final chatDocs = snapshot.data != null
                                        ? _controller.filterDeletedChats(snapshot.data!)
                                        : <QueryDocumentSnapshot>[];

                                    // Separar chats en: con hijos y con otros
                                    final separated = _controller.separateChats(
                                      chatDocs: chatDocs,
                                      childrenIds: childrenIds,
                                    );
                                    final otherChats = separated['otherChats']!;

                                    // Obtener grupos del parent
                                    return StreamBuilder<QuerySnapshot>(
                                      stream: _controller.getGroupsStream(),
                                      builder: (context, groupsSnapshot) {
                                        final groups = groupsSnapshot.data?.docs ?? [];

                                        // Build the list items using controller
                                        final listItems = _controller.buildListItems(
                                          childrenLinks: childrenLinks,
                                          childrenIds: childrenIds,
                                          chatDocs: chatDocs,
                                          otherChats: otherChats,
                                          groups: groups,
                                        );

                                        return ValueListenableBuilder<String>(
                                          valueListenable: _searchQuery,
                                          builder: (context, query, _) {
                                            return ListView.builder(
                                              padding: EdgeInsets.all(16),
                                              itemCount: listItems.length,
                                              itemBuilder: (context, index) {
                                                final item = listItems[index];
                                                return _buildItemWidget(
                                                  item,
                                                  childrenLinks,
                                                  chatDocs,
                                                  childrenIds,
                                                  query.toLowerCase(),
                                                );
                                              },
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Construye el widget correspondiente a cada tipo de item
  Widget _buildItemWidget(
    ChatListItemType item,
    List<QueryDocumentSnapshot> childrenLinks,
    List<QueryDocumentSnapshot> chatDocs,
    Set<String> childrenIds,
    String searchQuery,
  ) {
    switch (item) {
      case HeaderItem(:final title, :final isChildrenHeader):
        if (isChildrenHeader) {
          return ParentChatHeader();
        }
        return Padding(
          padding: EdgeInsets.only(bottom: 12, left: 4, top: 16),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        );

      case ChatItem(:final userId, :final chatDoc):
        // Check if this is a child chat to use proper data stream
        final isChildChat = childrenLinks.any(
          (doc) => doc['childId'] == userId,
        );

        if (isChildChat) {
          // For child chats, we need to get user data via stream
          return StreamBuilder<DocumentSnapshot>(
            stream: _controller.getUserDataStream(userId),
            builder: (context, childSnapshot) {
              if (!childSnapshot.hasData) {
                return SizedBox.shrink();
              }

              final childData =
                  childSnapshot.data!.data() as Map<String, dynamic>?;
              if (childData == null) return SizedBox.shrink();

              final childName = childData['name'] ?? 'Usuario';

              // Filter by search
              if (searchQuery.isNotEmpty &&
                  !childName.toLowerCase().contains(searchQuery)) {
                return SizedBox.shrink();
              }

              return _buildChatItem(
                childId: userId,
                childData: childData,
                chatDoc: chatDoc,
              );
            },
          );
        } else {
          // For other chats and contacts
          return StreamBuilder<DocumentSnapshot>(
            stream: _controller.getUserDataStream(userId),
            builder: (context, userSnapshot) {
              if (!userSnapshot.hasData) return SizedBox.shrink();

              final fetchedUserData =
                  userSnapshot.data!.data() as Map<String, dynamic>?;
              if (fetchedUserData == null) return SizedBox.shrink();

              final userName = fetchedUserData['name'] ?? 'Usuario';

              return StreamBuilder<String>(
                stream: _aliasService.watchDisplayName(userId, userName),
                initialData: userName,
                builder: (context, aliasSnapshot) {
                  final displayName = aliasSnapshot.data ?? userName;

                  // Filter by search (search in both real name and alias)
                  if (searchQuery.isNotEmpty) {
                    final matchesRealName = userName.toLowerCase().contains(
                      searchQuery,
                    );
                    final matchesAlias = displayName.toLowerCase().contains(
                      searchQuery,
                    );
                    if (!matchesRealName && !matchesAlias) {
                      return SizedBox.shrink();
                    }
                  }

                  return _buildChatItem(
                    childId: userId,
                    childData: fetchedUserData,
                    chatDoc: chatDoc,
                  );
                },
              );
            },
          );
        }

      case GroupItem(:final groupId, :final groupData):
        final groupName = groupData['name'] ?? 'Grupo';
        final parentId = _auth.currentUser?.uid ?? '';

        // Filter by search
        if (searchQuery.isNotEmpty &&
            !groupName.toLowerCase().contains(searchQuery)) {
          return SizedBox.shrink();
        }

        // Leer contador de mensajes no leídos para este usuario
        final unreadCount = groupData['unreadCount_$parentId'] ?? 0;

        if (unreadCount > 0) {
          print('💬 [ChatList] Grupo $groupId tiene $unreadCount mensajes no leídos');
        }

        return GroupChatListItem(
          groupId: groupId,
          groupName: groupName,
          memberCount: (groupData['members'] as List?)?.length ?? 0,
          lastMessage: groupData['lastMessage'] ?? 'Toca para abrir',
          messageCount: groupData['messageCount'] ?? 0,
          groupImageUrl: groupData['imageUrl'],
          unreadCount: unreadCount,
          onLeaveGroup: () =>
              _confirmLeaveGroup(groupId, groupName),
        );

      default:
        return SizedBox.shrink();
    }
  }

  Widget _buildChatItem({
    required String childId,
    required Map<String, dynamic> childData,
    QueryDocumentSnapshot? chatDoc,
  }) {
    final realName = childData['name'] ?? 'Hijo/a';
    final isOnline = childData['isOnline'] ?? false;
    final photoURL = childData['photoURL'];
    final parentId = _auth.currentUser?.uid ?? '';

    return StreamBuilder<String>(
      stream: _aliasService.watchDisplayName(childId, realName),
      initialData: realName,
      builder: (context, aliasSnapshot) {
        final displayName = aliasSnapshot.data ?? realName;

        // ✅ Verificar si el contacto está bloqueado
        return StreamBuilder<bool>(
          stream: _blockService.isBlockedStream(childId),
          initialData: false,
          builder: (context, blockedSnapshot) {
            final isBlocked = blockedSnapshot.data ?? false;

            if (chatDoc != null) {
              // Chat con mensajes existentes
              final chatData = chatDoc.data() as Map<String, dynamic>;
              // Leer contador de mensajes no leídos para este usuario
              final unreadCount = chatData['unreadCount_$parentId'] ?? 0;

              if (unreadCount > 0) {
                print('💬 [ChatList] Chat ${chatDoc.id} tiene $unreadCount mensajes no leídos');
              }

              // Obtener el último mensaje para mostrar su estado
              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('chats')
                    .doc(chatDoc.id)
                    .collection('messages')
                    .orderBy('timestamp', descending: true)
                    .limit(1)
                    .snapshots(),
                builder: (context, messageSnapshot) {
                  String? lastMessageSenderId;
                  MessageStatus? lastMessageStatus;
                  ModerationStatus? lastMessageModerationStatus;

                  if (messageSnapshot.hasData && messageSnapshot.data!.docs.isNotEmpty) {
                    final lastMessageDoc = messageSnapshot.data!.docs.first;
                    final lastMessageData = lastMessageDoc.data() as Map<String, dynamic>;

                    final senderId = lastMessageData['senderId'] as String? ?? '';
                    lastMessageSenderId = senderId;

                    // Calcular el estado del mensaje
                    lastMessageStatus = MessageStatusHelper.calculateStatus(
                      data: lastMessageData,
                      senderId: senderId,
                      hasServerTimestamp: lastMessageData['timestamp'] != null,
                    );

                    // Obtener estado de moderación
                    final modStatusString = lastMessageData['moderationStatus'] as String?;
                    if (modStatusString != null) {
                      switch (modStatusString) {
                        case 'approved':
                          lastMessageModerationStatus = ModerationStatus.approved;
                          break;
                        case 'blocked':
                          lastMessageModerationStatus = ModerationStatus.blocked;
                          break;
                        case 'pending':
                          lastMessageModerationStatus = ModerationStatus.pending;
                          break;
                      }
                    }
                  }

                  return ChatListItem(
                    chatId: chatDoc.id,
                    userId: childId,
                    name: displayName,
                    lastMessage: isBlocked ? '🔒 Contacto bloqueado' : (chatData['lastMessage'] ?? ''),
                    time: ChatUtils.formatChatTime(chatData['lastMessageTime']),
                    unreadCount: isBlocked ? 0 : unreadCount,
                    isOnline: isOnline,
                    photoURL: photoURL,
                    isEmpty: false,
                    isBlocked: isBlocked,
                    lastMessageSenderId: lastMessageSenderId,
                    lastMessageStatus: lastMessageStatus,
                    lastMessageModerationStatus: lastMessageModerationStatus,
                  );
                },
              );
            } else {
              // Chat vacío (placeholder)
              return ChatListItem(
                chatId: ChatUtils.getChatId(parentId, childId),
                userId: childId,
                name: displayName,
                lastMessage: isBlocked ? '🔒 Contacto bloqueado' : 'Toca para iniciar conversación',
                time: '',
                unreadCount: 0,
                isOnline: isOnline,
                photoURL: photoURL,
                isEmpty: true,
                isBlocked: isBlocked,
              );
            }
          },
        );
      },
    );
  }

  Future<void> _confirmLeaveGroup(String groupId, String groupName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Salir del grupo?'),
        content: Text(
          '¿Estás seguro de que quieres salir de "$groupName"?\n\n'
          'Los demás miembros podrán seguir usando el grupo. Si eres el último miembro, el grupo será eliminado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Salir'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _leaveGroup(groupId, groupName);
    }
  }

  Future<void> _leaveGroup(String groupId, String groupName) async {
    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(child: CircularProgressIndicator()),
    );

    try {
      await _controller.leaveGroup(groupId);

      if (!mounted) return;
      Navigator.pop(context); // Cerrar loading

      // Refrescar la UI
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // Cerrar loading

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al salir del grupo: $e'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }
}
