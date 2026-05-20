import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../../groups/groups.dart'; // Groups V2
import '../../../../models/chat_message.dart';
import '../../../../widgets/message_status_indicator.dart';
import '../../../../controllers/chat_list_item_controller.dart';
import '../../../../services/user_cache_service.dart';

class GroupChatListItem extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String lastMessage;
  final int memberCount;
  final int messageCount;
  final String? groupImageUrl;
  final int unreadCount;
  final VoidCallback? onLeaveGroup;
  final VoidCallback? onArchived;
  final VoidCallback? onMuted;
  final VoidCallback? onCleared;
  // Campos para indicador de estado del último mensaje
  final String? lastMessageSenderId;
  final MessageStatus? lastMessageStatus;
  final ModerationStatus? lastMessageModerationStatus;
  final String? lastMessageType; // ✅ Para estilo cursiva en mensajes eliminados
  final String? timeString;
  /// Si el usuario está pendiente de aprobación para este grupo
  final bool isPending;

  const GroupChatListItem({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.lastMessage,
    required this.memberCount,
    required this.messageCount,
    this.groupImageUrl,
    this.unreadCount = 0,
    this.onLeaveGroup,
    this.onArchived,
    this.onMuted,
    this.onCleared,
    this.lastMessageSenderId,
    this.lastMessageStatus,
    this.lastMessageModerationStatus,
    this.lastMessageType,
    this.timeString,
    this.isPending = false,
  });

  @override
  State<GroupChatListItem> createState() => _GroupChatListItemState();
}

