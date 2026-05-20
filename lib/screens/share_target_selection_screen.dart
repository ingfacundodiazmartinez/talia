import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/shared_content.dart';
import '../controllers/share_target_controller.dart';

/// Pantalla para seleccionar destino del contenido compartido (chat o story)
class ShareTargetSelectionScreen extends StatefulWidget {
  const ShareTargetSelectionScreen({super.key});

  @override
  State<ShareTargetSelectionScreen> createState() =>
      _ShareTargetSelectionScreenState();
}

class _ShareTargetSelectionScreenState
    extends State<ShareTargetSelectionScreen> {
  late final ShareTargetController _controller;
  late final StreamSubscription<ShareTargetState> _stateSubscription;

  @override
  void initState() {
    super.initState();
    _controller = ShareTargetController();

    _controller.onSuccess = (message) {
      if (mounted) {
        // ✅ FIX: Usar ScaffoldMessenger.of(context) de manera más robusta
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        } catch (e) {
          // Si falla, al menos loguear
          debugPrint('Error showing success snackbar: $e');
        }
      }
    };

    _controller.onError = (message) {
      if (mounted) {
        // ✅ FIX: Mostrar AlertDialog para errores (más visible que SnackBar)
        try {
          showDialog(
            context: context,
            barrierDismissible: false, // Usuario debe presionar OK
            builder: (ctx) => AlertDialog(
              title: const Text('Error al enviar'),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        } catch (e) {
          debugPrint('Error showing error dialog: $e');
        }
      }
    };

    _controller.onComplete = () {
      if (mounted) {
        // ✅ FIX: Pequeño delay para que el snackbar se muestre antes de cerrar
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    };

    _stateSubscription = _controller.stateStream.listen((_) {
      if (mounted) setState(() {});
    });

    _controller.initialize();
  }

  @override
  void dispose() {
    _stateSubscription.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.currentState;

    if (state.content.isEmpty && !state.isLoading) {
      return _buildEmptyState(context);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compartir'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _controller.cancel();
            Navigator.pop(context);
          },
        ),
      ),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Preview section
                _buildPreviewSection(context, state.content),

                // Selector de destino (Chat / Historia) - solo si puede crear historia
                if (_controller.canCreateStory)
                  _buildDestinationPicker(context, state),

                // Contenido según destino
                Expanded(
                  child: state.destination == ShareDestination.story
                      ? _buildStoryContent(context, state)
                      : _buildChatList(context, state),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compartir')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.share_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No hay contenido para compartir',
              style: TextStyle(color: Colors.grey[600], fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewSection(
      BuildContext context, List<SharedContent> content) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.share, size: 16, color: Colors.grey[600]),
              const SizedBox(width: 8),
              Text(
                '${content.length} ${content.length == 1 ? "elemento" : "elementos"} para compartir',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: content.length,
              itemBuilder: (context, index) {
                return _buildPreviewItem(content[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewItem(SharedContent item) {
    if (item.isMedia && item.mediaPath != null) {
      return Container(
        width: 60,
        height: 60,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.grey[300],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(item.mediaPath!),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Icon(
                  item.type == SharedContentType.video
                      ? Icons.video_file
                      : Icons.image,
                  color: Colors.grey[600],
                ),
              ),
              if (item.type == SharedContentType.video)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: 120,
      height: 60,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[200],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.isUrl ? Icons.link : Icons.text_fields,
            size: 14,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Text(
              item.text ?? item.url ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: Colors.grey[700]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatList(BuildContext context, ShareTargetState state) {
    final chatsController = _controller.chatsController;

    if (chatsController.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!chatsController.hasChatsOrGroups) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No hay chats disponibles',
              style: TextStyle(color: Colors.grey[600], fontSize: 16),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              // Sección de chats
              if (chatsController.chats.isNotEmpty) ...[
                _buildSectionHeader('Chats'),
                ...chatsController.chats.map((chat) => _buildChatTile(
                      chatId: chat.chatId,
                      name: chat.contactName,
                      photoUrl: chat.contactPhotoUrl,
                      isGroup: false,
                      isSelected: state.selectedChatId == chat.chatId,
                    )),
              ],
              // Sección de grupos
              if (chatsController.groups.isNotEmpty) ...[
                _buildSectionHeader('Grupos'),
                ...chatsController.groups.map((group) => _buildChatTile(
                      chatId: group.groupId,
                      name: group.groupName,
                      photoUrl: group.groupPhotoUrl,
                      isGroup: true,
                      isSelected: state.selectedChatId == group.groupId,
                      subtitle: '${group.membersCount} miembros',
                    )),
              ],
            ],
          ),
        ),
        // Botón de enviar
        if (state.selectedChatId != null) _buildSendButton(context, state),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.grey[600],
        ),
      ),
    );
  }

  Widget _buildChatTile({
    required String chatId,
    required String name,
    String? photoUrl,
    required bool isGroup,
    required bool isSelected,
    String? subtitle,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: CircleAvatar(
        backgroundImage:
            photoUrl != null ? CachedNetworkImageProvider(photoUrl) : null,
        backgroundColor: Colors.grey[300],
        child: photoUrl == null
            ? Icon(
                isGroup ? Icons.group : Icons.person,
                color: Colors.grey[600],
              )
            : null,
      ),
      title: Text(name),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: isSelected
          ? Icon(Icons.check_circle, color: colorScheme.primary)
          : Icon(Icons.circle_outlined, color: Colors.grey[400]),
      selected: isSelected,
      selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
      onTap: () => _controller.selectChat(chatId, isGroup: isGroup),
    );
  }

  Widget _buildSendButton(BuildContext context, ShareTargetState state) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: state.isSending ? null : _controller.sendToChat,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: state.isSending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send),
            label: Text(state.isSending ? 'Enviando...' : 'Enviar'),
          ),
        ),
      ),
    );
  }

  Widget _buildDestinationPicker(BuildContext context, ShareTargetState state) {
    final isChat = state.destination != ShareDestination.story;
    final isStory = state.destination == ShareDestination.story;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _buildDestinationButton(
              context: context,
              label: 'Chat',
              icon: Icons.chat_bubble,
              isSelected: isChat,
              onTap: () => _controller.selectDestination(ShareDestination.chat),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildDestinationButton(
              context: context,
              label: 'Historia',
              icon: Icons.auto_awesome,
              isSelected: isStory,
              onTap: () => _controller.selectDestination(ShareDestination.story),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDestinationButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? colorScheme.primary : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoryContent(BuildContext context, ShareTargetState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = state.content.isNotEmpty ? state.content.first : null;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Preview grande
                if (content != null && content.mediaPath != null)
                  Container(
                    constraints: const BoxConstraints(maxWidth: 250, maxHeight: 350),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(content.mediaPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 200,
                          height: 300,
                          color: Colors.grey[300],
                          child: Icon(Icons.image, size: 64, color: Colors.grey[600]),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Text(
                  'Tu historia estará visible por 24 horas',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Botón crear historia
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: state.isSending ? null : _controller.createStory,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: state.isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.add_circle_outline),
                label: Text(state.isSending ? 'Creando...' : 'Crear Historia'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
