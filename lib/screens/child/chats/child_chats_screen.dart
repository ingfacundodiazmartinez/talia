import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../controllers/child_chats_controller.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/emergency_button.dart';
import '../../../widgets/create_group_widget.dart';
import '../../../services/chat_service.dart';
import '../../../services/block_service.dart';
import '../../../screens/group_chat_screen.dart';
import '../../chat_detail_screen.dart';
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

  // Cache local para evitar rebuilds y mostrar datos inmediatamente
  List<Widget>? _cachedChatList;
  String? _lastSnapshotHash;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _chatsController = ChildChatsController(childId: widget.childId);
    _chatsController.addListener(_onControllerChanged);
    _chatsController.initialize();
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {
        // Limpiar cache cuando hay cambios
        _cachedChatList = null;
        _lastSnapshotHash = null;
      });
    }
  }

  @override
  void dispose() {
    _chatsController.removeListener(_onControllerChanged);
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
    // Si no está inicializado, mostrar loading
    if (!_chatsController.isInitialized) {
      return Center(child: CircularProgressIndicator());
    }

    // Si tenemos cache de la lista, mostrarla
    if (_cachedChatList != null) {
      return ListView(
        padding: EdgeInsets.all(16),
        children: _cachedChatList!,
      );
    }

    // Si no tenemos snapshot, mostrar loading
    if (_chatsController.cachedChatsSnapshot == null) {
      return Center(child: CircularProgressIndicator());
    }

    if (_chatsController.cachedChatsSnapshot!.docs.isEmpty) {
      return _buildEmptyState(colorScheme);
    }

    final filteredChats = _chatService.filterDeletedChats(_chatsController.cachedChatsSnapshot!);

    // Crear hash del snapshot para detectar cambios
    final snapshotHash = _chatsController.cachedChatsSnapshot!.docs.map((d) => d.id).join(',');

    // Solo reconstruir si los datos cambiaron
    final shouldRebuild = _lastSnapshotHash != snapshotHash;

    // Si no necesitamos reconstruir, mostrar loading mientras tanto
    if (!shouldRebuild && _cachedChatList != null) {
      return ListView(
        padding: EdgeInsets.all(16),
        children: _cachedChatList!,
      );
    }

    return FutureBuilder<List<Widget>>(
      future: _buildCategorizedChatList(filteredChats, colorScheme),
      builder: (context, chatListSnapshot) {
        // Si completó, actualizar cache
        if (chatListSnapshot.connectionState == ConnectionState.done &&
            chatListSnapshot.hasData) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _cachedChatList = chatListSnapshot.data;
                _lastSnapshotHash = snapshotHash;
              });
            }
          });
        }

        // Si tenemos cache previo, mostrarlo mientras carga
        if (_cachedChatList != null) {
          return ListView(
            padding: EdgeInsets.all(16),
            children: _cachedChatList!,
          );
        }

        // Si está cargando y tenemos datos del snapshot, usarlos
        if (chatListSnapshot.hasData) {
          return ListView(
            padding: EdgeInsets.all(16),
            children: chatListSnapshot.data!,
          );
        }

        // Fallback: spinner
        return Center(child: CircularProgressIndicator());
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

  Future<List<Widget>> _buildCategorizedChatList(
    List<QueryDocumentSnapshot> chatDocs,
    ColorScheme colorScheme,
  ) async {
    final List<Widget> widgets = [];
    final List<Map<String, dynamic>> parentChats = [];
    final List<Map<String, dynamic>> otherChats = [];

    // Agregar sección de historias al principio
    widgets.add(StoriesHeader());
    widgets.add(StoriesSection());
    widgets.add(SizedBox(height: 16));

    // Obtener y agregar grupos (con cache)
    try {
      final groups = await _chatsController.getGroups();

      if (groups.isNotEmpty) {
        widgets.add(
          Padding(
            padding: EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Grupos',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        );

        for (final group in groups) {
          widgets.add(_buildGroupChatItem(
            groupId: group.groupId,
            groupName: group.groupName,
            memberCount: group.memberCount,
            lastMessage: group.lastMessage,
            messageCount: group.messageCount,
            colorScheme: colorScheme,
          ));
        }

        widgets.add(SizedBox(height: 16));
      }
    } catch (e) {
      print('Error obteniendo grupos: $e');
    }

    // Obtener padres vinculados
    final parentId = await _chatsController.getLinkedParentId();

    // Separar chats de padres y otros
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != widget.childId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) continue;

      try {
        final userData = await _chatsController.getUserData(otherUserId);

        final chatInfo = {
          'chatDoc': chatDoc,
          'chatData': chatData,
          'otherUserId': otherUserId,
          'userData': userData,
        };

        if (otherUserId == parentId || (userData?['isParent'] == true)) {
          parentChats.add(chatInfo);
        } else {
          otherChats.add(chatInfo);
        }
      } catch (e) {
        print('Error obteniendo datos del usuario $otherUserId: $e');
      }
    }

    // Agregar chats de padres (o crear placeholder)
    if (parentId != null) {
      final existingParentChat = parentChats.any(
        (chat) => chat['otherUserId'] == parentId,
      );

      if (!existingParentChat) {
        try {
          final parentData = await _chatsController.getUserData(parentId);

          if (parentData != null) {
            final realName = parentData['name'] ?? 'Padre/Madre';

            widgets.add(_buildParentChatHeader(colorScheme));
            widgets.add(
              StreamBuilder<String>(
                stream: _chatsController.watchDisplayName(parentId, realName),
                initialData: realName,
                builder: (context, aliasSnapshot) {
                  final displayName = aliasSnapshot.data ?? realName;

                  return _buildChatItem(
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
                  );
                },
              ),
            );
          }
        } catch (e) {
          print('Error obteniendo datos del padre: $e');
        }
      }
    }

    // Agregar chats de padres existentes
    if (parentChats.isNotEmpty) {
      widgets.add(_buildParentChatHeader(colorScheme));

      parentChats.sort((a, b) {
        final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
        final bTime = b['chatData']['lastMessageTime'] as Timestamp?;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      for (final chat in parentChats) {
        final chatDoc = chat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = chat['chatData'] as Map<String, dynamic>;
        final userData = chat['userData'] as Map<String, dynamic>?;
        final otherUserId = chat['otherUserId'] as String;
        final realName = userData?['name'] ?? 'Usuario';

        final unreadCount = chatData['unreadCount_${widget.childId}'] ?? 0;
        widgets.add(
          StreamBuilder<String>(
            stream: _chatsController.watchDisplayName(otherUserId, realName),
            initialData: realName,
            builder: (context, aliasSnapshot) {
              final displayName = aliasSnapshot.data ?? realName;

              // Verificar si el chat fue limpiado y no hay mensajes nuevos
              final clearedAt = chatData['clearedAt_${widget.childId}'] as Timestamp?;
              final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;
              final isChatCleared = clearedAt != null &&
                  (lastMessageTime == null || clearedAt.compareTo(lastMessageTime) >= 0);

              return _buildChatItem(
                chatId: chatDoc.id,
                userId: otherUserId,
                name: displayName,
                lastMessage: isChatCleared ? 'Inicia una conversación...' : (chatData['lastMessage'] ?? ''),
                time: isChatCleared ? '' : _chatsController.formatTime(chatData['lastMessageTime']),
                unreadCount: unreadCount is int ? unreadCount : 0,
                isOnline: userData?['isOnline'] ?? false,
                photoURL: userData?['photoURL'],
                isParent: true,
                colorScheme: colorScheme,
              );
            },
          ),
        );
      }
    }

    // Agregar separador si hay chats de padres y otros chats
    if (widgets.isNotEmpty && otherChats.isNotEmpty) {
      widgets.add(SizedBox(height: 16));
      widgets.add(_buildOtherChatsHeader(colorScheme));
    }

    // Agregar otros chats
    if (otherChats.isNotEmpty) {
      if (widgets.isEmpty) {
        widgets.add(_buildOtherChatsHeader(colorScheme));
      }

      otherChats.sort((a, b) {
        final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
        final bTime = b['chatData']['lastMessageTime'] as Timestamp?;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      for (final chat in otherChats) {
        final chatDoc = chat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = chat['chatData'] as Map<String, dynamic>;
        final userData = chat['userData'] as Map<String, dynamic>?;
        final otherUserId = chat['otherUserId'] as String;
        final realName = userData?['name'] ?? 'Usuario';

        final unreadCount = chatData['unreadCount_${widget.childId}'] ?? 0;
        final chatId = chatDoc.id;

        widgets.add(
          StreamBuilder<bool>(
            stream: _chatsController.watchChatBlocked(chatId),
            builder: (context, blockSnapshot) {
              bool isRevoked = false;

              // Ignorar errores de permisos
              if (blockSnapshot.hasError) {
                // El chat no está bloqueado si hay error
                isRevoked = false;
              } else if (blockSnapshot.hasData) {
                isRevoked = blockSnapshot.data ?? false;
              }

              return StreamBuilder<bool>(
                stream: _blockService.isBlockedStream(otherUserId),
                initialData: false,
                builder: (context, blockedSnapshot) {
                  final isBlocked = blockedSnapshot.data ?? false;

                  return StreamBuilder<String>(
                    stream: _chatsController.watchDisplayName(otherUserId, realName),
                    initialData: realName,
                    builder: (context, aliasSnapshot) {
                      final displayName = aliasSnapshot.data ?? realName;

                      // Verificar si el chat fue limpiado y no hay mensajes nuevos
                      final clearedAt = chatData['clearedAt_${widget.childId}'] as Timestamp?;
                      final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;
                      final isChatCleared = clearedAt != null &&
                          (lastMessageTime == null || clearedAt.compareTo(lastMessageTime) >= 0);

                      return _buildChatItem(
                        chatId: chatId,
                        userId: otherUserId,
                        name: displayName,
                        lastMessage: isBlocked
                            ? '🔒 Contacto bloqueado'
                            : (isChatCleared
                                ? 'Inicia una conversación...'
                                : (chatData['lastMessage'] ?? '')),
                        time: isChatCleared ? '' : _chatsController.formatTime(chatData['lastMessageTime']),
                        unreadCount: isBlocked ? 0 : (unreadCount is int ? unreadCount : 0),
                        isOnline: userData?['isOnline'] ?? false,
                        photoURL: userData?['photoURL'],
                        isParent: false,
                        isRevoked: isRevoked,
                        isBlocked: isBlocked,
                        colorScheme: colorScheme,
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      }
    }

    return widgets;
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
    return GestureDetector(
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
                  Row(
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
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

}
