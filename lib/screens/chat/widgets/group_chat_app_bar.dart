import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../widgets/profile_photo_viewer.dart';
import '../../../controllers/group_chat_app_bar_controller.dart';

/// AppBar personalizado para pantallas de chat grupal
class GroupChatAppBar extends StatefulWidget implements PreferredSizeWidget {
  final String groupId;
  final String groupName;
  final VoidCallback onTap;

  const GroupChatAppBar({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.onTap,
  });

  @override
  State<GroupChatAppBar> createState() => _GroupChatAppBarState();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _GroupChatAppBarState extends State<GroupChatAppBar> {
  late GroupChatAppBarController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GroupChatAppBarController(groupId: widget.groupId);
    _setupControllerCallbacks();
    _controller.initialize();
  }

  void _setupControllerCallbacks() {
    _controller.onError = (message) {
      if (mounted) {
        _showErrorSnackbar(message);
      }
    };

    _controller.onSuccess = (message) {
      if (mounted) {
        _showSuccessSnackbar(message);
      }
    };

    // El CallsOrchestrator maneja la navegación automáticamente
    _controller.onNavigateToCall = () {
      // No es necesario navegar manualmente, CallsOrchestrator lo hace
    };
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
          stream: _controller.getGroupStream(),
          builder: (context, snapshot) {
            final groupData = snapshot.data?.data() as Map<String, dynamic>?;
            final photoURL = groupData?['avatar'] as String? ?? '';
            final members = groupData?['members'] as List<dynamic>? ?? [];
            final memberCount = members.length;

            return Row(
              children: [
                // Avatar del grupo (clickeable para ver ampliado)
                ClickableAvatar(
                  photoUrl: photoURL.isNotEmpty ? photoURL : null,
                  name: widget.groupName,
                  radius: 18,
                ),
                const SizedBox(width: 12),
                // Nombre y miembros
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.groupName,
                        style: const TextStyle(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$memberCount miembros',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDarkMode
                              ? colorScheme.onSurface.withValues(alpha: 0.7)
                              : colorScheme.onPrimary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        StreamBuilder<DocumentSnapshot>(
          stream: _controller.getGroupStream(),
          builder: (context, snapshot) {
            final groupData = snapshot.data?.data() as Map<String, dynamic>?;
            final members = List<String>.from(groupData?['members'] ?? []);
            final canStartCall = members.length > 1;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón de llamada de audio
                IconButton(
                  icon: const Icon(Icons.phone),
                  onPressed: canStartCall ? () => _startGroupAudioCall() : null,
                  tooltip: 'Llamada grupal',
                ),
                // Botón de videollamada
                IconButton(
                  icon: const Icon(Icons.videocam),
                  onPressed: canStartCall ? () => _startGroupVideoCall() : null,
                  tooltip: 'Videollamada grupal',
                ),
              ],
            );
          },
        ),
      ],
      backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
      foregroundColor:
          isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
    );
  }

  // ==================== CONTROLLER METHODS ====================

  void _startGroupVideoCall() {
    _controller.startGroupVideoCall();
  }

  void _startGroupAudioCall() {
    _controller.startGroupAudioCall();
  }

  // Método eliminado: CallsOrchestrator maneja navegación automáticamente

  // ==================== SNACKBARS ====================

  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccessSnackbar(String message) {
    // Success feedback removed - only show errors
  }
}
