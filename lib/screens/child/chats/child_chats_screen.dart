import 'dart:async';
import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../controllers/child_chats_controller.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/emergency_button.dart';
import '../../../groups/groups.dart'; // Groups V2
import '../../../services/chats/chat_services.dart';
import '../../../services/message_cache_service.dart';
import '../../../services/message_status_helper.dart';
import '../../../services/local_unread_count_service.dart';
import '../../../services/search_service.dart';
import '../../../services/user_cache_service.dart';
import '../../../services/block_service.dart';
import '../../../models/chat_message.dart';
import '../../../models/chat_list_item_type.dart';
import '../../../utils/chat_utils.dart';
import '../../../utils/release_logger.dart';
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

class _ChildChatsScreenState extends State<ChildChatsScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  late ChildChatsController _chatsController;
  final LeaveGroupService _leaveGroupService = LeaveGroupService();
  final UserCacheService _userCacheService = UserCacheService();
  final BlockService _blockService = BlockService();
  final ChatPreferencesCache _preferencesCache = ChatPreferencesCache();
  // Búsqueda
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');
  // Scroll de la lista de chats — usado para volver al tope al reabrir la app.
  final ScrollController _chatListScrollController = ScrollController();

  /// ✅ Contador para forzar rebuild cuando cambia estado de archivado/silenciado/limpiado
  int _preferencesVersion = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chatsController = ChildChatsController(userId: widget.childId);
    _chatsController.initialize();

    // ✅ Inicializar cache de usuarios y forzar rebuild cuando termine
    _userCacheService.initialize().then((_) {
      if (mounted) setState(() {});
    });

    // ✅ Escuchar cambios en contadores de no leídos para actualizar badges
    LocalUnreadCountService().addListener(_onUnreadCountsChanged);

    // ✅ Escuchar cambios en preferencias (archivado/silenciado/limpiado) para actualizar lista
    _preferencesCache.addListener(_onPreferencesChanged);

    // ✅ Escuchar cambios en alias para actualizar nombres en la lista
    _userCacheService.aliasChangedNotifier.addListener(_onAliasChanged);

    // 🔒 Hive como SST: rebuildear la chat list cuando llega un mensaje
    // nuevo a cache (cualquier chat o grupo). Esto reordena la lista por
    // el nuevo timestamp del último mensaje.
    _lastMessageSub = MessageCacheService().lastMessageChanges.listen((_) {
      if (mounted) setState(() {});
    });
    _groupLastMessageSub = GroupMessageCacheService().lastMessageChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  StreamSubscription<String>? _lastMessageSub;
  StreamSubscription<String>? _groupLastMessageSub;

  void _onAliasChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onPreferencesChanged() {
    if (mounted) {
      setState(() => _preferencesVersion++);
    }
  }

  void _onUnreadCountsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver a la app desde background, resetear scroll de la chat list
    // al tope. El user pidió ese comportamiento — la sesión nueva empieza
    // desde el chat más reciente, no donde quedó.
    if (state == AppLifecycleState.resumed) {
      if (_chatListScrollController.hasClients) {
        _chatListScrollController.jumpTo(0);
      }
      // 🔌 Despertar el socket gRPC de Firestore: tras background largo el
      // listener de getChatsStream queda vivo pero sin recibir updates hasta
      // reiniciar la app. Un get(Source.server) reactiva el canal.
      _chatsController.refreshChatsFromServer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LocalUnreadCountService().removeListener(_onUnreadCountsChanged);
    _preferencesCache.removeListener(_onPreferencesChanged);
    _userCacheService.aliasChangedNotifier.removeListener(_onAliasChanged);
    _lastMessageSub?.cancel();
    _groupLastMessageSub?.cancel();
    _searchController.dispose();
    _searchQuery.dispose();
    _chatListScrollController.dispose();
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
              : [ThemeService.primaryColor, Color(0xFFB39DDB)],
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
      title: 'Chats',
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

  /// Genera el preview de texto a mostrar en la chat list desde el ChatMessage
  /// del cache Hive. Si no hay mensaje, devuelve ''.
  String _previewFor(ChatMessage? m) {
    if (m == null) return '';
    if (m.isDeletedForEveryone) return 'Mensaje eliminado';
    if (m.latitude != null && m.longitude != null) {
      return m.isLiveLocation ? '📍 Ubicación en tiempo real' : '📍 Ubicación';
    }
    final text = m.text?.trim();
    if (text != null && text.isNotEmpty) return text;
    if (m.imageUrl != null && m.imageUrl!.isNotEmpty) return '📷 Imagen';
    if (m.videoUrl != null && m.videoUrl!.isNotEmpty) return '🎥 Video';
    if (m.audioUrl != null && m.audioUrl!.isNotEmpty) return '🎤 Audio';
    return '';
  }

  Widget _buildChatList(ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      key: ValueKey('chats_$_preferencesVersion'),
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
              var chatDocs = _chatsController.filterDeletedChats(_lastValidChatsData!);
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

        var chatDocs = _chatsController.filterDeletedChats(dataToUse);

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
  // ✅ Incluye grupos pendientes de aprobación
  Widget _buildChatListContent(List<QueryDocumentSnapshot> chatDocs, ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      key: ValueKey('groups_$_preferencesVersion'),
      stream: _chatsController.getGroupsStream(),
      builder: (context, groupsSnapshot) {
        // También escuchar grupos pendientes
        return StreamBuilder<QuerySnapshot>(
          stream: _chatsController.getPendingGroupsStream(),
          builder: (context, pendingGroupsSnapshot) {
            final allGroups = groupsSnapshot.data?.docs ?? [];
            final groups = _chatsController.filterArchivedGroups(allGroups);

            // Grupos pendientes (no se filtran por archivados)
            final pendingGroups = pendingGroupsSnapshot.data?.docs ?? [];

            // Construir lista de items usando controller
            final listItems = _chatsController.buildListItems(
              chatDocs: chatDocs,
              groups: groups,
              pendingGroups: pendingGroups,
            );

            // Cachear chats para iOS Share Extension (fire and forget)
            _chatsController.cacheChatsForShareExtension(
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
                        controller: _chatListScrollController,
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

            // ✅ OPTIMIZADO: Solo pasar el nombre de Firestore como fallback
            // SyncedUserName en ChatListItem calculará el displayName correcto
            // con prioridad: alias > agenda > Firestore
            final userName = fetchedUserData['name'] ?? 'Usuario';

            return _buildChatItemWidget(
              childId: userId,
              childData: fetchedUserData,
              chatDoc: chatDoc,
              displayName: userName,
            );
          },
        );

      case GroupItem(:final groupId, :final groupData, :final isPending):
        return _buildGroupItemWidget(groupId, groupData, isPending: isPending);

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

    // Solo el bloqueador ve la marca de "Contacto bloqueado" en su lista.
    // El bloqueado nunca debe enterarse, pero sí oculta la foto del bloqueador.
    return StreamBuilder<bool>(
      key: ValueKey('blocked_$childId'),
      stream: _blockService.iBlockedStream(childId),
      initialData: false,
      builder: (context, blockedSnapshot) {
        final isBlocked = blockedSnapshot.data ?? false;

        if (chatDoc != null) {
          final chatData = chatDoc.data() as Map<String, dynamic>;
          final unreadCount = LocalUnreadCountService().getUnreadCount(chatDoc.id);
          final currentUserId = _chatsController.userId;

          // 🔒 Source of truth: Hive cache. El cliente nuevo NO lee
          // chatData['lastMessage*'] — esos siguen en Firestore solo para
          // backward compat con clientes viejos. La info de receipts
          // (lastOpenedAt_*, lastReceivedAt_*) SÍ sigue viniendo del chatData
          // porque es metadata del recipient, no del mensaje.
          return StreamBuilder<ChatMessage?>(
            key: ValueKey('hive_last_${chatDoc.id}'),
            stream: MessageCacheService().watchLastMessage(chatDoc.id),
            builder: (context, lastMsgSnapshot) {
              final lastMsg = lastMsgSnapshot.data;

              final lastMessageSender = lastMsg?.senderId;
              final isOwnLastMessage =
                  lastMessageSender != null && lastMessageSender == currentUserId;
              final lastMessagePreview = _previewFor(lastMsg);
              final lastMessageDateTime =
                  lastMsg?.timestamp?.toDate() ?? lastMsg?.localTimestamp;
              final lastMessageType = lastMsg?.type;

              // ¿Chat limpiado? Comparar contra el lastMessage de Hive.
              final clearedAt = _preferencesCache.getClearedAt(chatDoc.id);
              final isChatCleared = clearedAt != null &&
                  (lastMessageDateTime == null ||
                      !clearedAt.isBefore(lastMessageDateTime));

              // Status (sent/delivered/seen) solo aplica a mis propios mensajes.
              MessageStatus? lastMessageStatus;
              ModerationStatus? lastMessageModerationStatus;
              if (isOwnLastMessage && lastMsg != null) {
                final chatParticipants =
                    List<String>.from(chatData['participants'] ?? []);
                final recipientId = chatParticipants.firstWhere(
                  (id) => id != currentUserId,
                  orElse: () => '',
                );
                final recipientLastOpenedAt =
                    chatData['lastOpenedAt_$recipientId'] as Timestamp?;
                final recipientLastReceivedAt =
                    chatData['lastReceivedAt_$recipientId'] as Timestamp?;

                lastMessageStatus = MessageStatusHelper.calculateStatusV2(
                  messageTimestamp: lastMessageDateTime,
                  senderId: lastMessageSender,
                  recipientLastOpenedAt: recipientLastOpenedAt?.toDate(),
                  recipientLastReceivedAt: recipientLastReceivedAt?.toDate(),
                );
                lastMessageModerationStatus = lastMsg.moderationStatus;
              }

              return ChatListItem(
                chatId: chatDoc.id,
                userId: childId,
                name: displayName,
                lastMessage: isBlocked
                    ? '🔒 Contacto bloqueado'
                    : (isChatCleared
                        ? 'Inicia una conversación...'
                        : lastMessagePreview),
                time: isChatCleared || lastMessageDateTime == null
                    ? ''
                    : ChatUtils.formatChatTime(
                        Timestamp.fromDate(lastMessageDateTime)),
                unreadCount: isBlocked ? 0 : unreadCount,
                photoURL: photoURL,
                isEmpty: isChatCleared,
                isBlocked: isBlocked,
                lastMessageSenderId:
                    isChatCleared || !isOwnLastMessage ? null : lastMessageSender,
                lastMessageStatus: isChatCleared ? null : lastMessageStatus,
                lastMessageModerationStatus:
                    isChatCleared ? null : lastMessageModerationStatus,
                lastMessageType: lastMessageType,
                onArchived: () => setState(() => _preferencesVersion++),
                onMuted: () => setState(() => _preferencesVersion++),
                onCleared: () => setState(() => _preferencesVersion++),
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
            onArchived: () => setState(() => _preferencesVersion++),
            onMuted: () => setState(() => _preferencesVersion++),
            onCleared: () => setState(() => _preferencesVersion++),
          );
        }
      },
    );
  }

  Widget _buildGroupItemWidget(String groupId, Map<String, dynamic> groupData, {bool isPending = false}) {
    final groupName = groupData['name'] ?? 'Grupo';
    final groupMembers = (groupData['members'] as List?)?.cast<String>() ?? <String>[];
    // ✅ Leer contador de mensajes no leídos desde cache local (0 si está pendiente)
    final unreadCount = isPending ? 0 : LocalUnreadCountService().getUnreadCount(groupId);

    // Si está pendiente, mostrar versión simplificada sin stream de mensajes
    if (isPending) {
      return GroupChatListItem(
        groupId: groupId,
        groupName: groupName,
        memberCount: (groupData['members'] as List?)?.length ?? 0,
        lastMessage: 'Pendiente de aprobación',
        messageCount: 0,
        groupImageUrl: groupData['avatar'],
        unreadCount: 0,
        isPending: true,
        onLeaveGroup: null, // No puede salir si está pendiente
        onArchived: null,
        onMuted: null,
        onCleared: null,
        timeString: '',
      );
    }

    // 🔒 Source of truth: Hive (GroupMessageCacheService).
    return StreamBuilder<GroupMessage?>(
      key: ValueKey('hive_last_grp_$groupId'),
      stream: GroupMessageCacheService().watchLastMessage(groupId),
      builder: (context, lastMsgSnapshot) {
        final lastMsg = lastMsgSnapshot.data;
        String? lastMessageSenderId;
        MessageStatus? lastMessageStatus;
        ModerationStatus? lastMessageModerationStatus;
        String? lastMessageFromCache;

        if (lastMsg != null) {
          final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
          final senderId = lastMsg.senderId;
          lastMessageSenderId = senderId;
          final isOwnMessage = senderId == currentUserId;

          // Preview
          String messagePreview;
          if (lastMsg.isDeleted) {
            messagePreview = 'Mensaje eliminado';
          } else if (lastMsg.latitude != null && lastMsg.longitude != null) {
            messagePreview = lastMsg.isLiveLocation
                ? '📍 Ubicación en tiempo real'
                : '📍 Ubicación';
          } else if ((lastMsg.text ?? '').isNotEmpty) {
            final t = lastMsg.text!;
            messagePreview = t.length > 40 ? '${t.substring(0, 40)}...' : t;
          } else if ((lastMsg.imageUrl ?? '').isNotEmpty) {
            messagePreview = '📷 Imagen';
          } else if ((lastMsg.videoUrl ?? '').isNotEmpty) {
            messagePreview = '🎥 Video';
          } else if ((lastMsg.audioUrl ?? '').isNotEmpty) {
            messagePreview = '🎵 Audio';
          } else {
            messagePreview = '';
          }
          if (!isOwnMessage && lastMsg.senderName.isNotEmpty && messagePreview.isNotEmpty) {
            final firstName = lastMsg.senderName.split(' ').first;
            lastMessageFromCache = '$firstName: $messagePreview';
          } else {
            lastMessageFromCache = messagePreview;
          }

          // Status: armamos un map sintético compatible con calculateGroupV2Status.
          // ignore: deprecated_member_use_from_same_package
          lastMessageStatus = MessageStatusHelper.calculateGroupV2Status(
            data: {
              'readBy': lastMsg.readBy,
              'timestamp': lastMsg.timestamp,
            },
            senderId: senderId,
            hasServerTimestamp: true,
            groupMembers: groupMembers,
          );

          if (lastMessageStatus == MessageStatus.seen) {
            lastMessageModerationStatus = ModerationStatus.approved;
          }
          if (lastMsg.moderationStatus != null) {
            switch (lastMsg.moderationStatus) {
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

        // Clear flag con timestamp de Hive.
        final clearedAt = _preferencesCache.getClearedAt(groupId);
        final isGroupCleared = clearedAt != null &&
            (lastMsg == null || !clearedAt.isBefore(lastMsg.timestamp));

        final lastMessage = isGroupCleared
            ? 'Inicia la conversación'
            : (lastMessageFromCache ?? 'Inicia la conversación');
        final timeString = isGroupCleared || lastMsg == null
            ? ''
            : _chatsController.formatTime(Timestamp.fromDate(lastMsg.timestamp));

        return GroupChatListItem(
          groupId: groupId,
          groupName: groupName,
          memberCount: (groupData['members'] as List?)?.length ?? 0,
          lastMessage: lastMessage,
          messageCount: groupData['messageCount'] ?? 0,
          groupImageUrl: groupData['avatar'],
          unreadCount: unreadCount,
          onLeaveGroup: () => _confirmLeaveGroup(groupId, groupName),
          onArchived: () => setState(() => _preferencesVersion++),
          onMuted: () => setState(() => _preferencesVersion++),
          onCleared: () => setState(() => _preferencesVersion++),
          lastMessageSenderId: lastMessageSenderId,
          lastMessageStatus: lastMessageStatus,
          lastMessageModerationStatus: lastMessageModerationStatus,
          lastMessageType: null, // GroupMessage no tiene field 'type' explícito
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

    ReleaseLogger.log(
      '🔍 [Search] _navigateToMessage: chatId=${result.chatId}, messageId=${result.message.id}, type=${result.chatType}',
      tag: 'Search',
    );

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
    ReleaseLogger.log(
      '🔍 [Search] _navigateToDirectChat: chatId=$chatId, scrollToMessageId=$scrollToMessageId',
      tag: 'Search',
    );

    try {
      final chatData = await _chatsController.getChatDataForNavigation(chatId);
      if (chatData == null) {
        ReleaseLogger.log('🔍 [Search] chatData is null', tag: 'Search');
        return;
      }

      final contactId = chatData['contactId'];
      if (contactId == null) {
        ReleaseLogger.log('🔍 [Search] contactId is null', tag: 'Search');
        return;
      }

      ReleaseLogger.log(
        '🔍 [Search] Navigating to ChatDetailScreen with scrollToMessageId=$scrollToMessageId',
        tag: 'Search',
      );

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
      ReleaseLogger.error('🔍 [Search] Error navigating: $e', tag: 'Search');
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
                    // ✅ OPTIMIZADO: Solo pasar el nombre de Firestore como fallback
                    // SyncedUserName en ChatListItem calculará el displayName correcto
                    final realName = parentData['name'] ?? 'Padre/Madre';

                    return ChatListItem(
                      chatId: _chatsController.getChatId(widget.childId, parentId),
                      userId: parentId,
                      name: realName,
                      lastMessage: 'Inicia una conversación',
                      time: '',
                      unreadCount: 0,
                      photoURL: parentData['photoURL'],
                      isEmpty: true,
                      onArchived: () => setState(() => _preferencesVersion++),
                      onMuted: () => setState(() => _preferencesVersion++),
                      onCleared: () => setState(() => _preferencesVersion++),
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
