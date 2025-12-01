import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/block_service.dart';
import '../../../services/message_status_helper.dart';
import '../../../services/local_unread_count_service.dart';
import '../../../services/search_service.dart';
import '../../../models/chat_message.dart';
import '../../../widgets/stories_section.dart';
import '../../create_group_screen.dart';
import '../../../utils/chat_utils.dart';
import '../../../models/chat_list_item_type.dart';
import '../../../controllers/parent_chats_controller.dart';
import '../../../theme_service.dart';
import '../../chat_detail_screen.dart';
import '../../group_chat_screen.dart';
import 'widgets/chat_list_item.dart';
import 'widgets/group_chat_list_item.dart';
import 'widgets/parent_chat_header.dart';
import 'widgets/chat_search_bar.dart';
import 'widgets/search_result_widgets.dart';
import 'parent_archived_chats_screen.dart';

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

class _ParentChatsScreenState extends State<ParentChatsScreen>
    with AutomaticKeepAliveClientMixin {
  final ContactAliasService _aliasService = ContactAliasService();
  final BlockService _blockService = BlockService();
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');
  late ParentChatsController _controller;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Create temporary controller to get current user ID
    final tempController = ParentChatsController(userId: '');
    _controller = ParentChatsController(userId: tempController.currentUserId);

    // ✅ Escuchar cambios en contadores de no leídos para actualizar badges
    LocalUnreadCountService().addListener(_onUnreadCountsChanged);
  }

  void _onUnreadCountsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    LocalUnreadCountService().removeListener(_onUnreadCountsChanged);
    _searchController.dispose();
    _searchQuery.dispose();
    super.dispose();
  }

  /// Busca en mensajes de todos los chats cuando hay un query activo
  Future<SearchResults> _performMessageSearch({
    required String query,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    return await _controller.performMessageSearch(
      query: query,
      chatDocs: chatDocs,
      groups: groups,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Necesario para AutomaticKeepAliveClientMixin
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
                      icon: Icon(Icons.archive, color: Colors.white, size: 26),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => ParentArchivedChatsScreen(),
                          ),
                        );
                      },
                      padding: EdgeInsets.all(8),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.group_add,
                        color: Colors.white,
                        size: 26,
                      ),
                      onPressed: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => CreateGroupScreen(),
                          ),
                        );

                        // Refrescar si se creó el grupo
                        if (result == true && mounted) {
                          // Forzar refresh de grupos desde servidor para actualizar cache
                          await _controller.refreshGroupsFromServer();
                          if (mounted) setState(() {});
                        }
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
                      // Lista de chats (filtrable) con pull-to-refresh
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: () async {
                            await _controller.forceReconnect();
                            // Pequeño delay para dar feedback visual
                            await Future.delayed(Duration(milliseconds: 500));
                          },
                          child: StreamBuilder<QuerySnapshot>(
                            stream: _controller.getChatsStream(),
                            builder: (context, snapshot) {
                              // SIEMPRE usar datos cacheados si están disponibles
                              // Esto evita pantallas en blanco y parpadeos
                              if (snapshot.hasError) {
                                debugPrint(
                                  '⚠️ Error en stream de chats: ${snapshot.error}',
                                );
                                // Continuar con lista vacía pero no bloquear la UI
                              }

                              // Solo mostrar spinner en la primera carga SIN cache
                              if (snapshot.connectionState ==
                                      ConnectionState.waiting &&
                                  !snapshot.hasData) {
                                return Center(
                                  child: CircularProgressIndicator(),
                                );
                              }

                              // Filtrar chats eliminados y archivados (NO filtrar bloqueados)
                              var chatDocs = snapshot.data != null
                                  ? _controller.filterDeletedChats(
                                      snapshot.data!,
                                    )
                                  : <QueryDocumentSnapshot>[];

                              // Filtrar chats archivados
                              chatDocs = _controller.filterArchivedChats(
                                chatDocs,
                              );

                              // Obtener grupos del parent
                              return StreamBuilder<QuerySnapshot>(
                                    stream: _controller.getGroupsStream(),
                                    builder: (context, groupsSnapshot) {
                                      // Filtrar grupos archivados
                                      final allGroups =
                                          groupsSnapshot.data?.docs ?? [];
                                      final groups = _controller
                                          .filterArchivedGroups(allGroups);

                                      // Build the list items using controller
                                      final listItems = _controller
                                          .buildListItems(
                                            chatDocs: chatDocs,
                                            groups: groups,
                                          );

                                      return ValueListenableBuilder<String>(
                                        valueListenable: _searchQuery,
                                        builder: (context, query, _) {
                                          // Si no hay query, mostrar lista normal
                                          if (query.trim().isEmpty) {
                                            return ListView.builder(
                                              padding: EdgeInsets.all(16),
                                              itemCount: listItems.length,
                                              itemBuilder: (context, index) {
                                                final item = listItems[index];
                                                return _buildItemWidget(
                                                  item,
                                                  chatDocs,
                                                  query.toLowerCase(),
                                                );
                                              },
                                            );
                                          }

                                          // Si hay query, mostrar resultados de búsqueda
                                          return FutureBuilder<SearchResults>(
                                            future: _performMessageSearch(
                                              query: query,
                                              chatDocs: chatDocs,
                                              groups: groups,
                                            ),
                                            builder: (context, snapshot) {
                                              // ✅ CORREGIDO: Solo mostrar spinner en primera carga SIN cache
                                              // Esto evita el spinner infinito después de videollamadas
                                              if (snapshot.connectionState ==
                                                      ConnectionState.waiting &&
                                                  !snapshot.hasData) {
                                                return Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                );
                                              }

                                              if (snapshot.hasError) {
                                                return Center(
                                                  child: Text(
                                                    'Error en la búsqueda: ${snapshot.error}',
                                                  ),
                                                );
                                              }

                                              final results = snapshot.data;
                                              if (results == null ||
                                                  results.isEmpty) {
                                                return SearchEmptyState(
                                                  query: query,
                                                );
                                              }

                                              return ListView.builder(
                                                padding: EdgeInsets.all(16),
                                                itemCount:
                                                    results.chatResults.length +
                                                    results
                                                        .messageResults
                                                        .length +
                                                    2, // +2 para las cabeceras
                                                itemBuilder: (context, index) {
                                                  // Cabecera de chats
                                                  if (index == 0 &&
                                                      results
                                                          .chatResults
                                                          .isNotEmpty) {
                                                    return SearchResultsHeader(
                                                      title: 'CHATS',
                                                      count: results
                                                          .chatResults
                                                          .length,
                                                    );
                                                  }

                                                  // Resultados de chats
                                                  if (index > 0 &&
                                                      index <=
                                                          results
                                                              .chatResults
                                                              .length) {
                                                    final chatResult = results
                                                        .chatResults[index - 1];
                                                    return ChatSearchResultCard(
                                                      result: chatResult,
                                                      onTap: () =>
                                                          _navigateToChat(
                                                            chatResult,
                                                          ),
                                                    );
                                                  }

                                                  // Cabecera de mensajes
                                                  if (index ==
                                                          results
                                                                  .chatResults
                                                                  .length +
                                                              1 &&
                                                      results
                                                          .messageResults
                                                          .isNotEmpty) {
                                                    return SearchResultsHeader(
                                                      title: 'MENSAJES',
                                                      count: results
                                                          .messageResults
                                                          .length,
                                                    );
                                                  }

                                                  // Resultados de mensajes
                                                  final messageIndex =
                                                      index -
                                                      results
                                                          .chatResults
                                                          .length -
                                                      2;
                                                  if (messageIndex >= 0 &&
                                                      messageIndex <
                                                          results
                                                              .messageResults
                                                              .length) {
                                                    final messageResult = results
                                                        .messageResults[messageIndex];
                                                    return MessageSearchResultCard(
                                                      result: messageResult,
                                                      onTap: () =>
                                                          _navigateToMessage(
                                                            messageResult,
                                                          ),
                                                    );
                                                  }

                                                  return SizedBox.shrink();
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
    List<QueryDocumentSnapshot> chatDocs,
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
        // Todos los chats se manejan igual (sin agrupación)
        return StreamBuilder<DocumentSnapshot>(
          stream: _controller.getUserDataStream(userId),
          builder: (context, userSnapshot) {
            if (!userSnapshot.hasData || userSnapshot.data == null) return SizedBox.shrink();

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

      case GroupItem(:final groupId, :final groupData):
        final groupName = groupData['name'] ?? 'Grupo';
        final parentId = _controller.currentUserId;

        // Filter by search
        if (searchQuery.isNotEmpty &&
            !groupName.toLowerCase().contains(searchQuery)) {
          return SizedBox.shrink();
        }

        // ✅ Leer contador de mensajes no leídos desde cache local
        final unreadCount = LocalUnreadCountService().getUnreadCount(groupId);

        // Obtener el último mensaje para mostrar su estado
        return StreamBuilder<QuerySnapshot>(
          stream: _controller.getLastMessageStream(groupId, isGroup: true),
          builder: (context, messageSnapshot) {
            String? lastMessageSenderId;
            MessageStatus? lastMessageStatus;
            ModerationStatus? lastMessageModerationStatus;

            if (messageSnapshot.hasData &&
                messageSnapshot.data != null &&
                messageSnapshot.data!.docs.isNotEmpty) {
              final lastMessageDoc = messageSnapshot.data!.docs.first;
              final lastMessageData =
                  lastMessageDoc.data() as Map<String, dynamic>;

              final senderId = lastMessageData['senderId'] as String? ?? '';
              lastMessageSenderId = senderId;

              // Calcular el estado del mensaje
              lastMessageStatus = MessageStatusHelper.calculateStatus(
                data: lastMessageData,
                senderId: senderId,
                hasServerTimestamp: lastMessageData['timestamp'] != null,
              );

              // Obtener estado de moderación
              final modStatusString =
                  lastMessageData['moderationStatus'] as String?;
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

            return GroupChatListItem(
              groupId: groupId,
              groupName: groupName,
              memberCount: (groupData['members'] as List?)?.length ?? 0,
              lastMessage: groupData['lastMessage'] ?? 'Toca para abrir',
              messageCount: groupData['messageCount'] ?? 0,
              groupImageUrl:
                  groupData['avatar'], // Campo correcto es 'avatar' no 'imageUrl'
              unreadCount: unreadCount,
              onLeaveGroup: () => _confirmLeaveGroup(groupId, groupName),
              lastMessageSenderId: lastMessageSenderId,
              lastMessageStatus: lastMessageStatus,
              lastMessageModerationStatus: lastMessageModerationStatus,
            );
          },
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
    final photoURL = childData['photoURL'];
    final parentId = _controller.currentUserId;

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
              // ✅ Leer contador de mensajes no leídos desde cache local
              final unreadCount = LocalUnreadCountService().getUnreadCount(chatDoc.id);

              // Obtener el último mensaje para mostrar su estado
              return StreamBuilder<QuerySnapshot>(
                stream: _controller.getLastMessageStream(chatDoc.id),
                builder: (context, messageSnapshot) {
                  String? lastMessageSenderId;
                  MessageStatus? lastMessageStatus;
                  ModerationStatus? lastMessageModerationStatus;

                  if (messageSnapshot.hasData &&
                      messageSnapshot.data != null &&
                      messageSnapshot.data!.docs.isNotEmpty) {
                    final lastMessageDoc = messageSnapshot.data!.docs.first;
                    final lastMessageData =
                        lastMessageDoc.data() as Map<String, dynamic>;

                    final senderId =
                        lastMessageData['senderId'] as String? ?? '';
                    lastMessageSenderId = senderId;

                    // Calcular el estado del mensaje
                    lastMessageStatus = MessageStatusHelper.calculateStatus(
                      data: lastMessageData,
                      senderId: senderId,
                      hasServerTimestamp: lastMessageData['timestamp'] != null,
                    );

                    // Obtener estado de moderación
                    final modStatusString =
                        lastMessageData['moderationStatus'] as String?;
                    if (modStatusString != null) {
                      switch (modStatusString) {
                        case 'approved':
                          lastMessageModerationStatus =
                              ModerationStatus.approved;
                          break;
                        case 'blocked':
                          lastMessageModerationStatus =
                              ModerationStatus.blocked;
                          break;
                        case 'pending':
                          lastMessageModerationStatus =
                              ModerationStatus.pending;
                          break;
                      }
                    }
                  }

                  // Verificar si el chat fue limpiado y no hay mensajes nuevos
                  final clearedAt =
                      chatData['clearedAt_$parentId'] as Timestamp?;
                  final lastMessageTime =
                      chatData['lastMessageTime'] as Timestamp?;
                  final isChatCleared =
                      clearedAt != null &&
                      (lastMessageTime == null ||
                          clearedAt.compareTo(lastMessageTime) >= 0);

                  return ChatListItem(
                    chatId: chatDoc.id,
                    userId: childId,
                    name: displayName,
                    lastMessage: isBlocked
                        ? '🔒 Contacto bloqueado'
                        : (isChatCleared
                              ? 'Inicia una conversación...'
                              : (chatData['lastMessage'] ?? '')),
                    time: isChatCleared
                        ? ''
                        : ChatUtils.formatChatTime(chatData['lastMessageTime']),
                    unreadCount: isBlocked ? 0 : unreadCount,
                    photoURL: photoURL,
                    isEmpty: isChatCleared,
                    isBlocked: isBlocked,
                    lastMessageSenderId: isChatCleared
                        ? null
                        : lastMessageSenderId,
                    lastMessageStatus: isChatCleared ? null : lastMessageStatus,
                    lastMessageModerationStatus: isChatCleared
                        ? null
                        : lastMessageModerationStatus,
                  );
                },
              );
            } else {
              // Chat vacío (placeholder)
              return ChatListItem(
                chatId: ChatUtils.getChatId(parentId, childId),
                userId: childId,
                name: displayName,
                lastMessage: isBlocked
                    ? '🔒 Contacto bloqueado'
                    : 'Toca para iniciar conversación',
                time: '',
                unreadCount: 0,
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
      await _leaveGroup(groupId, groupName);
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

      // Mostrar mensaje de éxito
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Has salido de "$groupName"'),
          duration: Duration(seconds: 2),
        ),
      );

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

  /// Navega al chat desde un resultado de búsqueda
  void _navigateToChat(ChatSearchResult result) {
    // Limpiar el buscador
    _searchController.clear();
    _searchQuery.value = '';

    // Navegar según el tipo de chat
    if (result.chatType == ChatType.group) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => GroupChatScreen(
            groupId: result.chatId,
            groupName: result.chatName,
          ),
        ),
      );
    } else {
      // Para chats directos (hijos y otros contactos)
      // Necesitamos obtener el contactId del chatId
      _navigateToDirectChat(result.chatId, result.chatName);
    }
  }

  /// Navega al chat y al mensaje específico desde un resultado de búsqueda
  void _navigateToMessage(MessageSearchResult result) {
    // Limpiar el buscador
    _searchController.clear();
    _searchQuery.value = '';

    // Navegar según el tipo de chat, pasando el messageId para hacer scroll
    if (result.chatType == ChatType.group) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => GroupChatScreen(
            groupId: result.chatId,
            groupName: result.chatName,
            scrollToMessageId: result.message.id,
          ),
        ),
      );
    } else {
      // Para chats directos (hijos y otros contactos)
      _navigateToDirectChat(result.chatId, result.chatName, result.message.id);
    }
  }

  /// Helper para navegar a chat directo obteniendo el contactId
  Future<void> _navigateToDirectChat(
    String chatId,
    String contactName, [
    String? scrollToMessageId,
  ]) async {
    try {
      final chatData = await _controller.getChatDataForNavigation(chatId);
      if (chatData == null) return;

      final contactId = chatData['contactId'];
      if (contactId == null) return;

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              chatId: chatId,
              contactId: contactId,
              contactName: contactName,
              scrollToMessageId: scrollToMessageId,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error navegando a chat directo: $e');
    }
  }
}
