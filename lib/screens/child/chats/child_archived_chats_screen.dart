import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../controllers/child_archived_chats_controller.dart';
import '../../../groups/groups.dart'; // GroupChatScreenV2
import '../../../services/chats/chat_preferences_cache.dart';
import '../../../services/user_cache_service.dart';
import '../../../utils/chat_utils.dart';
import '../../chat_detail_screen.dart';

/// Pantalla de chats archivados para hijos
/// ✅ Arquitectura: Screen → Controller → Service
class ChildArchivedChatsScreen extends StatefulWidget {
  final String childId;

  const ChildArchivedChatsScreen({
    super.key,
    required this.childId,
  });

  @override
  State<ChildArchivedChatsScreen> createState() => _ChildArchivedChatsScreenState();
}

class _ChildArchivedChatsScreenState extends State<ChildArchivedChatsScreen> {
  late final ChildArchivedChatsController _controller;
  final ChatPreferencesCache _preferencesCache = ChatPreferencesCache();
  final UserCacheService _userCacheService = UserCacheService();

  /// Contador para forzar rebuild cuando cambia estado de archivado
  int _preferencesVersion = 0;

  @override
  void initState() {
    super.initState();
    _controller = ChildArchivedChatsController(childId: widget.childId);
    _preferencesCache.addListener(_onPreferencesChanged);
    _userCacheService.aliasChangedNotifier.addListener(_onAliasChanged);

    // ✅ Inicializar cache de usuarios y forzar rebuild cuando termine
    _userCacheService.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _onPreferencesChanged() {
    if (mounted) {
      setState(() => _preferencesVersion++);
    }
  }

  void _onAliasChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _preferencesCache.removeListener(_onPreferencesChanged);
    _userCacheService.aliasChangedNotifier.removeListener(_onAliasChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unarchive(String id) async {
    final success = await _controller.unarchive(id);
    if (mounted && !success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al desarchivar'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
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
              _buildHeader(colorScheme, isDarkMode),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: _buildContent(colorScheme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme, bool isDarkMode) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back,
              color: isDarkMode ? colorScheme.onSurface : Colors.white,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chats Archivados',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: isDarkMode ? colorScheme.onSurface : Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Mantén privados tus chats',
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
        ],
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      key: ValueKey('archived_chats_$_preferencesVersion'),
      stream: _controller.getChatsStream(),
      builder: (context, chatsSnapshot) {
        return StreamBuilder<QuerySnapshot>(
          key: ValueKey('archived_groups_$_preferencesVersion'),
          stream: _controller.getGroupsStream(),
          builder: (context, groupsSnapshot) {
            // Loading
            if (chatsSnapshot.connectionState == ConnectionState.waiting &&
                groupsSnapshot.connectionState == ConnectionState.waiting &&
                !chatsSnapshot.hasData && !groupsSnapshot.hasData) {
              return Center(child: CircularProgressIndicator());
            }

            // Error
            if (chatsSnapshot.hasError || groupsSnapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 64, color: Colors.red),
                    SizedBox(height: 16),
                    Text('Error al cargar chats archivados'),
                  ],
                ),
              );
            }

            // Filtrar archivados EN EL BUILDER
            final allChatDocs = chatsSnapshot.data?.docs ?? [];
            final allGroupDocs = groupsSnapshot.data?.docs ?? [];
            final archivedChats = _controller.filterArchivedChats(allChatDocs);
            final archivedGroups = _controller.filterArchivedGroups(allGroupDocs);

            // Empty state
            if (archivedChats.isEmpty && archivedGroups.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.archive_outlined, size: 64, color: colorScheme.outlineVariant),
                    SizedBox(height: 16),
                    Text(
                      'No hay chats archivados',
                      style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Desliza un chat o grupo hacia la izquierda para archivarlo',
                      style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }

            return ListView(
              padding: EdgeInsets.all(16),
              children: [
                // Grupos archivados
                if (archivedGroups.isNotEmpty) ...[
                  _buildSectionHeader('Grupos', archivedGroups.length),
                  ...archivedGroups.map((doc) => _buildArchivedGroupItem(doc, colorScheme)),
                  if (archivedChats.isNotEmpty) SizedBox(height: 16),
                ],
                // Chats 1-1 archivados
                if (archivedChats.isNotEmpty) ...[
                  _buildSectionHeader('Chats', archivedChats.length),
                  ...archivedChats.map((doc) => _buildArchivedChatItem(doc, colorScheme)),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, top: 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(width: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              count.toString(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArchivedChatItem(QueryDocumentSnapshot chatDoc, ColorScheme colorScheme) {
    final chatData = chatDoc.data() as Map<String, dynamic>;
    final chatId = chatDoc.id;
    final participants = List<String>.from(chatData['participants'] ?? []);
    final otherUserId = _controller.getOtherParticipant(participants);

    if (otherUserId.isEmpty) return SizedBox.shrink();

    return FutureBuilder<DocumentSnapshot>(
      future: _controller.getUserDocument(otherUserId),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) return SizedBox.shrink();

        final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
        if (userData == null) return SizedBox.shrink();

        final realName = userData['name'] ?? 'Usuario';
        final photoURL = userData['photoURL'] as String?;
        final isOnline = userData['isOnline'] ?? false;
        final phone = userData['phone'] as String?;

        // Usar el cache centralizado con prioridad: alias > agenda > Firestore
        final displayName = _userCacheService.getDisplayName(
          otherUserId,
          fallback: realName,
          phoneHint: phone,
        );

        return StreamBuilder<bool>(
          stream: _controller.isBlockedStream(otherUserId),
          initialData: false,
          builder: (context, blockedSnapshot) {
            final isBlocked = blockedSnapshot.data ?? false;
            final isCleared = _controller.isCleared(chatId);
            final lastMessage = chatData['lastMessage'] as String?;
            final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;

            return _buildChatTile(
              id: chatId,
              name: displayName,
              photoURL: photoURL,
              isOnline: isOnline,
              isBlocked: isBlocked,
              lastMessage: isBlocked
                  ? 'Contacto bloqueado'
                  : (isCleared ? 'Inicia una conversación...' : (lastMessage ?? '')),
              time: isCleared ? '' : ChatUtils.formatChatTime(lastMessageTime),
              colorScheme: colorScheme,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ChatDetailScreen(
                    chatId: chatId,
                    contactId: otherUserId,
                    contactName: displayName,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildArchivedGroupItem(QueryDocumentSnapshot groupDoc, ColorScheme colorScheme) {
    final groupData = groupDoc.data() as Map<String, dynamic>;
    final groupId = groupDoc.id;
    final groupName = groupData['name'] as String? ?? 'Grupo';
    final groupAvatar = groupData['avatar'] as String?;
    final lastMessage = groupData['lastMessage'] as String?;
    final lastActivity = groupData['lastActivity'] as Timestamp?;
    final isCleared = _controller.isCleared(groupId);

    return Slidable(
      key: Key('archived_group_$groupId'),
      closeOnScroll: false,
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        extentRatio: 0.25,
        children: [
          CustomSlidableAction(
            onPressed: (context) => _unarchive(groupId),
            backgroundColor: Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            child: Icon(Icons.unarchive, size: 32, color: Colors.white),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatScreenV2(groupId: groupId, groupName: groupName),
          ),
        ),
        child: Container(
          margin: EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: Color(0xFF4CAF50).withValues(alpha: 0.2),
                backgroundImage: groupAvatar != null && groupAvatar.isNotEmpty
                    ? CachedNetworkImageProvider(groupAvatar)
                    : null,
                child: groupAvatar == null || groupAvatar.isEmpty
                    ? Icon(Icons.group, color: Color(0xFF4CAF50), size: 28)
                    : null,
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
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      isCleared ? 'Inicia la conversación' : (lastMessage ?? 'Sin mensajes'),
                      style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  if (lastActivity != null && !isCleared)
                    Text(
                      ChatUtils.formatChatTime(lastActivity),
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  SizedBox(height: 4),
                  Icon(Icons.archive, size: 16, color: colorScheme.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatTile({
    required String id,
    required String name,
    required String? photoURL,
    required bool isOnline,
    required bool isBlocked,
    required String lastMessage,
    required String time,
    required ColorScheme colorScheme,
    required VoidCallback onTap,
  }) {
    return Slidable(
      key: Key('archived_$id'),
      closeOnScroll: false,
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        extentRatio: 0.25,
        children: [
          CustomSlidableAction(
            onPressed: (context) => _unarchive(id),
            backgroundColor: Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            child: Icon(Icons.unarchive, size: 32, color: Colors.white),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: isBlocked ? 0.5 : 1.0,
          child: Container(
            margin: EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isBlocked
                  ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 25,
                      backgroundColor: colorScheme.primaryContainer,
                      backgroundImage: photoURL != null && photoURL.isNotEmpty
                          ? CachedNetworkImageProvider(photoURL)
                          : null,
                      child: photoURL == null || photoURL.isEmpty
                          ? Text(
                              name.isNotEmpty ? name[0].toUpperCase() : 'U',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
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
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        lastMessage,
                        style: TextStyle(
                          fontSize: 13,
                          color: isBlocked
                              ? Colors.red.withValues(alpha: 0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  children: [
                    Text(
                      time,
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: 4),
                    Icon(Icons.archive, size: 16, color: colorScheme.primary),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