class _GroupChatListItemState extends State<GroupChatListItem> {
  // Reutilizar el mismo controller de chats 1-1 (los servicios son genéricos)
  late final ChatListItemController _controller;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  void initState() {
    super.initState();
    // Usar groupId como chatId - los servicios son genéricos
    _controller = ChatListItemController(
      chatId: widget.groupId,
      userId: '', // No aplica para grupos
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _archiveGroup() async {
    final success = await _controller.archiveChat();
    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al archivar grupo'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    widget.onArchived?.call();

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Grupo archivado'),
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

  Future<void> _muteGroup() async {
    final success = await _controller.muteChat();
    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al silenciar grupo'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        widget.onMuted?.call();
      }
    }
  }

  Future<void> _unmuteGroup() async {
    final success = await _controller.unmuteChat();
    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al desilenciar grupo'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        widget.onMuted?.call();
      }
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

  void _showPendingInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            Icon(Icons.hourglass_empty_rounded, color: Colors.amber),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Pendiente de aprobación',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Text(
          'Tu solicitud para unirte a "${widget.groupName}" está pendiente de aprobación por el administrador del grupo.\n\n'
          'Podrás acceder al chat una vez que sea aprobada.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingGroupItem(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _showPendingInfoDialog(context),
        child: Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              // Avatar igual que los otros grupos
              Stack(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: colorScheme.primaryContainer.withValues(alpha: 0.5),
                    backgroundImage: widget.groupImageUrl != null && widget.groupImageUrl!.isNotEmpty
                        ? CachedNetworkImageProvider(widget.groupImageUrl!)
                        : null,
                    child: widget.groupImageUrl == null || widget.groupImageUrl!.isEmpty
                        ? Icon(
                            Icons.group,
                            color: colorScheme.primary.withValues(alpha: 0.7),
                            size: 28,
                          )
                        : null,
                  ),
                  // Pequeño badge de reloj en la esquina
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.schedule_rounded,
                        color: colorScheme.onSurfaceVariant,
                        size: 14,
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
                    // Nombre del grupo
                    Text(
                      widget.groupName,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 4),
                    // Subtítulo sutil
                    Text(
                      'Esperando aprobación',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Icono de info sutil
              Icon(
                Icons.info_outline_rounded,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Si está pendiente, mostrar versión simplificada sin Slidable
    if (widget.isPending) {
      return _buildPendingGroupItem(context);
    }

    final userCacheService = UserCacheService();
    final colorScheme = Theme.of(context).colorScheme;

    // Usar StreamBuilder para estado de mute (igual que ChatListItem)
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
                key: Key('group_${widget.groupId}'),
                closeOnScroll: false,
                endActionPane: ActionPane(
                  motion: const BehindMotion(),
                  extentRatio: 0.65, // 4 botones
                  openThreshold: 0.1,
                  closeThreshold: 0.1,
                  children: [
                    Expanded(
                      child: Container(
                        color: colorScheme.primary,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // Archivar
                            Builder(
                              builder: (slidableContext) => _buildSlideButton(
                                icon: Icons.archive_outlined,
                                label: 'Archivar',
                                onTap: () async {
                                  Slidable.of(slidableContext)?.close();
                                  await _archiveGroup();
                                },
                              ),
                            ),
                            // Silenciar/Activar
                            Builder(
                              builder: (slidableContext) => _buildSlideButton(
                                icon: isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                                label: isMuted ? 'Activar' : 'Silenciar',
                                onTap: () async {
                                  Slidable.of(slidableContext)?.close();
                                  if (isMuted) {
                                    await _unmuteGroup();
                                  } else {
                                    await _muteGroup();
                                  }
                                },
                              ),
                            ),
                            // Limpiar
                            Builder(
                              builder: (slidableContext) => _buildSlideButton(
                                icon: Icons.delete_outline_rounded,
                                label: 'Limpiar',
                                onTap: () async {
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
                                          Text('¿Limpiar grupo?'),
                                        ],
                                      ),
                                      content: Text(
                                        '¿Estás seguro de que quieres ocultar todo el historial de mensajes de este grupo?\n\n'
                                        'Los mensajes seguirán visibles para los demás miembros.',
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
                                            content: Text('Error al limpiar grupo'),
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
                            // Salir
                            Builder(
                              builder: (slidableContext) => _buildSlideButton(
                                icon: Icons.exit_to_app_outlined,
                                label: 'Salir',
                                onTap: () {
                                  Slidable.of(slidableContext)?.close();
                                  widget.onLeaveGroup?.call();
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
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => GroupChatScreenV2(
                          groupId: widget.groupId,
                          groupName: widget.groupName,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: EdgeInsets.all(12),
                    color: colorScheme.surface,
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: Color(0xFF4CAF50).withValues(alpha: 0.2),
                          backgroundImage: widget.groupImageUrl != null && widget.groupImageUrl!.isNotEmpty
                              ? CachedNetworkImageProvider(widget.groupImageUrl!)
                              : null,
                          child: widget.groupImageUrl == null || widget.groupImageUrl!.isEmpty
                              ? Icon(
                                  Icons.group,
                                  color: Color(0xFF4CAF50),
                                  size: 28,
                                )
                              : null,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Primera línea: Nombre + icono mute + badge miembros + tiempo
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.groupName,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: colorScheme.onSurface,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  // Indicador de grupo silenciado
                                  if (isMuted)
                                    Padding(
                                      padding: EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Icons.notifications_off,
                                        size: 14,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  if (widget.timeString != null && widget.timeString!.isNotEmpty) ...[
                                    SizedBox(width: 8),
                                    Text(
                                      widget.timeString!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              SizedBox(height: 4),
                              StreamBuilder<QuerySnapshot>(
                                stream: _firestore
                                    .collection('groups_v2')
                                    .doc(widget.groupId)
                                    .collection('typing')
                                    .snapshots(),
                                builder: (context, typingSnapshot) {
                                  // Si hay error de permisos, mostrar el último mensaje
                                  if (typingSnapshot.hasError) {
                                    final currentUserId = _auth.currentUser?.uid ?? '';
                                    final isOwnMessage = widget.lastMessageSenderId == currentUserId;

                                    return Row(
                                      children: [
                                        if (isOwnMessage && widget.lastMessageStatus != null) ...[
                                          MessageStatusIndicator(
                                            status: widget.lastMessageStatus!,
                                            moderationStatus: widget.lastMessageModerationStatus,
                                            size: 12,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        Expanded(
                                          child: Text(
                                            widget.lastMessage,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: colorScheme.onSurfaceVariant,
                                              fontStyle: widget.lastMessageType == 'deleted'
                                                  ? FontStyle.italic
                                                  : FontStyle.normal,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (widget.unreadCount > 0) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: colorScheme.primary,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              widget.unreadCount.toString(),
                                              style: TextStyle(
                                                color: colorScheme.onPrimary,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  }

                                  if (typingSnapshot.hasData && typingSnapshot.data!.docs.isNotEmpty) {
                                    final currentUserId = _auth.currentUser!.uid;
                                    final now = DateTime.now();

                                    final typingUserIds = typingSnapshot.data!.docs.where((doc) {
                                      if (doc.id == currentUserId) return false;

                                      final data = doc.data() as Map<String, dynamic>;
                                      final isTyping = data['isTyping'] as bool? ?? false;
                                      final timestamp = data['timestamp'] as Timestamp?;

                                      if (!isTyping || timestamp == null) return false;

                                      final diff = now.difference(timestamp.toDate());
                                      return diff.inSeconds < 5;
                                    }).map((doc) => doc.id).toList();

                                    if (typingUserIds.isNotEmpty) {
                                      return FutureBuilder<List<String>>(
                                        future: Future.wait<String>(
                                          typingUserIds.map<Future<String>>((userId) async {
                                            try {
                                              final userData = await userCacheService.getUserData(userId);
                                              return userData?['name'] as String? ?? 'Alguien';
                                            } catch (e) {
                                              return 'Alguien';
                                            }
                                          }),
                                        ),
                                        builder: (context, namesSnapshot) {
                                          if (!namesSnapshot.hasData) {
                                            return Row(
                                              children: [
                                                SizedBox(
                                                  width: 12,
                                                  height: 12,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 1.5,
                                                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
                                                  ),
                                                ),
                                                SizedBox(width: 6),
                                                Text(
                                                  'Escribiendo...',
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    color: Color(0xFF4CAF50),
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                ),
                                              ],
                                            );
                                          }

                                          final names = namesSnapshot.data!;
                                          String typingText;
                                          if (names.length == 1) {
                                            typingText = '${names[0]} está escribiendo...';
                                          } else if (names.length == 2) {
                                            typingText = '${names[0]} y ${names[1]} escribiendo...';
                                          } else {
                                            typingText = '${names[0]} y ${names.length - 1} más escribiendo...';
                                          }

                                          return Row(
                                            children: [
                                              SizedBox(
                                                width: 12,
                                                height: 12,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 1.5,
                                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
                                                ),
                                              ),
                                              SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  typingText,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    color: Color(0xFF4CAF50),
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                    }
                                  }

                                  // Mostrar lastMessage con indicador de estado
                                  final currentUserId = _auth.currentUser?.uid ?? '';
                                  final isOwnMessage = widget.lastMessageSenderId == currentUserId;

                                  return Row(
                                    children: [
                                      if (isOwnMessage && widget.lastMessageStatus != null) ...[
                                        MessageStatusIndicator(
                                          status: widget.lastMessageStatus!,
                                          moderationStatus: widget.lastMessageModerationStatus,
                                          size: 12,
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Expanded(
                                        child: Text(
                                          widget.lastMessage,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: colorScheme.onSurfaceVariant,
                                            fontStyle: widget.lastMessageType == 'deleted'
                                                ? FontStyle.italic
                                                : FontStyle.normal,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (widget.unreadCount > 0) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: colorScheme.primary,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            widget.unreadCount.toString(),
                                            style: TextStyle(
                                              color: colorScheme.onPrimary,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
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
        );
      },
    );
  }
}
