import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../../services/typing_indicator_service.dart';
import '../../../../services/nudge_service.dart';
import '../../../../services/block_service.dart';
import '../../../../controllers/chat_list_item_controller.dart';
import '../../../../models/chat_message.dart';
import '../../../../models/nudge.dart';
import '../../../../widgets/message_status_indicator.dart';
import '../../../../widgets/synced_user_widgets.dart';
import '../../../../widgets/nudge/nudge_type_selector.dart';
import '../../../../widgets/nudge/nudge_tutorial.dart';
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
  final VoidCallback? onMuted;
  final VoidCallback? onCleared;
  // Campos para indicador de estado del último mensaje
  final String? lastMessageSenderId;
  final MessageStatus? lastMessageStatus;
  final ModerationStatus? lastMessageModerationStatus;
  final String? lastMessageType; // ✅ Para estilo cursiva en mensajes eliminados

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
    this.onMuted,
    this.onCleared,
    this.lastMessageSenderId,
    this.lastMessageStatus,
    this.lastMessageModerationStatus,
    this.lastMessageType,
  });

  @override
  State<ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<ChatListItem> {
  late final ChatListItemController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ChatListItemController(
      chatId: widget.chatId,
      userId: widget.userId,
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _archiveChat() async {
    final success = await _controller.archiveChat();

    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al archivar chat'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    widget.onArchived?.call();

    // Snackbar con acción "Deshacer"
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Chat archivado'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () async {
            final reverted = await _controller.unarchiveChat();
            if (reverted && mounted) {
              widget.onArchived?.call();
            }
          },
        ),
      ),
    );
  }

  Future<void> _muteChat() async {
    final success = await _controller.muteChat();

    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al silenciar chat'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        widget.onMuted?.call();
      }
    }
  }

  Future<void> _unmuteChat() async {
    final success = await _controller.unmuteChat();

    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al desilenciar chat'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        widget.onMuted?.call();
      }
    }
  }

  /// Mostrar selector de tipo de nudge
  void _showNudgeSelector(BuildContext context) {
    // Feedback haptico al activar
    HapticFeedback.mediumImpact();

    showNudgeSelector(
      context: context,
      recipientId: widget.userId,
      recipientName: widget.name,
      onSelect: (type) => _sendNudge(type),
      onTutorialTap: () {
        Navigator.pop(context); // Cerrar bottom sheet
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => NudgeTutorial(),
            fullscreenDialog: true,
          ),
        );
      },
    );
  }

  /// Enviar nudge del tipo seleccionado
  Future<void> _sendNudge(NudgeType type) async {
    final success = await NudgeService().sendNudge(
      toUserId: widget.userId,
      toUserName: widget.name,
      type: type,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '${type.emoji} Enviado'
                : 'No se pudo enviar',
          ),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
          backgroundColor: success ? null : Colors.red,
        ),
      );
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
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<bool>(
      stream: _controller.watchChatMuted(),
      initialData: false,
      builder: (context, muteSnapshot) {
        final isMuted = muteSnapshot.data ?? false;

        return Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: ClipRect(
            child: Container(
              color: colorScheme.primary,
              child: Slidable(
            key: Key('chat_${widget.chatId}'),
            // closeOnScroll: false mantiene el swipe abierto
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
                        Builder(
                          builder: (slidableContext) => _buildSlideButton(
                            icon: Icons.archive_outlined,
                            label: 'Archivar',
                            onTap: () async {
                              Slidable.of(slidableContext)?.close();
                              await _archiveChat();
                            },
                          ),
                        ),
                        Builder(
                          builder: (slidableContext) => _buildSlideButton(
                            icon: isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                            label: isMuted ? 'Activar' : 'Silenciar',
                            onTap: () async {
                              // Cerrar el swipe primero
                              Slidable.of(slidableContext)?.close();
                              if (isMuted) {
                                await _unmuteChat();
                              } else {
                                await _muteChat();
                              }
                            },
                          ),
                        ),
                        Builder(
                          builder: (slidableContext) => _buildSlideButton(
                            icon: Icons.delete_outline_rounded,
                            label: 'Limpiar',
                            onTap: () async {
                              // Cerrar el swipe primero
                              Slidable.of(slidableContext)?.close();

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
                                final success = await _controller.clearChat();

                                if (mounted) {
                                  if (!success) {
                                    // ignore: use_build_context_synchronously
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Error al limpiar chat'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  } else {
                                    widget.onCleared?.call();
                                  }
                                }
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
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
            onLongPress: widget.isBlocked ? null : () => _showNudgeSelector(context),
            child: Opacity(
              opacity: widget.isBlocked ? 0.5 : 1.0,
              child: Container(
                padding: EdgeInsets.all(12),
                color: widget.isBlocked
                    ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
                    : colorScheme.surface,
                child: Row(
                  children: [
                    Stack(
                      children: [
                        // Si el contacto bloqueó al usuario actual, no se muestra su foto.
                        StreamBuilder<bool>(
                          stream: BlockService().shouldHidePhotoOfStream(widget.userId),
                          initialData: false,
                          builder: (context, hideSnap) {
                            final hidePhoto = hideSnap.data ?? false;
                            final effectivePhoto = hidePhoto ? null : widget.photoURL;
                            return CircleAvatar(
                          radius: 28,
                          backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                          child: effectivePhoto != null && effectivePhoto.isNotEmpty
                              ? ClipOval(
                                  child: CachedNetworkImage(
                                    imageUrl: effectivePhoto,
                                    width: 56,
                                    height: 56,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => Text(
                                      widget.name.isNotEmpty ? widget.name[0].toUpperCase() : 'H',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                    errorWidget: (context, url, error) => Text(
                                      widget.name.isNotEmpty ? widget.name[0].toUpperCase() : 'H',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                )
                              : Text(
                                  widget.name.isNotEmpty ? widget.name[0].toUpperCase() : 'H',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                ),
                            );
                          },
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
                            stream: _controller.getUserOnlineStatusStream(),
                            builder: (context, userSnapshot) {
                              final isOnline = userSnapshot.hasData && userSnapshot.data != null
                                  ? _controller.isUserOnline(userSnapshot.data!)
                                  : false;

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
                                child: SyncedUserName(
                                  userId: widget.userId,
                                  fallbackName: widget.name,
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
                                stream: _controller.watchChatMuted(),
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
                          StreamBuilder<UserActivityState>(
                            stream: TypingIndicatorService().watchOtherUserActivity(
                              widget.chatId,
                              widget.userId,
                            ),
                            initialData: UserActivityState.none,
                            builder: (context, activitySnapshot) {
                              final activityState = activitySnapshot.data ?? UserActivityState.none;
                              final isTyping = activityState == UserActivityState.typing;
                              final isRecording = activityState == UserActivityState.recording;

                              if ((isTyping || isRecording) && !widget.isBlocked) {
                                return Row(
                                  children: [
                                    if (isRecording)
                                      Icon(
                                        Icons.mic,
                                        size: 14,
                                        color: colorScheme.primary,
                                      )
                                    else
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
                                      isRecording ? 'Grabando audio...' : 'Escribiendo...',
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
                              final isOwnMessage = _controller.isOwnMessage(widget.lastMessageSenderId);

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
                                        // ✅ Cursiva para: vacío, bloqueado, o mensaje eliminado
                                        fontStyle: (widget.isEmpty || widget.isBlocked || widget.lastMessageType == 'deleted')
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
        ),
        ),
        ),
        );
      },
    );
  }
}
