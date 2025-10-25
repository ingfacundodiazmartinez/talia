import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../controllers/child_chats_controller.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/emergency_button.dart';
import '../../../widgets/create_group_widget.dart';
import '../../../services/chat_service.dart';
import '../../../services/block_service.dart';
import '../../../services/chat_archive_service.dart';
import '../../../services/chat_mute_service.dart';
import '../../../services/chat_clear_service.dart';
import '../../../services/message_cache_service.dart';
import '../../../services/typing_indicator_service.dart';
import '../../../services/message_status_helper.dart';
import '../../../screens/group_chat_screen.dart';
import '../../../models/chat_message.dart';
import '../../chat_detail_screen.dart';
import '../../parent/chats/widgets/group_chat_list_item.dart';
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
  final BlockService _blockService = BlockService();
  final ChatArchiveService _archiveService = ChatArchiveService();
  final ChatMuteService _muteService = ChatMuteService();
  final ChatClearService _clearService = ChatClearService();
  final MessageCacheService _cacheService = MessageCacheService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _chatsController = ChildChatsController(childId: widget.childId);
    _chatsController.initialize();
  }

  @override
  void dispose() {
    _chatsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

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
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '¡Hola! 👋',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: isDarkMode ? colorScheme.onSurface : Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Tus conversaciones seguras',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDarkMode
                        ? colorScheme.onSurface.withValues(alpha: 0.7)
                        : Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ChildArchivedChatsScreen(
                        childId: widget.childId,
                      ),
                    ),
                  );
                },
                child: Icon(
                  Icons.archive,
                  color: isDarkMode ? colorScheme.onSurface : Colors.white,
                  size: 22,
                ),
              ),
              SizedBox(width: 8),
              GestureDetector(
                onTap: () {
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
                child: Icon(
                  Icons.group_add,
                  color: isDarkMode ? colorScheme.onSurface : Colors.white,
                  size: 22,
                ),
              ),
              SizedBox(width: 8),
              FutureBuilder<bool>(
                future: widget.controller.hasLinkedParents(),
                builder: (context, snapshot) {
                  if (snapshot.data == true) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HeaderEmergencyButton(
                          onEmergencyActivated: () {
                            print('🆘 Emergencia activada desde el header');
                          },
                        ),
                        SizedBox(width: 8),
                      ],
                    );
                  }
                  return SizedBox.shrink();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChatList(ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('chats')
          .where('participants', arrayContains: widget.childId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        var chatDocs = snapshot.hasData
            ? _chatService.filterDeletedChats(snapshot.data!)
            : <QueryDocumentSnapshot>[];

        // Filtrar chats archivados
        chatDocs = chatDocs.where((chatDoc) {
          final chatData = chatDoc.data() as Map<String, dynamic>;
          final archived = chatData['archived_${widget.childId}'] as bool? ?? false;
          return !archived;
        }).toList();

        // Obtener grupos del niño
        return StreamBuilder<QuerySnapshot>(
          stream: _firestore
              .collection('groups')
              .where('members', arrayContains: widget.childId)
              .snapshots(),
          builder: (context, groupsSnapshot) {
            final groups = groupsSnapshot.data?.docs ?? [];

            // Filtrar grupos archivados
            final activeGroups = groups.where((groupDoc) {
              final groupData = groupDoc.data() as Map<String, dynamic>;
              final archived = groupData['archived_${widget.childId}'] as bool? ?? false;
              return !archived;
            }).toList();

            if (chatDocs.isEmpty && activeGroups.isEmpty) {
              return _buildEmptyState(colorScheme);
            }

            return ListView(
              padding: EdgeInsets.all(16),
              children: [
                StoriesHeader(),
                StoriesSection(),
                SizedBox(height: 16),
                ..._buildChatItems(chatDocs, activeGroups, colorScheme),
              ],
            );
          },
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

    // Por ahora, todos los chats se muestran en la sección "Otros Chats"
    // OPTIMIZACIÓN: No separar por categoría para evitar StreamBuilders innecesarios
    final otherChats = chatDocs;

    // Build groups section
    if (groups.isNotEmpty) {
      widgets.add(_buildGroupsHeader(colorScheme));
      for (final groupDoc in groups) {
        widgets.add(_buildGroupItem(groupDoc, colorScheme));
      }
      widgets.add(SizedBox(height: 8));
    }

    // Build other chats section
    if (otherChats.isNotEmpty) {
      widgets.add(_buildOtherChatsHeader(colorScheme));
      for (final chatDoc in otherChats) {
        widgets.add(_buildSingleChatItem(chatDoc, false, colorScheme));
      }
    }

    return widgets;
  }

  Widget _buildGroupsHeader(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4, top: 8),
      child: Text(
        'Grupos',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildGroupItem(QueryDocumentSnapshot groupDoc, ColorScheme colorScheme) {
    final groupId = groupDoc.id;
    final groupData = groupDoc.data() as Map<String, dynamic>;
    final groupName = groupData['name'] ?? 'Grupo';
    final unreadCount = groupData['unreadCount_${widget.childId}'] ?? 0;

    // Obtener el último mensaje para mostrar su estado
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('groups')
          .doc(groupId)
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

        return GroupChatListItem(
          groupId: groupId,
          groupName: groupName,
          memberCount: (groupData['members'] as List?)?.length ?? 0,
          lastMessage: groupData['lastMessage'] ?? 'Toca para abrir',
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
    try {
      final groupRef = _firestore.collection('groups').doc(groupId);
      final groupDoc = await groupRef.get();

      if (!groupDoc.exists) {
        throw Exception('El grupo no existe');
      }

      final groupData = groupDoc.data() as Map<String, dynamic>;
      final members = List<String>.from(groupData['members'] ?? []);

      // Eliminar al usuario de la lista de miembros
      members.remove(widget.childId);

      if (members.isEmpty) {
        // Si no quedan miembros, eliminar el grupo
        await groupRef.delete();
      } else {
        // Actualizar la lista de miembros
        await groupRef.update({'members': members});

        // Enviar mensaje de sistema que el usuario salió
        await groupRef.collection('messages').add({
          'type': 'system',
          'text': 'Ha salido del grupo',
          'senderId': widget.childId,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Has salido de "$groupName"'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
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

    // OPTIMIZACIÓN: Usar un solo StreamBuilder combinado para chat
    // Los datos del usuario y alias se cargarán solo cuando sea necesario
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('chats').doc(chatId).snapshots(),
      initialData: chatDoc,  // CRÍTICO: usar initialData para evitar flicker
      builder: (context, chatSnapshot) {
        final currentChatData = chatSnapshot.hasData
            ? (chatSnapshot.data!.data() as Map<String, dynamic>?) ?? chatData
            : chatData;

        final unreadCount = currentChatData['unreadCount_${widget.childId}'] ?? 0;
        final clearedAt = currentChatData['clearedAt_${widget.childId}'] as Timestamp?;
        final lastMessageTime = currentChatData['lastMessageTime'] as Timestamp?;
        final isChatCleared = clearedAt != null &&
            (lastMessageTime == null || clearedAt.compareTo(lastMessageTime) >= 0);
        final lastMessage = currentChatData['lastMessage'] ?? '';
        final timeString = isChatCleared ? '' : _chatsController.formatTime(currentChatData['lastMessageTime']);

        // OPTIMIZACIÓN: Cachear información del usuario para evitar consultas repetidas
        return FutureBuilder<DocumentSnapshot>(
          future: _firestore.collection('users').doc(otherUserId).get(),
          builder: (context, userSnapshot) {
            if (!userSnapshot.hasData) {
              // Mostrar placeholder mientras carga
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

            final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
            if (userData == null) return SizedBox.shrink();

            final realName = userData['name'] ?? 'Usuario';
            final isOnline = userData['isOnline'] ?? false;
            final photoURL = userData['photoURL'] as String?;

            // OPTIMIZACIÓN: Solo usar StreamBuilder para cosas que cambian frecuentemente
            // Alias y bloqueos no cambian tan seguido, usar FutureBuilder
            return _buildChatItem(
              chatId: chatId,
              userId: otherUserId,
              name: realName,  // Usar nombre real, no alias por ahora para simplificar
              lastMessage: lastMessage,
              time: timeString,
              unreadCount: unreadCount is int ? unreadCount : 0,
              isOnline: isOnline,
              photoURL: photoURL,
              isParent: isParent,
              isEmpty: isChatCleared,
              isBlocked: false,  // Simplificar por ahora
              colorScheme: colorScheme,
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
                            _buildParentChatHeader(colorScheme),
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
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 64, color: colorScheme.outlineVariant),
                    SizedBox(height: 16),
                    Text(
                      'No tienes conversaciones aún',
                      style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }


  Widget _buildParentChatHeader(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.shield, size: 16, color: Colors.green),
          ),
          SizedBox(width: 8),
          Text(
            'Familia',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOtherChatsHeader(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.people, size: 16, color: colorScheme.primary),
          ),
          SizedBox(width: 8),
          Text(
            'Contactos',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupChatItem({
    required String groupId,
    required String groupName,
    required int memberCount,
    required String lastMessage,
    required int messageCount,
    required ColorScheme colorScheme,
  }) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatScreen(
              groupId: groupId,
              groupName: groupName,
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.group, color: colorScheme.primary, size: 24),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          groupName,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    '$memberCount miembros',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colorScheme.outlineVariant),
          ],
        ),
      ),
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

        return Slidable(
          key: Key('chat_$chatId'),
          closeOnScroll: false,
          endActionPane: ActionPane(
            motion: const ScrollMotion(),
            extentRatio: 0.5,
            children: [
              // Botón Archivar
              CustomSlidableAction(
                onPressed: (context) async {
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
                backgroundColor: Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                child: Icon(Icons.archive_outlined, size: 32, color: Colors.white),
              ),
              // Botón Silenciar/Desilenciar
              CustomSlidableAction(
                onPressed: (context) async {
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
                backgroundColor: Color(0xFF7B68EE),
                foregroundColor: Colors.white,
                child: Icon(
                  isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                  size: 32,
                  color: Colors.white,
                ),
              ),
              // Botón Limpiar
              CustomSlidableAction(
                onPressed: (buttonContext) async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text('¿Limpiar chat?'),
                      content: Text(
                        '¿Estás seguro de que quieres eliminar todo el historial de mensajes de este chat?\n\n'
                        'Esta acción no se puede deshacer.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: Text('Cancelar'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          style: TextButton.styleFrom(foregroundColor: Colors.red),
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
                backgroundColor: Color(0xFFE74C3C),
                foregroundColor: Colors.white,
                child: Icon(Icons.delete_sweep_outlined, size: 32, color: Colors.white),
              ),
            ],
          ),
          child: GestureDetector(
            onTap: isRevoked ? null : () {
              print('Navegando al chat: $chatId con usuario: $userId');
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ChatDetailScreen(
                    contactId: userId,
                    contactName: name,
                    chatId: chatId,
                  ),
                ),
              );
            },
            child: Opacity(
              opacity: (isRevoked || isBlocked) ? 0.5 : 1.0,
              child: Container(
                margin: EdgeInsets.only(bottom: 8),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (isRevoked || isBlocked)
                      ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                      : (unreadCount > 0 ? colorScheme.primaryContainer.withValues(alpha: 0.3) : Colors.transparent),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundColor: colorScheme.primaryContainer,
                          backgroundImage: photoURL != null && photoURL.isNotEmpty ? NetworkImage(photoURL) : null,
                          child: photoURL == null || photoURL.isEmpty
                              ? Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                  style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
                                )
                              : null,
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
                                child: Text(
                                  name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    color: colorScheme.onSurface,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Indicador de chat silenciado
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
        );
      },
    );
  }

}
