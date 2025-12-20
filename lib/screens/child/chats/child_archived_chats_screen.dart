import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../models/chat.dart';
import '../../../services/chats/chat_services.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/block_service.dart';
import '../../../utils/chat_utils.dart';
import '../../chat_detail_screen.dart';

/// Pantalla de chats archivados para hijos
/// ✅ CORREGIDO: Usa Hive (ChatPreferencesCache) en vez de Firestore
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
  final ListChatsService _listChatsService = ListChatsService();
  final UnarchiveChatService _unarchiveService = UnarchiveChatService();
  final ChatPreferencesCache _preferencesCache = ChatPreferencesCache();
  final ContactAliasService _aliasService = ContactAliasService();
  final BlockService _blockService = BlockService();

  StreamSubscription? _chatsSubscription;
  final _archivedChatsController = StreamController<List<Chat>>.broadcast();

  @override
  void initState() {
    super.initState();
    _startListeningChats();
  }

  @override
  void dispose() {
    _chatsSubscription?.cancel();
    _archivedChatsController.close();
    super.dispose();
  }

  void _startListeningChats() {
    _chatsSubscription?.cancel();

    _chatsSubscription = _listChatsService
        .call(includeArchived: true)
        .listen(
          (chats) {
            // Filtrar solo los archivados usando el cache de Hive
            final archived = chats.where((c) => _preferencesCache.isArchived(c.id)).toList();
            _archivedChatsController.add(archived);
          },
          onError: (e) {
            _archivedChatsController.addError(e);
          },
        );
  }

  Future<void> _unarchiveChat(String chatId) async {
    final result = await _unarchiveService.call(chatId: chatId);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.success ? 'Chat desarchivado' : 'Error al desarchivar chat',
          ),
          backgroundColor: result.success ? Colors.green : Colors.red,
        ),
      );

      if (result.success) {
        setState(() {}); // Refrescar UI
        _startListeningChats(); // Refrescar stream
      }
    }
  }

  String _getOtherParticipant(List<String> participants) {
    return participants.firstWhere(
      (id) => id != widget.childId,
      orElse: () => '',
    );
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
                : [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
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
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: StreamBuilder<List<Chat>>(
                    stream: _archivedChatsController.stream,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Center(child: CircularProgressIndicator());
                      }

                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 64,
                                color: Colors.red,
                              ),
                              SizedBox(height: 16),
                              Text(
                                'Error al cargar chats archivados',
                                style: TextStyle(fontSize: 16),
                              ),
                            ],
                          ),
                        );
                      }

                      final archivedChats = snapshot.data ?? [];

                      if (archivedChats.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.archive_outlined,
                                size: 64,
                                color: colorScheme.outlineVariant,
                              ),
                              SizedBox(height: 16),
                              Text(
                                'No hay chats archivados',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Desliza un chat hacia la izquierda para archivarlo',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: EdgeInsets.all(16),
                        itemCount: archivedChats.length,
                        itemBuilder: (context, index) {
                          final chat = archivedChats[index];
                          final otherUserId = _getOtherParticipant(chat.participants);

                          if (otherUserId.isEmpty) return SizedBox.shrink();

                          return FutureBuilder<DocumentSnapshot>(
                            future: FirebaseFirestore.instance
                                .collection('users')
                                .doc(otherUserId)
                                .get(),
                            builder: (context, userSnapshot) {
                              if (!userSnapshot.hasData) return SizedBox.shrink();

                              final userData = userSnapshot.data!.data()
                                  as Map<String, dynamic>?;
                              if (userData == null) return SizedBox.shrink();

                              final realName = userData['name'] ?? 'Usuario';

                              return StreamBuilder<String>(
                                stream: _aliasService.watchDisplayName(
                                  otherUserId,
                                  realName,
                                ),
                                initialData: realName,
                                builder: (context, aliasSnapshot) {
                                  final displayName = aliasSnapshot.data ?? realName;

                                  return StreamBuilder<bool>(
                                    stream: _blockService.isBlockedStream(otherUserId),
                                    initialData: false,
                                    builder: (context, blockedSnapshot) {
                                      final isBlocked = blockedSnapshot.data ?? false;
                                      final isChatCleared = _preferencesCache.getClearedAt(chat.id) != null;

                                      return _buildArchivedChatItem(
                                        chatId: chat.id,
                                        userId: otherUserId,
                                        name: displayName,
                                        lastMessage: isBlocked
                                            ? 'Contacto bloqueado'
                                            : (isChatCleared
                                                ? 'Inicia una conversación...'
                                                : (chat.lastMessage ?? '')),
                                        time: isChatCleared
                                            ? ''
                                            : ChatUtils.formatChatTime(
                                                chat.lastMessageTime != null
                                                    ? Timestamp.fromDate(chat.lastMessageTime!)
                                                    : null,
                                              ),
                                        isOnline: userData['isOnline'] ?? false,
                                        photoURL: userData['photoURL'],
                                        isBlocked: isBlocked,
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArchivedChatItem({
    required String chatId,
    required String userId,
    required String name,
    required String lastMessage,
    required String time,
    required bool isOnline,
    String? photoURL,
    required bool isBlocked,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Slidable(
      key: Key('archived_$chatId'),
      closeOnScroll: false,
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        extentRatio: 0.25,
        children: [
          CustomSlidableAction(
            onPressed: (context) => _unarchiveChat(chatId),
            backgroundColor: Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            child: Icon(Icons.unarchive, size: 32, color: Colors.white),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ChatDetailScreen(
                chatId: chatId,
                contactId: userId,
                contactName: name,
              ),
            ),
          );
        },
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
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
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
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: 4),
                  Icon(
                    Icons.archive,
                    size: 16,
                    color: colorScheme.primary,
                  ),
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
