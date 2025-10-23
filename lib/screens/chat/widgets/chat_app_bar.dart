import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../widgets/profile_photo_viewer.dart';
import '../../../services/block_service.dart';

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
  bool _isParentOrAdult = false;
  bool _isLoading = true;
  final BlockService _blockService = BlockService();

  @override
  void initState() {
    super.initState();
    _checkIfParentOrAdult();
  }

  Future<void> _checkIfParentOrAdult() async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) {
        setState(() => _isLoading = false);
        return;
      }

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUserId)
          .get();

      if (!userDoc.exists) {
        setState(() => _isLoading = false);
        return;
      }

      final userData = userDoc.data();

      // Verificar si es padre
      bool isParentOrAdult = userData?['isParent'] == true;

      // Verificar si es adulto (mayor de 18 años)
      if (!isParentOrAdult) {
        final birthDate = userData?['birthDate'];
        if (birthDate != null) {
          final birthDateTime = (birthDate as Timestamp).toDate();
          final age = DateTime.now().difference(birthDateTime).inDays ~/ 365;
          isParentOrAdult = age >= 18;
        }
      }

      setState(() {
        _isParentOrAdult = isParentOrAdult;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Error verificando si es padre/adulto: $e');
      setState(() => _isLoading = false);
    }
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
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(widget.contactId)
              .snapshots(),
          builder: (context, snapshot) {
            final userData = snapshot.data?.data() as Map<String, dynamic>?;
            final photoURL = userData?['photoURL'] as String? ?? '';
            final isOnline = userData?['isOnline'] ?? false;

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
                      Text(
                        widget.contactName,
                        style: const TextStyle(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          if (isOnline) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            isOnline ? 'En línea' : 'Desconectado',
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
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
      foregroundColor:
          isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      actions: [
        StreamBuilder<bool>(
          stream: _blockService.isBlockedStream(widget.contactId),
          initialData: false,
          builder: (context, blockedSnapshot) {
            final isBlocked = blockedSnapshot.data ?? false;

            return PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                if (value == 'moderation') {
                  Navigator.pushNamed(
                    context,
                    '/chat_moderation_settings',
                    arguments: {
                      'chatId': widget.chatId,
                      'contactName': widget.contactName,
                    },
                  );
                } else if (value == 'clear_chat') {
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
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error al desbloquear: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                }
              },
              itemBuilder: (context) {
            final items = <PopupMenuEntry<String>>[];

            // Mostrar "Moderación con IA" solo para padres/adultos
            if (_isParentOrAdult) {
              items.add(
                PopupMenuItem(
                  value: 'moderation',
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        color: colorScheme.onSurface,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Moderación con IA',
                        style: TextStyle(color: colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
              );
            }

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

            return items;
          },
        );
          },
        ),
      ],
    );
  }
}
