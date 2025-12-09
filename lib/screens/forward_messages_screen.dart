import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/chat_message.dart';
import '../services/message_forward_service.dart';
import '../controllers/forward_messages_controller.dart';
import '../utils/string_utils.dart';

/// Pantalla para seleccionar chats/grupos a los que reenviar múltiples mensajes
class ForwardMessagesScreen extends StatefulWidget {
  final List<ChatMessage> messages;
  final String originalChatId;
  final String contactName;

  const ForwardMessagesScreen({
    super.key,
    required this.messages,
    required this.originalChatId,
    required this.contactName,
  });

  @override
  State<ForwardMessagesScreen> createState() => _ForwardMessagesScreenState();
}

class _ForwardMessagesScreenState extends State<ForwardMessagesScreen> {
  late final ForwardMessagesController _controller;
  final MessageForwardService _forwardService = MessageForwardService();

  final Set<String> _selectedChatIds = {};
  final Set<String> _selectedGroupIds = {};
  bool _isForwarding = false;

  @override
  void initState() {
    super.initState();
    _controller = ForwardMessagesController();
    _controller.initialize(originalChatId: widget.originalChatId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }


  Future<void> _forwardMessages() async {
    if (_selectedChatIds.isEmpty && _selectedGroupIds.isEmpty) return;

    setState(() => _isForwarding = true);

    try {
      final result = await _forwardService.forwardMultipleMessages(
        originalMessages: widget.messages,
        targetChatIds: _selectedChatIds.toList(),
        targetGroupIds: _selectedGroupIds.toList(),
        originalChatId: widget.originalChatId,
        originalContactName: widget.contactName,
      );

      if (mounted) {
        Navigator.pop(context);

        if (result['success']) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${widget.messages.length} mensajes reenviados a ${result['forwardedCount']} chats'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al reenviar: ${result['error']}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isForwarding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final totalSelected = _selectedChatIds.length + _selectedGroupIds.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(totalSelected > 0
            ? '$totalSelected seleccionados'
            : 'Reenviar ${widget.messages.length} mensajes'),
        actions: [
          if (totalSelected > 0)
            IconButton(
              icon: _isForwarding
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : Icon(Icons.send),
              onPressed: _isForwarding ? null : _forwardMessages,
              tooltip: 'Reenviar',
            ),
        ],
      ),
      body: _controller.isLoading
          ? Center(child: CircularProgressIndicator())
          : !_controller.hasChatsOrGroups
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[400]),
                      SizedBox(height: 16),
                      Text(
                        'No hay chats disponibles',
                        style: TextStyle(color: Colors.grey[600], fontSize: 16),
                      ),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    // Vista previa de los mensajes
                    Container(
                      margin: EdgeInsets.all(16),
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.forward, size: 16, color: Colors.grey[600]),
                              SizedBox(width: 8),
                              Text(
                                'Mensajes a reenviar de conversación con ${widget.contactName}:',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          ...widget.messages.take(3).map((message) => Padding(
                            padding: EdgeInsets.only(bottom: 4),
                            child: Text(
                              StringUtils.sanitize(message.text ?? '[Media]'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13),
                            ),
                          )),
                          if (widget.messages.length > 3)
                            Text(
                              '+ ${widget.messages.length - 3} más...',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Sección de Chats
                    if (_controller.chats.isNotEmpty) ...[
                      Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Text(
                          'Chats',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      ..._controller.chats.map((chat) => CheckboxListTile(
                            value: _selectedChatIds.contains(chat.chatId),
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  _selectedChatIds.add(chat.chatId);
                                } else {
                                  _selectedChatIds.remove(chat.chatId);
                                }
                              });
                            },
                            activeColor: colorScheme.primary,
                            secondary: CircleAvatar(
                              radius: 20,
                              backgroundColor: colorScheme.primaryContainer,
                              child: chat.contactPhotoUrl != null
                                  ? ClipOval(
                                      child: CachedNetworkImage(
                                        imageUrl: chat.contactPhotoUrl!,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => Icon(Icons.person),
                                        errorWidget: (context, url, error) => Icon(Icons.person),
                                      ),
                                    )
                                  : Text(
                                      chat.contactName[0].toUpperCase(),
                                      style: TextStyle(
                                        color: colorScheme.primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                            title: Text(
                              chat.contactName,
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: chat.isOnline
                                ? Text(
                                    'En línea',
                                    style: TextStyle(color: Colors.green, fontSize: 12),
                                  )
                                : null,
                          )),
                    ],

                    // Sección de Grupos
                    if (_controller.groups.isNotEmpty) ...[
                      Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          'Grupos',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      ..._controller.groups.map((group) => CheckboxListTile(
                            value: _selectedGroupIds.contains(group.groupId),
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  _selectedGroupIds.add(group.groupId);
                                } else {
                                  _selectedGroupIds.remove(group.groupId);
                                }
                              });
                            },
                            activeColor: colorScheme.primary,
                            secondary: CircleAvatar(
                              radius: 20,
                              backgroundColor: colorScheme.primaryContainer,
                              child: group.groupPhotoUrl != null
                                  ? ClipOval(
                                      child: CachedNetworkImage(
                                        imageUrl: group.groupPhotoUrl!,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => Icon(Icons.group, color: colorScheme.primary),
                                        errorWidget: (context, url, error) => Icon(Icons.group, color: colorScheme.primary),
                                      ),
                                    )
                                  : Icon(Icons.group, color: colorScheme.primary),
                            ),
                            title: Text(
                              group.groupName,
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(
                              '${group.membersCount} miembros',
                              style: TextStyle(fontSize: 12),
                            ),
                          )),
                    ],
                  ],
                ),
    );
  }
}
