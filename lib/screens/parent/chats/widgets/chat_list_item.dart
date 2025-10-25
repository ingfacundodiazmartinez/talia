import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../../services/typing_indicator_service.dart';
import '../../../../services/chat_archive_service.dart';
import '../../../../services/chat_mute_service.dart';
import '../../../../services/chat_clear_service.dart';
import '../../../../services/message_cache_service.dart';
import '../../../../models/chat_message.dart';
import '../../../../widgets/message_status_indicator.dart';
import '../../../chat_detail_screen.dart';

class ChatListItem extends StatefulWidget {
  final String chatId;
  final String userId;
  final String name;
  final String lastMessage;
  final String time;
  final int unreadCount;
  final String? photoURL;
  final bool isEmpty;
  final bool isBlocked;
  final VoidCallback? onArchived;
  // Campos para indicador de estado del último mensaje
  final String? lastMessageSenderId;
  final MessageStatus? lastMessageStatus;
  final ModerationStatus? lastMessageModerationStatus;

  const ChatListItem({
    super.key,
    required this.chatId,
    required this.userId,
    required this.name,
    required this.lastMessage,
    required this.time,
    required this.unreadCount,
    this.photoURL,
    this.isEmpty = false,
    this.isBlocked = false,
    this.onArchived,
    this.lastMessageSenderId,
    this.lastMessageStatus,
    this.lastMessageModerationStatus,
  });

  @override
  State<ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<ChatListItem> {
  final ChatArchiveService _archiveService = ChatArchiveService();
  final ChatMuteService _muteService = ChatMuteService();
  final ChatClearService _clearService = ChatClearService();
  final MessageCacheService _cacheService = MessageCacheService();

  Future<void> _archiveChat() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    final success = await _archiveService.archiveChat(
      chatId: widget.chatId,
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
      if (success) {
        widget.onArchived?.call();
      }
    }
  }

