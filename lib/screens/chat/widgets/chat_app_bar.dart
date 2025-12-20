import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../widgets/profile_photo_viewer.dart';
import '../../../widgets/synced_user_widgets.dart';
import '../../../services/block_service.dart';
import '../../../services/typing_indicator_service.dart';
import '../../../controllers/chat_app_bar_controller.dart';
import '../../../calls_v2/screens/agora_call_screen.dart';
import 'moderation_dialog.dart';

/// AppBar personalizado para pantallas de chat
class ChatAppBar extends StatefulWidget implements PreferredSizeWidget {
  final String contactId;
  final String contactName;
  final String contactPhotoURL;
  final String chatId;
  final VoidCallback onTap;
  final VoidCallback? onClearChat;

  const ChatAppBar({
    super.key,
    required this.contactId,
    required this.contactName,
    required this.contactPhotoURL,
    required this.chatId,
    required this.onTap,
    this.onClearChat,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<ChatAppBar> createState() => _ChatAppBarState();
}

class _ChatAppBarState extends State<ChatAppBar> {
  final BlockService _blockService = BlockService();
  late final ChatAppBarController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ChatAppBarController();
    _controller.initialize(chatId: widget.chatId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
      title: InkWell(
        onTap: widget.onTap,
        child: StreamBuilder<DocumentSnapshot>(
          stream: _controller.getContactDataStream(widget.contactId),
          builder: (context, snapshot) {
            final contactData = _controller.extractContactData(snapshot.data);
            final photoURL = contactData['photoURL'] as String;
            final isOnline = contactData['isOnline'] as bool;

            // Escuchar el estado de typing
            return StreamBuilder<bool>(
              stream: TypingIndicatorService().watchOtherUserTyping(
                widget.chatId,
                widget.contactId,
              ),
              initialData: false,
              builder: (context, typingSnapshot) {
                final isTyping = typingSnapshot.data ?? false;

                return Row(
                  children: [
                    // Avatar del contacto (clickeable para ver ampliado)
                    ClickableAvatar(
                      photoUrl: photoURL.isNotEmpty ? photoURL : null,
                      name: widget.contactName,
                      radius: 18,
                    ),
                    const SizedBox(width: 12),
                    // Nombre y estado
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SyncedUserName(
                            userId: widget.contactId,
                            fallbackName: widget.contactName,
                            style: const TextStyle(fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                          // Mostrar "escribiendo..." si está escribiendo, sino el estado normal
                          Text(
                            isTyping ? 'escribiendo...' : (isOnline ? 'En línea' : 'Desconectado'),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDarkMode
                                  ? colorScheme.onSurface
                                      .withValues(alpha: 0.7)
                                  : colorScheme.onPrimary
                                      .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
      backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
      foregroundColor:
          isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      actions: [
        // Botón de llamada de audio - Navegación inmediata
        IconButton(
          icon: const Icon(Icons.call),
          onPressed: () {
            // Navegar inmediatamente - la llamada se crea en background
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (context) => AgoraCallScreen.create(
                  participantIds: [widget.contactId],
                  isVideo: false,
                  isGroup: false,
                ),
              ),
            );
          },
          tooltip: 'Llamada de audio',
        ),

        // Botón de videollamada - Navegación inmediata
        IconButton(
          icon: const Icon(Icons.videocam),
          onPressed: () {
            // Navegar inmediatamente - la llamada se crea en background
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (context) => AgoraCallScreen.create(
                  participantIds: [widget.contactId],
                  isVideo: true,
                  isGroup: false,
                ),
              ),
            );
          },
          tooltip: 'Videollamada',
        ),

        StreamBuilder<bool>(
          stream: _blockService.isBlockedStream(widget.contactId),
          initialData: false,
          builder: (context, blockedSnapshot) {
            final isBlocked = blockedSnapshot.data ?? false;

            return PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                if (value == 'clear_chat') {
                  if (widget.onClearChat != null) {
                    // Mostrar confirmación
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Limpiar chat'),
                        content: const Text(
                          '¿Estás seguro de que deseas limpiar este chat? '
                          'Todos los mensajes se borrarán solo para ti.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancelar'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onClearChat!();
                            },
                            child: const Text('Limpiar'),
                          ),
                        ],
                      ),
                    );
                  }
                } else if (value == 'block') {
                  // Bloquear contacto
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Bloquear contacto'),
                      content: Text(
                        '¿Estás seguro de que deseas bloquear a ${widget.contactName}? '
                        'No podrás enviar ni recibir mensajes.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancelar'),
                        ),
                        TextButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            try {
                              await _blockService.blockContact(widget.contactId);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('${widget.contactName} ha sido bloqueado'),
                                    backgroundColor: Colors.orange,
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Error al bloquear: $e'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Bloquear', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                } else if (value == 'unblock') {
                  // Desbloquear contacto
                  try {
                    await _blockService.unblockContact(widget.contactId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${widget.contactName} ha sido desbloqueado'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    }
                  } on ParentBlockedException {
                    if (context.mounted) {
                      _showParentBlockedDialog(context);
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error al desbloquear contacto'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                } else if (value == 'moderation') {
                  // Mostrar diálogo de moderación
                  ModerationDialog.show(context, _controller);
                }
              },
              itemBuilder: (context) {
            final items = <PopupMenuEntry<String>>[];

            // Opción limpiar chat
            if (widget.onClearChat != null) {
              items.add(
                PopupMenuItem(
                  value: 'clear_chat',
                  child: Row(
                    children: [
                      Icon(
                        Icons.cleaning_services,
                        color: colorScheme.onSurface,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Limpiar chat',
                        style: TextStyle(color: colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
              );
            }

            // Opción bloquear/desbloquear
            items.add(
              PopupMenuItem(
                value: isBlocked ? 'unblock' : 'block',
                child: Row(
                  children: [
                    Icon(
                      isBlocked ? Icons.check_circle : Icons.block,
                      color: isBlocked ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      isBlocked ? 'Desbloquear contacto' : 'Bloquear contacto',
                      style: TextStyle(
                        color: isBlocked ? Colors.green : Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            );

            // Opción moderación IA (solo para adultos/padres)
            if (_controller.canModifyModeration) {
              items.add(
                PopupMenuItem(
                  value: 'moderation',
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology,
                        color: _controller.moderationEnabled
                            ? const Color(0xFF5C6BC0)
                            : colorScheme.onSurface,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Moderación IA',
                        style: TextStyle(color: colorScheme.onSurface),
                      ),
                      if (_controller.moderationEnabled) ...[
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF5C6BC0),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getModerationLabel(_controller.moderationLevel),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }

            return items;
          },
        );
          },
        ),
      ],
    );
  }

  /// Helper para obtener label del nivel de moderación
  String _getModerationLabel(String level) {
    switch (level) {
      case 'high':
        return 'Alto';
      case 'medium':
        return 'Medio';
      case 'low':
        return 'Bajo';
      default:
        return 'Medio';
    }
  }

  void _showParentBlockedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.family_restroom,
          size: 48,
          color: Colors.orange,
        ),
        title: Text('Contacto bloqueado'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Este contacto fue bloqueado por tu padre o madre.',
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12),
            Text(
              'Solo ellos pueden desbloquearlo desde su aplicación.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }
}
