import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../controllers/child_chats_controller.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/emergency_button.dart';
import '../../../groups/groups.dart'; // Groups V2
import '../../../services/chat_service.dart';
import '../../../services/chats/chat_services.dart';
import '../../../services/message_status_helper.dart';
import '../../../services/local_unread_count_service.dart';
import '../../../services/search_service.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/block_service.dart';
import '../../../models/chat_message.dart';
import '../../../models/chat_list_item_type.dart';
import '../../../utils/chat_utils.dart';
import '../../chat_detail_screen.dart';
import '../../parent/chats/widgets/group_chat_list_item.dart';
import '../../parent/chats/widgets/chat_list_item.dart';
import '../../parent/chats/widgets/chat_search_bar.dart';
import '../../parent/chats/widgets/search_result_widgets.dart';
import '../../common/chats/chat_header_widget.dart';
import '../../common/chats/chat_empty_state_widget.dart';
import 'child_archived_chats_screen.dart';

/// Pantalla completa de chats para niños
///
/// Incluye:
/// - Header con botones de crear grupo y emergencia
/// - Sección de stories
/// - Grupos
/// - Chat con padre (categoría "Familia")
/// - Chats con otros contactos
class ChildChatsScreen extends StatefulWidget {
  final String childId;
  final ChildHomeController controller;

  const ChildChatsScreen({
    super.key,
    required this.childId,
    required this.controller,
  });

  @override
  State<ChildChatsScreen> createState() => _ChildChatsScreenState();
}

