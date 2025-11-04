import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../controllers/parent_archived_chats_controller.dart';
import '../../../utils/chat_utils.dart';
import '../../chat_detail_screen.dart';
import '../../../theme_service.dart';

/// Pantalla de chats archivados para padres
class ParentArchivedChatsScreen extends StatefulWidget {
  const ParentArchivedChatsScreen({super.key});

  @override
  State<ParentArchivedChatsScreen> createState() => _ParentArchivedChatsScreenState();
}

class _ParentArchivedChatsScreenState extends State<ParentArchivedChatsScreen> {
  late final ParentArchivedChatsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ParentArchivedChatsController();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unarchiveChat(String chatId) async {
    final success = await _controller.unarchiveChat(chatId);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? 'Chat desarchivado' : 'Error al desarchivar chat',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.isUserAuthenticated) {
      return Scaffold(
        body: Center(
          child: Text('Error: Usuario no autenticado'),
        ),
      );
    }

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
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Chats Archivados 📦',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Mantén privados tus chats',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.9),
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
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _controller.getArchivedChatsStream(),
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

                      final archivedChatsDocs = snapshot.data?.docs ?? [];
                      final archivedChats = _controller.sortChatsByLastActivity(archivedChatsDocs);

                      if (archivedChats.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.archive_outlined,
                                size: 64,
                                color: Theme.of(context).colorScheme.outlineVariant,
                              ),
                              SizedBox(height: 16),
                              Text(
                                'No hay chats archivados',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Mantén presionado un chat para archivarlo',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                          final chatDoc = archivedChats[index];
                          final chatData = chatDoc.data() as Map<String, dynamic>;
                          final participants = List<String>.from(
                            chatData['participants'] ?? [],
                          );
                          final otherUserId = _controller.getOtherParticipant(participants);

                          if (otherUserId.isEmpty) return SizedBox.shrink();

                          return FutureBuilder<DocumentSnapshot>(
                            future: _controller.getUserDocument(otherUserId),
                            builder: (context, userSnapshot) {
                              if (!userSnapshot.hasData) return SizedBox.shrink();

                              final formattedUserData = _controller.formatUserData(userSnapshot.data!);
                              final realName = formattedUserData['realName'];

                              return StreamBuilder<String>(
                                stream: _controller.watchDisplayName(
                                  otherUserId,
                                  realName,
                                ),
                                initialData: realName,
                                builder: (context, aliasSnapshot) {
                                  final displayName = aliasSnapshot.data ?? realName;

                                  return StreamBuilder<bool>(
                                    stream: _controller.isBlockedStream(otherUserId),
                                    initialData: false,
                                    builder: (context, blockedSnapshot) {
                                      final isBlocked = blockedSnapshot.data ?? false;

                                      // Verificar si el chat fue limpiado y no hay mensajes nuevos
                                      final isChatCleared = _controller.isChatCleared(chatData);

                                      return _buildArchivedChatItem(
                                        chatId: chatDoc.id,
                                        userId: otherUserId,
                                        name: displayName,
                                        lastMessage: isBlocked
                                            ? '🔒 Contacto bloqueado'
                                            : (isChatCleared
                                                ? 'Inicia una conversación...'
                                                : (chatData['lastMessage'] ?? '')),
                                        time: isChatCleared
                                            ? ''
                                            : ChatUtils.formatChatTime(
                                                chatData['lastMessageTime'],
                                              ),
                                        isOnline: formattedUserData['isOnline'],
                                        photoURL: formattedUserData['photoURL'],
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
          // Botón Desarchivar - Azul suave
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
          // MaterialPageRoute evita parpadeo Y habilita swipe-to-go-back en iOS
          // El bottom nav se oculta automáticamente por el NavigatorObserver del shell
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
                    radius: 28,
                    backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                    backgroundImage: photoURL != null && photoURL.isNotEmpty
                        ? NetworkImage(photoURL)
                        : null,
                    child: photoURL == null || photoURL.isEmpty
                        ? Text(
                            name.isNotEmpty ? name[0].toUpperCase() : 'H',
                            style: TextStyle(
                              fontSize: 20,
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
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isBlocked
                            ? colorScheme.onSurface.withValues(alpha: 0.6)
                            : colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      lastMessage,
                      style: TextStyle(
                        fontSize: 14,
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
