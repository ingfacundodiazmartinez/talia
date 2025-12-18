import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../controllers/child_chats_controller.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/emergency_button.dart';
import '../../../widgets/synced_user_widgets.dart';
import '../../../groups/groups.dart'; // Groups V2
import '../../../services/chat_service.dart';
import '../../../services/chat_archive_service.dart';
import '../../../services/chat_mute_service.dart';
import '../../../services/chat_clear_service.dart';
import '../../../services/message_cache_service.dart';
import '../../../services/typing_indicator_service.dart';
import '../../../services/message_status_helper.dart';
import '../../../services/group_chat_service.dart';
import '../../../services/local_unread_count_service.dart';
import '../../../models/chat_message.dart';
import '../../../widgets/message_status_indicator.dart';
import '../../chat_detail_screen.dart';
import '../../parent/chats/widgets/group_chat_list_item.dart';
import '../../common/chats/chat_header_widget.dart';
import '../../common/chats/chat_section_header_widget.dart';
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
  final ChatArchiveService _archiveService = ChatArchiveService();
  final ChatMuteService _muteService = ChatMuteService();
  final ChatClearService _clearService = ChatClearService();
  final MessageCacheService _cacheService = MessageCacheService();

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

  Widget _buildSlideButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    LocalUnreadCountService().removeListener(_onUnreadCountsChanged);
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
        );
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

  // Método separado para construir el contenido con grupos
  Widget _buildChatListContent(List<QueryDocumentSnapshot> chatDocs, ColorScheme colorScheme) {
    // Obtener grupos del niño
    return StreamBuilder<QuerySnapshot>(
      stream: _chatsController.getGroupsStream(),
      builder: (context, groupsSnapshot) {
        final allGroups = groupsSnapshot.data?.docs ?? [];
        final groups = _chatsController.filterArchivedGroups(allGroups);

        if (chatDocs.isEmpty && groups.isEmpty) {
          return _buildEmptyState(colorScheme);
        }

        return SlidableAutoCloseBehavior(
          child: ListView(
            padding: EdgeInsets.all(16),
            children: [
              StoriesHeader(),
              StoriesSection(),
              SizedBox(height: 16),
              ..._buildChatItems(chatDocs, groups, colorScheme),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildChatItems(
    List<QueryDocumentSnapshot> chatDocs,
    List<QueryDocumentSnapshot> groups,
    ColorScheme colorScheme,
  ) {
    final widgets = <Widget>[];

    // Build groups section
    if (groups.isNotEmpty) {
      widgets.add(ChatSectionHeaderWidget(
        title: 'Grupos',
        icon: Icons.group,
        iconColor: colorScheme.primary,
        iconBackgroundColor: colorScheme.primaryContainer,
        padding: EdgeInsets.only(bottom: 12, left: 4, top: 8),
      ));
      for (final groupDoc in groups) {
        widgets.add(_buildGroupItem(groupDoc, colorScheme));
      }
      widgets.add(SizedBox(height: 8));
    }

    // Build other chats section
    if (chatDocs.isNotEmpty) {
      widgets.add(ChatSectionHeaderWidget(
        title: 'Contactos',
        icon: Icons.people,
        iconColor: colorScheme.primary,
        iconBackgroundColor: colorScheme.primaryContainer,
        padding: EdgeInsets.only(bottom: 12, left: 4),
      ));
      for (final chatDoc in chatDocs) {
        widgets.add(_buildSingleChatItem(chatDoc, false, colorScheme));
      }
    }

    return widgets;
  }

  Widget _buildGroupItem(QueryDocumentSnapshot groupDoc, ColorScheme colorScheme) {
    final groupId = groupDoc.id;
    final groupData = groupDoc.data() as Map<String, dynamic>;
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
      await GroupChatService().leaveGroup(groupId, widget.childId);
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
    }
  }

  Widget _buildSingleChatItem(
    QueryDocumentSnapshot chatDoc,
    bool isParent,
    ColorScheme colorScheme,
  ) {
    final chatId = chatDoc.id;
    final chatData = chatDoc.data() as Map<String, dynamic>;
    final participants = List<String>.from(chatData['participants'] ?? []);
    final otherUserId = participants.firstWhere(
      (id) => id != widget.childId,
      orElse: () => '',
    );

    if (otherUserId.isEmpty) return SizedBox.shrink();

    // ✅ FIX #5: Agregar key única para evitar reutilización incorrecta de estado
    // cuando Flutter reconstruye la lista (race condition que causaba
    // nombre/foto incorrectos al entrar a un chat)
    return StreamBuilder<DocumentSnapshot>(
      key: ValueKey('chat_stream_$chatId'),
      stream: _chatsController.getChatDataStream(chatId),
      initialData: chatDoc,
      builder: (context, chatSnapshot) {
        final currentChatData = chatSnapshot.hasData
            ? (chatSnapshot.data!.data() as Map<String, dynamic>?) ?? chatData
            : chatData;

        // ✅ Leer contador de mensajes no leídos desde cache local
        final unreadCount = LocalUnreadCountService().getUnreadCount(chatId);
        final clearedAt = currentChatData['clearedAt_${widget.childId}'] as Timestamp?;
        final lastMessageTime = currentChatData['lastMessageTime'] as Timestamp?;
        final isChatCleared = clearedAt != null &&
            (lastMessageTime == null || clearedAt.compareTo(lastMessageTime) >= 0);
        final lastMessage = isChatCleared
            ? 'Inicia una conversación...'
            : (currentChatData['lastMessage'] ?? '');
        final timeString = isChatCleared ? '' : _chatsController.formatTime(currentChatData['lastMessageTime']);

        // ✅ FIX #5: Key única para datos de usuario
        return FutureBuilder<Map<String, dynamic>?>(
          key: ValueKey('user_data_$otherUserId'),
          future: _chatsController.getUserData(otherUserId),
          builder: (context, userSnapshot) {
            if (!userSnapshot.hasData) {
              return _buildChatItem(
                chatId: chatId,
                userId: otherUserId,
                name: '...',
                lastMessage: lastMessage,
                time: timeString,
                unreadCount: unreadCount is int ? unreadCount : 0,
                isOnline: false,
                isParent: isParent,
                isEmpty: isChatCleared,
                isBlocked: false,
                colorScheme: colorScheme,
              );
            }

            final userData = userSnapshot.data;
            if (userData == null) return SizedBox.shrink();

            final realName = userData['name'] ?? 'Usuario';
            final isOnline = userData['isOnline'] ?? false;
            final photoURL = userData['photoURL'] as String?;

            // ✅ FIX #5: Key única para el último mensaje
            return StreamBuilder<QuerySnapshot>(
              key: ValueKey('last_msg_$chatId'),
              stream: _chatsController.getChatLastMessageStream(chatId),
              builder: (context, messageSnapshot) {
                String? lastMessageSenderId;
                MessageStatus? lastMessageStatus;
                ModerationStatus? lastMessageModerationStatus;

                if (messageSnapshot.hasData && messageSnapshot.data!.docs.isNotEmpty) {
                  final lastMessageDoc = messageSnapshot.data!.docs.first;
                  final lastMessageData = lastMessageDoc.data() as Map<String, dynamic>;

                  final senderId = lastMessageData['senderId'] as String? ?? '';
                  lastMessageSenderId = senderId;

                  // Usar calculateStatus para chats 1:1
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

                return _buildChatItem(
                  chatId: chatId,
                  userId: otherUserId,
                  name: realName,
                  lastMessage: lastMessage,
                  time: timeString,
                  unreadCount: unreadCount is int ? unreadCount : 0,
                  isOnline: isOnline,
                  photoURL: photoURL,
                  isParent: isParent,
                  isEmpty: isChatCleared,
                  isBlocked: false,
                  colorScheme: colorScheme,
                  lastMessageSenderId: isChatCleared ? null : lastMessageSenderId,
                  lastMessageStatus: isChatCleared ? null : lastMessageStatus,
                  lastMessageModerationStatus: isChatCleared ? null : lastMessageModerationStatus,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return FutureBuilder<String?>(
      future: _chatsController.getLinkedParentId(),
      builder: (context, parentSnapshot) {
        return ListView(
          padding: EdgeInsets.all(16),
          children: [
            StoriesHeader(),
            StoriesSection(),
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

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ChatSectionHeaderWidget(
                              title: 'Familia',
                              icon: Icons.shield,
                              iconColor: Colors.green,
                              iconBackgroundColor: Colors.green.withValues(alpha: 0.1),
                              padding: EdgeInsets.only(bottom: 12, left: 4),
                            ),
                            _buildChatItem(
                              chatId: _chatsController.getChatId(widget.childId, parentId),
                              userId: parentId,
                              name: displayName,
                              lastMessage: 'Inicia una conversación',
                              time: '',
                              unreadCount: 0,
                              isOnline: parentData['isOnline'] ?? false,
                              photoURL: parentData['photoURL'],
                              isParent: true,
                              isEmpty: true,
                              colorScheme: colorScheme,
                            ),
                          ],
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

  Widget _buildChatItem({
    required String chatId,
    required String userId,
    required String name,
    required String lastMessage,
    required String time,
    required int unreadCount,
    required bool isOnline,
    String? photoURL,
    bool isParent = false,
    bool isEmpty = false,
    bool isRevoked = false,
    bool isBlocked = false,
    required ColorScheme colorScheme,
    String? lastMessageSenderId,
    MessageStatus? lastMessageStatus,
    ModerationStatus? lastMessageModerationStatus,
  }) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    return StreamBuilder<bool>(
      stream: _muteService.watchChatMuted(
        chatId: chatId,
        userId: currentUserId,
      ),
      initialData: false,
      builder: (context, muteSnapshot) {
        final isMuted = muteSnapshot.data ?? false;

        final colorScheme = Theme.of(context).colorScheme;

        return Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: ClipRect(
            child: Container(
              color: colorScheme.primary,
              child: Slidable(
            key: Key('chat_$chatId'),
            closeOnScroll: false,
            endActionPane: ActionPane(
            motion: const BehindMotion(),
            extentRatio: 0.5,
            openThreshold: 0.1,
            closeThreshold: 0.1,
            children: [
              Expanded(
                child: Container(
                  color: colorScheme.primary,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildSlideButton(
                        icon: Icons.archive_outlined,
                        label: 'Archivar',
                        onTap: () async {
                          final success = await _archiveService.archiveChat(
                            chatId: chatId,
                            userId: currentUserId,
                          );

                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success ? 'Chat archivado' : 'Error al archivar chat',
                                ),
                                backgroundColor: success ? Colors.green : Colors.red,
                              ),
                            );
                          }
                        },
                      ),
                      _buildSlideButton(
                        icon: isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                        label: isMuted ? 'Activar' : 'Silenciar',
                        onTap: () async {
                          final success = isMuted
                              ? await _muteService.unmuteChat(chatId: chatId, userId: currentUserId)
                              : await _muteService.muteChat(chatId: chatId, userId: currentUserId);

                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success
                                      ? (isMuted ? 'Chat desilenciado' : 'Chat silenciado')
                                      : 'Error al ${isMuted ? 'desilenciar' : 'silenciar'} chat',
                                ),
                                backgroundColor: success ? Colors.green : Colors.red,
                              ),
                            );
                          }
                        },
                      ),
                      _buildSlideButton(
                        icon: Icons.delete_outline_rounded,
                        label: 'Limpiar',
                        onTap: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              title: Row(
                                children: [
                                  Icon(Icons.delete_sweep_rounded, color: Color(0xFFE53935)),
                                  SizedBox(width: 8),
                                  Text('¿Limpiar chat?'),
                                ],
                              ),
                              content: Text(
                                '¿Estás seguro de que quieres eliminar todo el historial de mensajes de este chat?\n\n'
                                'Esta acción no se puede deshacer.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dialogContext, false),
                                  child: Text('Cancelar'),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(dialogContext, true),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Color(0xFFE53935),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: Text('Limpiar'),
                                ),
                              ],
                            ),
                          );

                          if (confirmed == true) {
                            final success = await _clearService.clearChat(
                              chatId: chatId,
                              userId: currentUserId,
                            );

                            if (success) {
                              await _cacheService.clearChat(chatId);
                            }

                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    success ? 'Chat limpiado' : 'Error al limpiar chat',
                                  ),
                                  backgroundColor: success ? Colors.green : Colors.red,
                                ),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          child: GestureDetector(
            onTap: isRevoked ? null : () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ChatDetailScreen(
                    contactId: userId,
                    contactName: name,
                    chatId: chatId,
                  ),
                ),
              );
              // ✅ FIX: Forzar refresh cuando vuelve del chat para actualizar lastMessageTime
              if (mounted) setState(() {});
            },
            child: Opacity(
              opacity: (isRevoked || isBlocked) ? 0.5 : 1.0,
              child: Container(
                padding: EdgeInsets.all(12),
                color: (isRevoked || isBlocked)
                    ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                    : colorScheme.surface,
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundColor: colorScheme.primaryContainer,
                          child: photoURL != null && photoURL.isNotEmpty
                              ? ClipOval(
                                  child: CachedNetworkImage(
                                    imageUrl: photoURL,
                                    width: 50,
                                    height: 50,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => Text(
                                      name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                      style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
                                    ),
                                    errorWidget: (context, url, error) => Text(
                                      name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                      style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                )
                              : Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                  style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
                                ),
                        ),
                        if (isBlocked)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                                border: Border.all(color: colorScheme.surface, width: 2),
                              ),
                              child: Icon(Icons.block, color: Colors.white, size: 10),
                            ),
                          )
                        else if (isOnline)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(color: colorScheme.surface, width: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: SyncedUserName(
                                  userId: userId,
                                  fallbackName: name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    color: colorScheme.onSurface,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isMuted)
                                Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: Icon(
                                    Icons.notifications_off,
                                    size: 14,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              if (time.isNotEmpty)
                                Text(
                                  time,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: 4),
                          StreamBuilder<bool>(
                            stream: TypingIndicatorService().watchOtherUserTyping(
                              chatId,
                              userId,
                            ),
                            builder: (context, typingSnapshot) {
                              final isTyping = typingSnapshot.data ?? false;

                              if (isTyping && !isBlocked && !isRevoked) {
                                return Row(
                                  children: [
                                    SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'Escribiendo...',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: colorScheme.primary,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                );
                              }

                              return Row(
                                children: [
                                  // Status indicator (only for own messages)
                                  if (lastMessageSenderId == currentUserId &&
                                      lastMessageStatus != null &&
                                      !isBlocked &&
                                      !isRevoked) ...[
                                    MessageStatusIndicator(
                                      status: lastMessageStatus,
                                      moderationStatus: lastMessageModerationStatus,
                                      size: 12,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: Text(
                                      isBlocked
                                          ? '🔒 Contacto bloqueado'
                                          : (isRevoked
                                              ? '🔒 Contacto no habilitado por tus padres'
                                              : lastMessage),
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: (isRevoked || isBlocked)
                                            ? colorScheme.error.withValues(alpha: 0.7)
                                            : (isEmpty
                                                ? colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
                                                : colorScheme.onSurfaceVariant),
                                        fontStyle: (isEmpty || isRevoked || isBlocked) ? FontStyle.italic : FontStyle.normal,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (unreadCount > 0 && !isRevoked && !isBlocked)
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: colorScheme.primary,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        unreadCount.toString(),
                                        style: TextStyle(
                                          color: colorScheme.onPrimary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
          ),
        ),
        );
      },
    );
  }
}
