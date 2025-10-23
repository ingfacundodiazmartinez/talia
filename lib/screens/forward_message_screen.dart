import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/chat_message.dart';
import '../services/message_forward_service.dart';
import '../services/contact_alias_service.dart';
import '../utils/string_utils.dart';

/// Pantalla para seleccionar chats/grupos a los que reenviar un mensaje
class ForwardMessageScreen extends StatefulWidget {
  final ChatMessage message;
  final String? chatId; // ID del chat del cual se está reenviando
  final String? contactName; // Nombre del contacto del chat original

  const ForwardMessageScreen({
    super.key,
    required this.message,
    this.chatId,
    this.contactName,
  });

  @override
  State<ForwardMessageScreen> createState() => _ForwardMessageScreenState();
}

class _ForwardMessageScreenState extends State<ForwardMessageScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ContactAliasService _aliasService = ContactAliasService();
  final MessageForwardService _forwardService = MessageForwardService();

  final Set<String> _selectedChatIds = {};
  final Set<String> _selectedGroupIds = {};

  List<ChatItem> _chats = [];
  List<GroupItem> _groups = [];
  bool _isLoading = true;
  bool _isForwarding = false;

  @override
  void initState() {
    super.initState();
    _loadChatsAndGroups();
  }

  Future<void> _loadChatsAndGroups() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      // Cargar chats individuales
      final chatsSnapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: currentUserId)
          .get();

      final chatsList = <ChatItem>[];
      for (final doc in chatsSnapshot.docs) {
        final data = doc.data();
        final participants = List<String>.from(data['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) continue;

        // Obtener info del contacto
        final userDoc = await _firestore.collection('users').doc(otherUserId).get();
        final userData = userDoc.data();

        if (userData != null) {
          final realName = userData['name'] ?? 'Usuario';
          final displayName = await _aliasService.getDisplayName(otherUserId, realName);

          chatsList.add(ChatItem(
            chatId: doc.id,
            contactId: otherUserId,
            contactName: displayName,
            contactPhotoUrl: userData['photoURL'],
            isOnline: userData['isOnline'] ?? false,
          ));
        }
      }

      // Cargar grupos
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: currentUserId)
          .get();

      final groupsList = <GroupItem>[];
      for (final doc in groupsSnapshot.docs) {
        final data = doc.data();
        groupsList.add(GroupItem(
          groupId: doc.id,
          groupName: data['name'] ?? 'Grupo',
          groupPhotoUrl: data['avatar'], // Campo correcto es 'avatar' no 'imageUrl'
          membersCount: (data['members'] as List?)?.length ?? 0,
        ));
      }

      setState(() {
        _chats = chatsList;
        _groups = groupsList;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Error cargando chats y grupos: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _forwardMessage() async {
    if (_selectedChatIds.isEmpty && _selectedGroupIds.isEmpty) return;

    setState(() => _isForwarding = true);

    try {
      final result = await _forwardService.forwardMessage(
        originalMessage: widget.message,
        targetChatIds: _selectedChatIds.toList(),
        targetGroupIds: _selectedGroupIds.toList(),
        originalChatId: widget.chatId,
        originalContactName: widget.contactName,
      );

      if (mounted) {
        Navigator.pop(context);

        if (result['success']) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Mensaje reenviado a ${result['forwardedCount']} chats'),
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
            : 'Reenviar mensaje'),
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
              onPressed: _isForwarding ? null : _forwardMessage,
              tooltip: 'Reenviar',
            ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _chats.isEmpty && _groups.isEmpty
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
                    // Vista previa del mensaje
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
                                'Mensaje a reenviar:',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Text(
                            StringUtils.sanitize(widget.message.text),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),

                    // Sección de Chats
                    if (_chats.isNotEmpty) ...[
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
                      ..._chats.map((chat) => CheckboxListTile(
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
                              backgroundImage: chat.contactPhotoUrl != null
                                  ? NetworkImage(chat.contactPhotoUrl!)
                                  : null,
                              child: chat.contactPhotoUrl == null
                                  ? Text(
                                      chat.contactName[0].toUpperCase(),
                                      style: TextStyle(
                                        color: colorScheme.primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
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
                    if (_groups.isNotEmpty) ...[
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
                      ..._groups.map((group) => CheckboxListTile(
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
                              backgroundImage: group.groupPhotoUrl != null
                                  ? NetworkImage(group.groupPhotoUrl!)
                                  : null,
                              child: group.groupPhotoUrl == null
                                  ? Icon(Icons.group, color: colorScheme.primary)
                                  : null,
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

class ChatItem {
  final String chatId;
  final String contactId;
  final String contactName;
  final String? contactPhotoUrl;
  final bool isOnline;

  ChatItem({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    this.contactPhotoUrl,
    required this.isOnline,
  });
}

class GroupItem {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final int membersCount;

  GroupItem({
    required this.groupId,
    required this.groupName,
    this.groupPhotoUrl,
    required this.membersCount,
  });
}