class _ChildChatsScreenState extends State<ChildChatsScreen> with AutomaticKeepAliveClientMixin {
  late ChildChatsController _chatsController;
  final ChatService _chatService = ChatService();
  final LeaveGroupService _leaveGroupService = LeaveGroupService();
  final ContactAliasService _aliasService = ContactAliasService();
  final BlockService _blockService = BlockService();
  final ChatPreferencesCache _preferencesCache = ChatPreferencesCache();
  // Búsqueda
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _chatsController = ChildChatsController(userId: widget.childId);
    _chatsController.initialize();

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
    _chatsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDarkMode
              ? [
                  colorScheme.primary.withValues(alpha: 0.3),
                  colorScheme.primary.withValues(alpha: 0.2),
                ]
              : [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(isDarkMode, colorScheme),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                ),
                child: _buildChatList(colorScheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDarkMode, ColorScheme colorScheme) {
    return ChatHeaderWidget(
      title: '¡Hola! 👋',
      subtitle: 'Tus conversaciones seguras',
      isDarkMode: isDarkMode,
      onArchivedTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChildArchivedChatsScreen(
              childId: widget.childId,
            ),
          ),
        ).then((_) {
          // Refrescar lista al volver de chats archivados
          if (mounted) setState(() {});
        });
      },
      onCreateGroupTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const CreateGroupScreenV2(),
          ),
        );
        // Refresh on return
        if (mounted) setState(() {});
      },
      additionalAction: FutureBuilder<bool>(
        future: widget.controller.hasLinkedParents(),
        builder: (context, snapshot) {
          if (snapshot.data == true) {
            return HeaderEmergencyButton(
              onEmergencyActivated: () {},
            );
          }
          return SizedBox.shrink();
        },
      ),
    );
  }

  // ✅ CACHE: Variables para mantener últimos datos válidos y evitar rebuild infinito
  QuerySnapshot? _lastValidChatsData;
  DateTime _lastValidChatsTimestamp = DateTime.now();

  Widget _buildChatList(ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      stream: _chatsController.getChatsStream(),
      builder: (context, snapshot) {
        // CACHE LOGIC: Actualizar cache cuando tenemos datos válidos
        if (snapshot.hasData && snapshot.data != null) {
          _lastValidChatsData = snapshot.data;
          _lastValidChatsTimestamp = DateTime.now();
        }

        final isInitialLoading = snapshot.connectionState == ConnectionState.waiting &&
                                 !snapshot.hasData &&
                                 !snapshot.hasError &&
                                 _lastValidChatsData == null; // Solo initial loading si no hay cache

        if (isInitialLoading) {
          return Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          // En caso de error, usar cache si está disponible y es reciente (< 5 minutos)
          if (_lastValidChatsData != null) {
            final cacheAge = DateTime.now().difference(_lastValidChatsTimestamp).inMinutes;
            if (cacheAge < 5) {
              var chatDocs = _chatService.filterDeletedChats(_lastValidChatsData!);
              chatDocs = _chatsController.filterArchivedChats(chatDocs);
              return _buildChatListContent(chatDocs, colorScheme);
            }
          }
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        // Usar cache cuando estamos waiting pero tenemos datos válidos recientes
        final useCache = !snapshot.hasData && _lastValidChatsData != null &&
                        DateTime.now().difference(_lastValidChatsTimestamp).inMinutes < 10;

        final dataToUse = useCache ? _lastValidChatsData! : snapshot.data;

        if (dataToUse == null) {
          return Center(child: CircularProgressIndicator());
        }

        var chatDocs = _chatService.filterDeletedChats(dataToUse);

        // Filtrar chats archivados
        chatDocs = _chatsController.filterArchivedChats(chatDocs);

        return _buildChatListContent(chatDocs, colorScheme);
      },
    );
  }

  /// Busca en mensajes de todos los chats cuando hay un query activo
  Future<SearchResults> _performMessageSearch({
    required String query,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    return await _chatsController.performMessageSearch(
      query: query,
      chatDocs: chatDocs,
      groups: groups,
    );
  }

  // Método separado para construir el contenido con grupos
  // ✅ UNIFICADO: Usa el mismo enfoque que parent_chats_screen
  Widget _buildChatListContent(List<QueryDocumentSnapshot> chatDocs, ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      stream: _chatsController.getGroupsStream(),
      builder: (context, groupsSnapshot) {
        final allGroups = groupsSnapshot.data?.docs ?? [];
        final groups = _chatsController.filterArchivedGroups(allGroups);

        // Construir lista de items usando controller (igual que parent)
        final listItems = _chatsController.buildListItems(
          chatDocs: chatDocs,
          groups: groups,
        );

        return Column(
          children: [
            // Historias (estáticas, fuera del ListView)
            StoriesHeader(),
            StoriesSection(),
            SizedBox(height: 16),
            // Buscador (estático, fuera del ListView)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: ChatSearchBar(
                controller: _searchController,
                onChanged: (value) => _searchQuery.value = value,
              ),
            ),
            // Lista de chats con pull-to-refresh
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _chatsController.forceReconnect();
                  await Future.delayed(Duration(milliseconds: 500));
                },
                child: ValueListenableBuilder<String>(
                  valueListenable: _searchQuery,
                  builder: (context, query, _) {
                    // Si hay query activo, mostrar resultados de búsqueda
                    if (query.trim().isNotEmpty) {
                      return FutureBuilder<SearchResults>(
                        future: _performMessageSearch(
                          query: query,
                          chatDocs: chatDocs,
                          groups: groups,
                        ),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting &&
                              !snapshot.hasData) {
                            return Center(child: CircularProgressIndicator());
                          }

                          if (snapshot.hasError) {
                            return Center(
                              child: Text('Error en la búsqueda: ${snapshot.error}'),
                            );
                          }

                          final results = snapshot.data;
                          if (results == null || results.isEmpty) {
                            return SearchEmptyState(query: query);
                          }

                          return ListView.builder(
                            padding: EdgeInsets.all(16),
                            itemCount: results.chatResults.length +
                                results.messageResults.length +
                                2,
                            itemBuilder: (context, index) {
                              if (index == 0 && results.chatResults.isNotEmpty) {
                                return SearchResultsHeader(
                                  title: 'CHATS',
                                  count: results.chatResults.length,
                                );
                              }

                              if (index > 0 && index <= results.chatResults.length) {
                                final chatResult = results.chatResults[index - 1];
                                return ChatSearchResultCard(
                                  result: chatResult,
                                  onTap: () => _navigateToChat(chatResult),
                                );
                              }

                              if (index == results.chatResults.length + 1 &&
                                  results.messageResults.isNotEmpty) {
                                return SearchResultsHeader(
                                  title: 'MENSAJES',
                                  count: results.messageResults.length,
                                );
                              }

                              final messageIndex = index - results.chatResults.length - 2;
                              if (messageIndex >= 0 &&
                                  messageIndex < results.messageResults.length) {
                                final messageResult = results.messageResults[messageIndex];
                                return MessageSearchResultCard(
                                  result: messageResult,
                                  onTap: () => _navigateToMessage(messageResult),
                                );
                              }

                              return SizedBox.shrink();
                            },
                          );
                        },
                      );
                    }

                    // Si no hay query, mostrar lista normal
                    if (listItems.isEmpty) {
                      return _buildEmptyState(colorScheme);
                    }

                    return SlidableAutoCloseBehavior(
                      child: ListView.builder(
                        padding: EdgeInsets.all(16),
                        itemCount: listItems.length,
                        itemBuilder: (context, index) {
                          final item = listItems[index];
                          return _buildItemWidget(item, chatDocs);
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Construye el widget correspondiente a cada tipo de item (igual que parent)
  Widget _buildItemWidget(
    ChatListItemType item,
    List<QueryDocumentSnapshot> chatDocs,
  ) {
    switch (item) {
      case ChatItem(:final userId, :final chatDoc):
        return StreamBuilder<DocumentSnapshot>(
          key: ValueKey('user_stream_$userId'),
          stream: _chatsController.getUserDataStream(userId),
          builder: (context, userSnapshot) {
            if (!userSnapshot.hasData || userSnapshot.data == null) {
              return SizedBox.shrink();
            }

            final fetchedUserData = userSnapshot.data!.data() as Map<String, dynamic>?;
            if (fetchedUserData == null) return SizedBox.shrink();

            final userName = fetchedUserData['name'] ?? 'Usuario';

            return StreamBuilder<String>(
              key: ValueKey('alias_$userId'),
              stream: _aliasService.watchDisplayName(userId, userName),
              initialData: userName,
              builder: (context, aliasSnapshot) {
                final displayName = aliasSnapshot.data ?? userName;
                return _buildChatItemWidget(
                  childId: userId,
                  childData: fetchedUserData,
                  chatDoc: chatDoc,
                  displayName: displayName,
                );
              },
            );
          },
        );

      case GroupItem(:final groupId, :final groupData):
        return _buildGroupItemWidget(groupId, groupData);

      default:
        return SizedBox.shrink();
    }
  }

  Widget _buildChatItemWidget({
    required String childId,
    required Map<String, dynamic> childData,
    QueryDocumentSnapshot? chatDoc,
    required String displayName,
  }) {
    final photoURL = childData['photoURL'];

    return StreamBuilder<bool>(
      key: ValueKey('blocked_$childId'),
      stream: _blockService.isBlockedStream(childId),
      initialData: false,
      builder: (context, blockedSnapshot) {
        final isBlocked = blockedSnapshot.data ?? false;

        if (chatDoc != null) {
          final chatData = chatDoc.data() as Map<String, dynamic>;
          final unreadCount = LocalUnreadCountService().getUnreadCount(chatDoc.id);

          return StreamBuilder<QuerySnapshot>(
            key: ValueKey('last_msg_${chatDoc.id}'),
            stream: _chatsController.getChatLastMessageStream(chatDoc.id),
            builder: (context, messageSnapshot) {
              String? lastMessageSenderId;
              MessageStatus? lastMessageStatus;
              ModerationStatus? lastMessageModerationStatus;

              if (messageSnapshot.hasData &&
                  messageSnapshot.data != null &&
                  messageSnapshot.data!.docs.isNotEmpty) {
                final lastMessageDoc = messageSnapshot.data!.docs.first;
                final lastMessageData = lastMessageDoc.data() as Map<String, dynamic>;

                final senderId = lastMessageData['senderId'] as String? ?? '';
                lastMessageSenderId = senderId;

                lastMessageStatus = MessageStatusHelper.calculateStatus(
                  data: lastMessageData,
                  senderId: senderId,
                  hasServerTimestamp: lastMessageData['timestamp'] != null,
                );

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

              // Verificar si el chat fue limpiado usando Hive cache
              final clearedAt = _preferencesCache.getClearedAt(chatDoc.id);
              final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;
              final isChatCleared = clearedAt != null &&
                  (lastMessageTime == null || !clearedAt.isBefore(lastMessageTime.toDate()));

              return ChatListItem(
                chatId: chatDoc.id,
                userId: childId,
                name: displayName,
                lastMessage: isBlocked
                    ? '🔒 Contacto bloqueado'
                    : (isChatCleared
                        ? 'Inicia una conversación...'
                        : (chatData['lastMessage'] ?? '')),
                time: isChatCleared ? '' : ChatUtils.formatChatTime(chatData['lastMessageTime']),
                unreadCount: isBlocked ? 0 : unreadCount,
                photoURL: photoURL,
                isEmpty: isChatCleared,
                isBlocked: isBlocked,
                lastMessageSenderId: isChatCleared ? null : lastMessageSenderId,
                lastMessageStatus: isChatCleared ? null : lastMessageStatus,
                lastMessageModerationStatus: isChatCleared ? null : lastMessageModerationStatus,
                onArchived: () => setState(() {}),
                onMuted: () => setState(() {}),
                onCleared: () => setState(() {}),
              );
            },
          );
        } else {
          return ChatListItem(
            chatId: ChatUtils.getChatId(widget.childId, childId),
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
            onArchived: () => setState(() {}),
            onMuted: () => setState(() {}),
            onCleared: () => setState(() {}),
          );
        }
      },
    );
  }

  Widget _buildGroupItemWidget(String groupId, Map<String, dynamic> groupData) {
    final groupName = groupData['name'] ?? 'Grupo';
    final groupMembers = (groupData['members'] as List?)?.cast<String>() ?? <String>[];
    // ✅ Leer contador de mensajes no leídos desde cache local
    final unreadCount = LocalUnreadCountService().getUnreadCount(groupId);

    return StreamBuilder<QuerySnapshot>(
      stream: _chatsController.getGroupLastMessageStream(groupId),
      builder: (context, messageSnapshot) {
        String? lastMessageSenderId;
        MessageStatus? lastMessageStatus;
        ModerationStatus? lastMessageModerationStatus;
        String? lastMessageFromStream;

        if (messageSnapshot.hasData && messageSnapshot.data!.docs.isNotEmpty) {
          final lastMessageDoc = messageSnapshot.data!.docs.first;
          final lastMessageData = lastMessageDoc.data() as Map<String, dynamic>;

          final senderId = lastMessageData['senderId'] as String? ?? '';
          lastMessageSenderId = senderId;

          // Obtener preview del mensaje desde el stream si no hay en groupData
          final messageText = lastMessageData['text'] as String?;
          final hasImage = lastMessageData['imageUrl'] != null;
          final hasVideo = lastMessageData['videoUrl'] != null;
          final hasAudio = lastMessageData['audioUrl'] != null;
          final isDeleted = lastMessageData['isDeleted'] as bool? ?? false;
          final senderName = lastMessageData['senderName'] as String? ?? '';
          final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
          final isOwnMessage = senderId == currentUserId;

          // Construir preview del mensaje
          String messagePreview;
          if (isDeleted) {
            messagePreview = 'Mensaje eliminado';
          } else if (messageText != null && messageText.isNotEmpty) {
            messagePreview = messageText.length > 40
                ? '${messageText.substring(0, 40)}...'
                : messageText;
          } else if (hasImage) {
            messagePreview = '📷 Imagen';
          } else if (hasVideo) {
            messagePreview = '🎥 Video';
          } else if (hasAudio) {
            messagePreview = '🎵 Audio';
          } else {
            messagePreview = '';
          }

          // Agregar nombre del sender si no es mensaje propio
          if (!isOwnMessage && senderName.isNotEmpty && messagePreview.isNotEmpty) {
            // Usar solo el primer nombre para ahorrar espacio
            final firstName = senderName.split(' ').first;
            lastMessageFromStream = '$firstName: $messagePreview';
          } else {
            lastMessageFromStream = messagePreview;
          }

          // Usar calculateGroupV2Status - seen solo si TODOS los miembros leyeron
          lastMessageStatus = MessageStatusHelper.calculateGroupV2Status(
            data: lastMessageData,
            senderId: senderId,
            hasServerTimestamp: lastMessageData['timestamp'] != null,
            groupMembers: groupMembers,
          );

          // Para grupos V2, usar verde (approved) cuando está seen, gris para otros estados
          if (lastMessageStatus == MessageStatus.seen) {
            lastMessageModerationStatus = ModerationStatus.approved;
          }

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

        // Prioridad: groupData['lastMessage'] > lastMessageFromStream > 'Inicia la conversación'
        final lastMessage = groupData['lastMessage'] ?? lastMessageFromStream ?? 'Inicia la conversación';

        // Formatear tiempo del último mensaje
        final timeString = _chatsController.formatTime(groupData['lastMessageTime']);

        return GroupChatListItem(
          groupId: groupId,
          groupName: groupName,
          memberCount: (groupData['members'] as List?)?.length ?? 0,
          lastMessage: lastMessage,
          messageCount: groupData['messageCount'] ?? 0,
          groupImageUrl: groupData['avatar'],
          unreadCount: unreadCount,
          onLeaveGroup: () => _confirmLeaveGroup(groupId, groupName),
          lastMessageSenderId: lastMessageSenderId,
          lastMessageStatus: lastMessageStatus,
          lastMessageModerationStatus: lastMessageModerationStatus,
          timeString: timeString,
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
    // ✅ FIX: Guardar referencias antes de operaciones asíncronas
    final navigator = Navigator.of(context, rootNavigator: true);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) => const Center(child: CircularProgressIndicator()),
    );

    // ✅ Usar nuevo servicio atómico
    final result = await _leaveGroupService.call(groupId: groupId);

    // ✅ SIEMPRE cerrar el spinner, sin importar el resultado
    if (navigator.canPop()) {
      navigator.pop();
    }

    // Mostrar mensaje después de cerrar el spinner
    if (!result.success) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Error al salir del grupo: ${result.message}'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Has salido de "$groupName"'),
          duration: Duration(seconds: 2),
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
          builder: (context) => GroupChatScreenV2(
            groupId: result.chatId,
            groupName: result.chatName,
          ),
        ),
      );
    } else {
      // Para chats directos
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
          builder: (context) => GroupChatScreenV2(
            groupId: result.chatId,
            groupName: result.chatName,
            scrollToMessageId: result.message.id,
          ),
        ),
      );
    } else {
      // Para chats directos
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
      final chatData = await _chatsController.getChatDataForNavigation(chatId);
      if (chatData == null) return;

      final contactId = chatData['contactId'];
      if (contactId == null) return;

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              chatId: chatId,
              contactId: contactId,
              contactName: contactName,
              scrollToMessageId: scrollToMessageId,
            ),
          ),
        );
        // ✅ FIX: Forzar refresh cuando vuelve del chat
        if (mounted) setState(() {});
      }
    } catch (e) {
      // Error silencioso
    }
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return FutureBuilder<String?>(
      future: _chatsController.getLinkedParentId(),
      builder: (context, parentSnapshot) {
        return ListView(
          padding: EdgeInsets.all(16),
          children: [
            SizedBox(height: 24),
            if (parentSnapshot.hasData && parentSnapshot.data != null)
              FutureBuilder<Map<String, dynamic>?>(
                future: _chatsController.getUserData(parentSnapshot.data!),
                builder: (context, userSnapshot) {
                  if (userSnapshot.hasData && userSnapshot.data != null) {
                    final parentData = userSnapshot.data!;
                    final parentId = parentSnapshot.data!;
                    final realName = parentData['name'] ?? 'Padre/Madre';

                    return StreamBuilder<String>(
                      stream: _chatsController.watchDisplayName(parentId, realName),
                      initialData: realName,
                      builder: (context, aliasSnapshot) {
                        final displayName = aliasSnapshot.data ?? realName;

                        return ChatListItem(
                          chatId: _chatsController.getChatId(widget.childId, parentId),
                          userId: parentId,
                          name: displayName,
                          lastMessage: 'Inicia una conversación',
                          time: '',
                          unreadCount: 0,
                          photoURL: parentData['photoURL'],
                          isEmpty: true,
                          onArchived: () => setState(() {}),
                          onMuted: () => setState(() {}),
                          onCleared: () => setState(() {}),
                        );
                      },
                    );
                  }
                  return SizedBox.shrink();
                },
              ),
            if (parentSnapshot.data == null)
              ChatEmptyStateWidget(),
          ],
        );
      },
    );
  }
}