  Future<void> _muteChat() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    final success = await _muteService.muteChat(
      chatId: widget.chatId,
      userId: currentUserId,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? 'Chat silenciado' : 'Error al silenciar chat',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _unmuteChat() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    final success = await _muteService.unmuteChat(
      chatId: widget.chatId,
      userId: currentUserId,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? 'Chat desilenciado' : 'Error al desilenciar chat',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    return StreamBuilder<bool>(
      stream: _muteService.watchChatMuted(
        chatId: widget.chatId,
        userId: currentUserId,
      ),
      initialData: false,
      builder: (context, muteSnapshot) {
        final isMuted = muteSnapshot.data ?? false;

        return Slidable(
          key: Key('chat_${widget.chatId}'),
          // closeOnScroll: false mantiene el swipe abierto
          closeOnScroll: false,
          endActionPane: ActionPane(
            // ScrollMotion mantiene los botones visibles sin cerrarse automáticamente
            motion: const ScrollMotion(),
            extentRatio: 0.5, // Más espacio para 3 botones
            children: [
              // Botón Archivar - Azul suave
              CustomSlidableAction(
                onPressed: (context) => _archiveChat(),
                backgroundColor: Color(0xFF4A90E2), // Azul suave
                foregroundColor: Colors.white,
                child: Icon(Icons.archive_outlined, size: 32, color: Colors.white),
              ),
              // Botón Silenciar - Morado del tema
              CustomSlidableAction(
                onPressed: (context) {
                  if (isMuted) {
                    _unmuteChat();
                  } else {
                    _muteChat();
                  }
                },
                backgroundColor: Color(0xFF7B68EE), // Morado medio
                foregroundColor: Colors.white,
                child: Icon(
                  isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                  size: 32,
                  color: Colors.white,
                ),
              ),
              // Botón Limpiar - Rojo/Rosado suave
              CustomSlidableAction(
                onPressed: (buttonContext) async {
                  final currentUserId = FirebaseAuth.instance.currentUser?.uid;
                  if (currentUserId == null) return;

                  final confirmed = await showDialog<bool>(
                    context: context, // Use widget's context for dialog
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
                      chatId: widget.chatId,
                      userId: currentUserId,
                    );

                    // Limpiar también el cache local
                    if (success) {
                      await _cacheService.clearChat(widget.chatId);
                      print('✅ Cache local limpiado para chat ${widget.chatId}');
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
                backgroundColor: Color(0xFFE74C3C), // Rojo más suave
                foregroundColor: Colors.white,
                child: Icon(Icons.delete_sweep_outlined, size: 32, color: Colors.white),
              ),
            ],
          ),
          child: GestureDetector(
            onTap: () async {
              // MaterialPageRoute evita parpadeo Y habilita swipe-to-go-back en iOS
              // Usar Navigator del tab (sin rootNavigator) para que pop() funcione correctamente
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ChatDetailScreen(
                    chatId: widget.chatId,
                    contactId: widget.userId,
                    contactName: widget.name,
                  ),
                ),
              );
            },
            child: Opacity(
              opacity: widget.isBlocked ? 0.5 : 1.0,
              child: Container(
                margin: EdgeInsets.only(bottom: 8),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.isBlocked
                      ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
                      : (widget.unreadCount > 0
                          ? colorScheme.primary.withValues(alpha: 0.1)
                          : Colors.transparent),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                          backgroundImage: widget.photoURL != null && widget.photoURL!.isNotEmpty
                              ? CachedNetworkImageProvider(widget.photoURL!)
                              : null,
                          child: widget.photoURL == null || widget.photoURL!.isEmpty
                              ? Text(
                                  widget.name.isNotEmpty ? widget.name[0].toUpperCase() : 'H',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                )
                              : null,
                        ),
                        if (widget.isBlocked)
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
                        else
                          // StreamBuilder para escuchar el estado online en tiempo real
                          StreamBuilder<DocumentSnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('users')
                                .doc(widget.userId)
                                .snapshots(),
                            builder: (context, userSnapshot) {
                              bool isOnline = false;
                              if (userSnapshot.hasData && userSnapshot.data!.data() != null) {
                                final userData = userSnapshot.data!.data() as Map<String, dynamic>;
                                isOnline = userData['isOnline'] ?? false;
                              }

                              if (!isOnline) {
                                return SizedBox.shrink();
                              }

                              return Positioned(
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
                              );
                            },
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
                                  widget.name,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: widget.isBlocked
                                        ? colorScheme.onSurface.withValues(alpha: 0.6)
                                        : colorScheme.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Indicador de chat silenciado
                              StreamBuilder<bool>(
                                stream: _muteService.watchChatMuted(
                                  chatId: widget.chatId,
                                  userId: FirebaseAuth.instance.currentUser?.uid ?? '',
                                ),
                                initialData: false,
                                builder: (context, muteSnapshot) {
                                  final isMuted = muteSnapshot.data ?? false;
                                  if (isMuted) {
                                    return Padding(
                                      padding: EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Icons.notifications_off,
                                        size: 14,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    );
                                  }
                                  return SizedBox.shrink();
                                },
                              ),
                            ],
                          ),
                          SizedBox(height: 4),
                          StreamBuilder<bool>(
                            stream: TypingIndicatorService().watchOtherUserTyping(
                              widget.chatId,
                              widget.userId,
                            ),
                            builder: (context, typingSnapshot) {
                              final isTyping = typingSnapshot.data ?? false;

                              if (isTyping && !widget.isBlocked) {
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
                                        fontSize: 14,
                                        color: colorScheme.primary,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                );
                              }

                              // Mostrar lastMessage con indicador de estado (si es mensaje propio)
                              final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
                              final isOwnMessage = widget.lastMessageSenderId == currentUserId;

                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Indicador de estado (solo para mensajes propios) - ANTES del texto
                                  if (isOwnMessage && widget.lastMessageStatus != null) ...[
                                    MessageStatusIndicator(
                                      status: widget.lastMessageStatus!,
                                      moderationStatus: widget.lastMessageModerationStatus,
                                      size: 12,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      widget.lastMessage,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: widget.isBlocked
                                            ? Colors.red.withValues(alpha: 0.7)
                                            : colorScheme.onSurfaceVariant,
                                        fontStyle: (widget.isEmpty || widget.isBlocked)
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    Column(
                      children: [
                        Text(
                          widget.time,
                          style: TextStyle(
                            fontSize: 12,
                            color: widget.unreadCount > 0
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (widget.unreadCount > 0) SizedBox(height: 4),
                        if (widget.unreadCount > 0)
                          Container(
                            padding: EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              widget.unreadCount.toString(),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
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
