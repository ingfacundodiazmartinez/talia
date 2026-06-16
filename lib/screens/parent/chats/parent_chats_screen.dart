import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../utils/release_logger.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/block_service.dart';
import '../../../services/message_cache_service.dart';
import '../../../services/message_status_helper.dart';
import '../../../services/local_unread_count_service.dart';
import '../../../services/search_service.dart';
import '../../../services/chats/chat_preferences_cache.dart';
import '../../../models/chat_message.dart';
import '../../../widgets/stories_section.dart';
import '../../../groups/groups.dart'; // Groups V2
import '../../../utils/chat_utils.dart';
import '../../../models/chat_list_item_type.dart';
import '../../../controllers/parent_chats_controller.dart';
import '../../../theme_service.dart';
import '../../chat_detail_screen.dart';
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
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final ContactAliasService _aliasService = ContactAliasService();
  final BlockService _blockService = BlockService();
  final ChatPreferencesCache _preferencesCache = ChatPreferencesCache();
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');
  // Scroll de la lista — usado para volver al tope al reabrir la app.
  final ScrollController _chatListScrollController = ScrollController();
  late ParentChatsController _controller;

  /// Contador para forzar rebuild cuando cambia estado de archivado/silenciado/limpiado
  int _preferencesVersion = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Create temporary controller to get current user ID
    final tempController = ParentChatsController(userId: '');
    _controller = ParentChatsController(userId: tempController.currentUserId);

    // ✅ Escuchar cambios en contadores de no leídos para actualizar badges
    LocalUnreadCountService().addListener(_onUnreadCountsChanged);

    // ✅ Escuchar cambios en preferencias (archivado/silenciado/limpiado) para actualizar lista
    _preferencesCache.addListener(_onPreferencesChanged);
    ReleaseLogger.log('🔔 [ParentChatsScreen] Listener REGISTRADO en ChatPreferencesCache. hashCode: ${identityHashCode(_preferencesCache)}', tag: 'Chats');

    // 🔒 Hive como SST: rebuildear la chat list cuando llega un mensaje a
    // cache (reordena la lista por el nuevo timestamp).
    _lastMessageSub = MessageCacheService().lastMessageChanges.listen((_) {
      if (mounted) setState(() {});
    });
    _groupLastMessageSub = GroupMessageCacheService().lastMessageChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  StreamSubscription<String>? _lastMessageSub;
  StreamSubscription<String>? _groupLastMessageSub;

  void _onPreferencesChanged() {
    final oldVersion = _preferencesVersion;
    ReleaseLogger.log('🔄 [ParentChatsScreen] _onPreferencesChanged LLAMADO! version: $oldVersion -> ${oldVersion + 1}', tag: 'Chats');
    if (mounted) {
      setState(() => _preferencesVersion++);
      ReleaseLogger.log('🔄 [ParentChatsScreen] setState EJECUTADO. Nuevo _preferencesVersion: $_preferencesVersion', tag: 'Chats');
    } else {
      ReleaseLogger.warning('⚠️ [ParentChatsScreen] Widget NO ESTÁ MOUNTED! No se puede hacer setState', tag: 'Chats');
    }
  }

  void _onUnreadCountsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver desde background, resetear scroll al tope (mismo comportamiento
    // que en child shell — la sesión nueva empieza desde los chats más recientes).
    if (state == AppLifecycleState.resumed) {
      if (_chatListScrollController.hasClients) {
        _chatListScrollController.jumpTo(0);
      }
      // 🔌 Despertar el socket gRPC de Firestore: tras background largo el
      // listener de getChatsStream queda vivo pero sin recibir updates hasta
      // reiniciar la app. Un get(Source.server) reactiva el canal.
      _controller.refreshChatsFromServer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LocalUnreadCountService().removeListener(_onUnreadCountsChanged);
    _preferencesCache.removeListener(_onPreferencesChanged);
    _lastMessageSub?.cancel();
    _groupLastMessageSub?.cancel();
    _searchController.dispose();
    _searchQuery.dispose();
    _chatListScrollController.dispose();
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
                    Text(
                      'Chats',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.archive, color: Colors.white, size: 26),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => ParentArchivedChatsScreen(),
                              ),
                            ).then((_) {
                              // Refrescar lista al volver de chats archivados
                              if (mounted) setState(() {});
                            });
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
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const CreateGroupScreenV2(),
                              ),
                            );

                            // Refrescar grupos al volver
                            if (mounted) {
                              await _controller.refreshGroupsFromServer();
                              if (mounted) setState(() {});
                            }
                          },
                          padding: EdgeInsets.all(8),
                        ),
                      ],
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
                          // ✅ Key cambia cuando preferencias cambian para forzar rebuild completo
                          child: StreamBuilder<QuerySnapshot>(
                            key: ValueKey('chats_$_preferencesVersion'),
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
                              // ✅ Key cambia cuando preferencias cambian para forzar rebuild
                              return StreamBuilder<QuerySnapshot>(
                                    key: ValueKey('groups_$_preferencesVersion'),
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

                                      // Cachear chats para iOS Share Extension (fire and forget)
                                      _controller.cacheChatsForShareExtension(
                                        chatDocs: chatDocs,
                                        groups: groups,
                                      );

                                      return ValueListenableBuilder<String>(
                                        valueListenable: _searchQuery,
                                        builder: (context, query, _) {
                                          // Si no hay query, mostrar lista normal
                                          if (query.trim().isEmpty) {
                                            return SlidableAutoCloseBehavior(
                                              child: ListView.builder(
                                                controller: _chatListScrollController,
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
                                              ),
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

  /// Preview del último mensaje a mostrar en la chat list, derivado del
  /// ChatMessage cacheado en Hive.
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
        // ✅ FIX #5: Key única para evitar reutilización incorrecta de estado
        return StreamBuilder<DocumentSnapshot>(
          key: ValueKey('user_stream_$userId'),
          stream: _controller.getUserDataStream(userId),
          builder: (context, userSnapshot) {
            if (!userSnapshot.hasData || userSnapshot.data == null) return SizedBox.shrink();

            final fetchedUserData =
                userSnapshot.data!.data() as Map<String, dynamic>?;
            if (fetchedUserData == null) return SizedBox.shrink();

            final userName = fetchedUserData['name'] ?? 'Usuario';

            // ✅ FIX #5: Key única para alias del usuario
            return StreamBuilder<String>(
              key: ValueKey('alias_$userId'),
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
        final groupMembers = (groupData['members'] as List?)?.cast<String>() ?? <String>[];

        // Filter by search
        if (searchQuery.isNotEmpty &&
            !groupName.toLowerCase().contains(searchQuery)) {
          return SizedBox.shrink();
        }

        // ✅ Leer contador de mensajes no leídos desde cache local
        final unreadCount = LocalUnreadCountService().getUnreadCount(groupId);

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

            final clearedAt = _preferencesCache.getClearedAt(groupId);
            final isCleared = clearedAt != null &&
                (lastMsg == null || !clearedAt.isBefore(lastMsg.timestamp));

            final lastMessage = isCleared
                ? 'Inicia la conversación'
                : (lastMessageFromCache ?? 'Inicia la conversación');
            final timeString = isCleared || lastMsg == null
                ? ''
                : _controller.formatTime(Timestamp.fromDate(lastMsg.timestamp));

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

    // ✅ FIX #5: Keys únicas para evitar reutilización incorrecta de estado
    return StreamBuilder<String>(
      key: ValueKey('chat_alias_$childId'),
      stream: _aliasService.watchDisplayName(childId, realName),
      initialData: realName,
      builder: (context, aliasSnapshot) {
        final displayName = aliasSnapshot.data ?? realName;

        // ✅ Solo el bloqueador ve la marca "Contacto bloqueado" en su lista.
        // El bloqueado nunca debe enterarse, pero su foto sí se oculta en ChatListItem.
        return StreamBuilder<bool>(
          key: ValueKey('blocked_$childId'),
          stream: _blockService.iBlockedStream(childId),
          initialData: false,
          builder: (context, blockedSnapshot) {
            final isBlocked = blockedSnapshot.data ?? false;

            if (chatDoc != null) {
              // Chat con mensajes existentes
              final chatData = chatDoc.data() as Map<String, dynamic>;
              // ✅ Leer contador de mensajes no leídos desde cache local
              final unreadCount = LocalUnreadCountService().getUnreadCount(chatDoc.id);
              final currentUserId = _controller.currentUserId;

              // 🔒 Source of truth: Hive (MessageCacheService). El cliente
              // nuevo NO lee chatData['lastMessage*'] — siguen escribiéndose
              // server-side pero solo para backward compat.
              return StreamBuilder<ChatMessage?>(
                key: ValueKey('hive_last_${chatDoc.id}'),
                stream: MessageCacheService().watchLastMessage(chatDoc.id),
                builder: (context, lastMsgSnapshot) {
                  final lastMsg = lastMsgSnapshot.data;
                  final lastMessageSender = lastMsg?.senderId;
                  final isOwnLastMessage = lastMessageSender != null &&
                      lastMessageSender == currentUserId;
                  final lastMessagePreview = _previewFor(lastMsg);
                  final lastMessageDateTime =
                      lastMsg?.timestamp?.toDate() ?? lastMsg?.localTimestamp;
                  final lastMessageType = lastMsg?.type;

                  final clearedAt = _preferencesCache.getClearedAt(chatDoc.id);
                  final isChatCleared = clearedAt != null &&
                      (lastMessageDateTime == null ||
                          !clearedAt.isBefore(lastMessageDateTime));

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
                onArchived: () => setState(() => _preferencesVersion++),
                onMuted: () => setState(() => _preferencesVersion++),
                onCleared: () => setState(() => _preferencesVersion++),
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

    String? errorMessage;
    try {
      await _controller.leaveGroup(groupId);
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      // ✅ SIEMPRE cerrar el spinner, sin importar el resultado
      if (navigator.canPop()) {
        navigator.pop();
      }
    }

    // Mostrar mensaje después de cerrar el spinner
    if (errorMessage != null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Error al salir del grupo: $errorMessage'),
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
      // Refrescar la UI
      if (mounted) {
        setState(() {});
      }
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
      // Para chats directos (hijos y otros contactos)
      // Necesitamos obtener el contactId del chatId
      _navigateToDirectChat(result.chatId, result.chatName);
    }
  }

  /// Navega al chat y al mensaje específico desde un resultado de búsqueda
  void _navigateToMessage(MessageSearchResult result) {
    ReleaseLogger.log(
      '🔍 [Search] _navigateToMessage: chatId=${result.chatId}, messageId=${result.message.id}, type=${result.chatType}',
      tag: 'Search',
    );

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
    ReleaseLogger.log(
      '🔍 [Search] _navigateToDirectChat: chatId=$chatId, scrollToMessageId=$scrollToMessageId',
      tag: 'Search',
    );

    try {
      final chatData = await _controller.getChatDataForNavigation(chatId);
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
        // ✅ FIX: Forzar refresh cuando vuelve del chat para actualizar lastMessageTime
        if (mounted) setState(() {});
      }
    } catch (e) {
      ReleaseLogger.error('🔍 [Search] Error navegando: $e', tag: 'Search');
    }
  }
}
