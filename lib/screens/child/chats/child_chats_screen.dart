import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/child_home_controller.dart';
import '../../../widgets/stories_section.dart';
import '../../../widgets/emergency_button.dart';
import '../../../widgets/create_group_widget.dart';
import '../../../services/chat_service.dart';
import '../../../services/group_chat_service.dart';
import '../../../services/user_role_service.dart';
import '../../../services/contact_alias_service.dart';
import '../../../screens/group_chat_screen.dart';
import '../../chat_detail_screen.dart';

/// Pantalla completa de chats para niños
///
/// Incluye:
/// - Header con botones de crear grupo y emergencia
/// - Sección de stories
/// - Grupos
/// - Chat con padre (categoría "Familia")
/// - Chats con otros contactos
class ChildChatsScreen extends StatefulWidget {
  final String childId;
  final ChildHomeController controller;

  const ChildChatsScreen({
    super.key,
    required this.childId,
    required this.controller,
  });

  @override
  State<ChildChatsScreen> createState() => _ChildChatsScreenState();
}

class _ChildChatsScreenState extends State<ChildChatsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ChatService _chatService = ChatService();
  final ContactAliasService _aliasService = ContactAliasService();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDarkMode
              ? [
                  colorScheme.primary.withValues(alpha: 0.3),
                  colorScheme.primary.withValues(alpha: 0.2),
                ]
              : [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(isDarkMode, colorScheme),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                ),
                child: _buildChatList(colorScheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDarkMode, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '¡Hola! 👋',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: isDarkMode ? colorScheme.onSurface : Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Tus conversaciones seguras',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDarkMode
                        ? colorScheme.onSurface.withValues(alpha: 0.7)
                        : Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (context) => CreateGroupWidget(
                      onGroupCreated: () {
                        setState(() {});
                      },
                    ),
                  );
                },
                child: Icon(
                  Icons.group_add,
                  color: isDarkMode ? colorScheme.onSurface : Colors.white,
                  size: 22,
                ),
              ),
              SizedBox(width: 8),
              FutureBuilder<bool>(
                future: widget.controller.hasLinkedParents(),
                builder: (context, snapshot) {
                  if (snapshot.data == true) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HeaderEmergencyButton(
                          onEmergencyActivated: () {
                            print('🆘 Emergencia activada desde el header');
                          },
                        ),
                        SizedBox(width: 8),
                      ],
                    );
                  }
                  return SizedBox.shrink();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChatList(ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('chats')
          .where('participants', arrayContains: widget.childId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: colorScheme.error),
                SizedBox(height: 16),
                Text('Error: ${snapshot.error}', style: TextStyle(color: colorScheme.onSurface)),
              ],
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return _buildEmptyState(colorScheme);
        }

        final filteredChats = _chatService.filterDeletedChats(snapshot.data!);

        return FutureBuilder<List<Widget>>(
          future: _buildCategorizedChatList(filteredChats, colorScheme),
          builder: (context, chatListSnapshot) {
            if (chatListSnapshot.connectionState == ConnectionState.waiting) {
              return Center(child: CircularProgressIndicator());
            }

            if (!chatListSnapshot.hasData || chatListSnapshot.data!.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 64, color: colorScheme.outlineVariant),
                    SizedBox(height: 16),
                    Text(
                      'No tienes conversaciones aún',
                      style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              );
            }

            return ListView(
              padding: EdgeInsets.all(16),
              children: chatListSnapshot.data!,
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return FutureBuilder<String?>(
      future: widget.controller.getLinkedParentId(),
      builder: (context, parentSnapshot) {
        return ListView(
          padding: EdgeInsets.all(16),
          children: [
            StoriesHeader(),
            StoriesSection(),
            SizedBox(height: 24),
            if (parentSnapshot.hasData && parentSnapshot.data != null)
              FutureBuilder<DocumentSnapshot>(
                future: _firestore.collection('users').doc(parentSnapshot.data!).get(),
                builder: (context, userSnapshot) {
                  if (userSnapshot.hasData && userSnapshot.data!.exists) {
                    final parentData = userSnapshot.data!.data() as Map<String, dynamic>?;
                    if (parentData != null) {
                      final parentId = parentSnapshot.data!;
                      final realName = parentData['name'] ?? 'Padre/Madre';

                      return StreamBuilder<String>(
                        stream: _aliasService.watchDisplayName(parentId, realName),
                        initialData: realName,
                        builder: (context, aliasSnapshot) {
                          final displayName = aliasSnapshot.data ?? realName;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildParentChatHeader(colorScheme),
                              _buildChatItem(
                                chatId: _getChatId(widget.childId, parentId),
                                userId: parentId,
                                name: displayName,
                                lastMessage: 'Inicia una conversación',
                                time: '',
                                unreadCount: 0,
                                isOnline: parentData['isOnline'] ?? false,
                                photoURL: parentData['photoURL'],
                                isParent: true,
                                isEmpty: true,
                                colorScheme: colorScheme,
                              ),
                            ],
                          );
                        },
                      );
                    }
                  }
                  return SizedBox.shrink();
                },
              ),
            if (parentSnapshot.data == null)
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 64, color: colorScheme.outlineVariant),
                    SizedBox(height: 16),
                    Text(
                      'No tienes conversaciones aún',
                      style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Future<List<Widget>> _buildCategorizedChatList(
    List<QueryDocumentSnapshot> chatDocs,
    ColorScheme colorScheme,
  ) async {
    final List<Widget> widgets = [];
    final List<Map<String, dynamic>> parentChats = [];
    final List<Map<String, dynamic>> otherChats = [];

    // Agregar sección de historias al principio
    widgets.add(StoriesHeader());
    widgets.add(StoriesSection());
    widgets.add(SizedBox(height: 16));

    // Obtener y agregar grupos
    try {
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: widget.childId)
          .where('isActive', isEqualTo: true)
          .orderBy('lastActivity', descending: true)
          .get();

      if (groupsSnapshot.docs.isNotEmpty) {
        widgets.add(
          Padding(
            padding: EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Grupos',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        );

        for (final groupDoc in groupsSnapshot.docs) {
          final groupData = groupDoc.data();
          widgets.add(_buildGroupChatItem(
            groupId: groupDoc.id,
            groupName: groupData['name'] ?? 'Grupo',
            memberCount: (groupData['members'] as List?)?.length ?? 0,
            lastMessage: 'Toca para abrir',
            messageCount: groupData['messageCount'] ?? 0,
            colorScheme: colorScheme,
          ));
        }

        widgets.add(SizedBox(height: 16));
      }
    } catch (e) {
      print('Error obteniendo grupos: $e');
    }

    // Obtener padres vinculados
    final userRoleService = UserRoleService();
    final linkedParents = await userRoleService.getLinkedParents(widget.childId);
    final parentId = linkedParents.isNotEmpty ? linkedParents.first : null;

    // Separar chats de padres y otros
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != widget.childId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) continue;

      try {
        final userDoc = await _firestore.collection('users').doc(otherUserId).get();
        final userData = userDoc.data();

        final chatInfo = {
          'chatDoc': chatDoc,
          'chatData': chatData,
          'otherUserId': otherUserId,
          'userData': userData,
        };

        if (otherUserId == parentId || (userData?['isParent'] == true)) {
          parentChats.add(chatInfo);
        } else {
          otherChats.add(chatInfo);
        }
      } catch (e) {
        print('Error obteniendo datos del usuario $otherUserId: $e');
      }
    }

    // Agregar chats de padres (o crear placeholder)
    if (parentId != null) {
      final existingParentChat = parentChats.any(
        (chat) => chat['otherUserId'] == parentId,
      );

      if (!existingParentChat) {
        try {
          final parentDoc = await _firestore.collection('users').doc(parentId).get();
          final parentData = parentDoc.data();

          if (parentData != null) {
            final realName = parentData['name'] ?? 'Padre/Madre';

            widgets.add(_buildParentChatHeader(colorScheme));
            widgets.add(
              StreamBuilder<String>(
                stream: _aliasService.watchDisplayName(parentId, realName),
                initialData: realName,
                builder: (context, aliasSnapshot) {
                  final displayName = aliasSnapshot.data ?? realName;

                  return _buildChatItem(
                    chatId: _getChatId(widget.childId, parentId),
                    userId: parentId,
                    name: displayName,
                    lastMessage: 'Inicia una conversación',
                    time: '',
                    unreadCount: 0,
                    isOnline: parentData['isOnline'] ?? false,
                    photoURL: parentData['photoURL'],
                    isParent: true,
                    isEmpty: true,
                    colorScheme: colorScheme,
                  );
                },
              ),
            );
          }
        } catch (e) {
          print('Error obteniendo datos del padre: $e');
        }
      }
    }

    // Agregar chats de padres existentes
    if (parentChats.isNotEmpty) {
      widgets.add(_buildParentChatHeader(colorScheme));

      parentChats.sort((a, b) {
        final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
        final bTime = b['chatData']['lastMessageTime'] as Timestamp?;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      for (final chat in parentChats) {
        final chatDoc = chat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = chat['chatData'] as Map<String, dynamic>;
        final userData = chat['userData'] as Map<String, dynamic>?;
        final otherUserId = chat['otherUserId'] as String;
        final realName = userData?['name'] ?? 'Usuario';

        final unreadCount = chatData['unreadCount_${widget.childId}'] ?? 0;
        widgets.add(
          StreamBuilder<String>(
            stream: _aliasService.watchDisplayName(otherUserId, realName),
            initialData: realName,
            builder: (context, aliasSnapshot) {
              final displayName = aliasSnapshot.data ?? realName;

              return _buildChatItem(
                chatId: chatDoc.id,
                userId: otherUserId,
                name: displayName,
                lastMessage: chatData['lastMessage'] ?? '',
                time: _formatTime(chatData['lastMessageTime']),
                unreadCount: unreadCount is int ? unreadCount : 0,
                isOnline: userData?['isOnline'] ?? false,
                photoURL: userData?['photoURL'],
                isParent: true,
                colorScheme: colorScheme,
              );
            },
          ),
        );
      }
    }

    // Agregar separador si hay chats de padres y otros chats
    if (widgets.isNotEmpty && otherChats.isNotEmpty) {
      widgets.add(SizedBox(height: 16));
      widgets.add(_buildOtherChatsHeader(colorScheme));
    }

    // Agregar otros chats
    if (otherChats.isNotEmpty) {
      if (widgets.isEmpty) {
        widgets.add(_buildOtherChatsHeader(colorScheme));
      }

      otherChats.sort((a, b) {
        final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
        final bTime = b['chatData']['lastMessageTime'] as Timestamp?;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      for (final chat in otherChats) {
        final chatDoc = chat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = chat['chatData'] as Map<String, dynamic>;
        final userData = chat['userData'] as Map<String, dynamic>?;
        final otherUserId = chat['otherUserId'] as String;
        final realName = userData?['name'] ?? 'Usuario';

        final unreadCount = chatData['unreadCount_${widget.childId}'] ?? 0;
        widgets.add(
          StreamBuilder<String>(
            stream: _aliasService.watchDisplayName(otherUserId, realName),
            initialData: realName,
            builder: (context, aliasSnapshot) {
              final displayName = aliasSnapshot.data ?? realName;

              return _buildChatItem(
                chatId: chatDoc.id,
                userId: otherUserId,
                name: displayName,
                lastMessage: chatData['lastMessage'] ?? '',
                time: _formatTime(chatData['lastMessageTime']),
                unreadCount: unreadCount is int ? unreadCount : 0,
                isOnline: userData?['isOnline'] ?? false,
                photoURL: userData?['photoURL'],
                isParent: false,
                colorScheme: colorScheme,
              );
            },
          ),
        );
      }
    }

    return widgets;
  }

  Widget _buildParentChatHeader(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.shield, size: 16, color: Colors.green),
          ),
          SizedBox(width: 8),
          Text(
            'Familia',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOtherChatsHeader(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.people, size: 16, color: colorScheme.primary),
          ),
          SizedBox(width: 8),
          Text(
            'Contactos',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupChatItem({
    required String groupId,
    required String groupName,
    required int memberCount,
    required String lastMessage,
    required int messageCount,
    required ColorScheme colorScheme,
  }) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GroupChatScreen(
              groupId: groupId,
              groupName: groupName,
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.group, color: colorScheme.primary, size: 24),
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
                          groupName,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    '$memberCount miembros',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colorScheme.outlineVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildChatItem({
    required String chatId,
    required String userId,
    required String name,
    required String lastMessage,
    required String time,
    required int unreadCount,
    required bool isOnline,
    String? photoURL,
    bool isParent = false,
    bool isEmpty = false,
    required ColorScheme colorScheme,
  }) {
    return GestureDetector(
      onTap: () {
        print('Navegando al chat: $chatId con usuario: $userId');
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              contactId: userId,
              contactName: name,
              chatId: chatId,
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: unreadCount > 0 ? colorScheme.primaryContainer.withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: colorScheme.primaryContainer,
                  backgroundImage: photoURL != null && photoURL.isNotEmpty ? NetworkImage(photoURL) : null,
                  child: photoURL == null || photoURL.isEmpty
                      ? Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'U',
                          style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
                        )
                      : null,
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: colorScheme.surface, width: 2),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (time.isNotEmpty)
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastMessage,
                          style: TextStyle(
                            fontSize: 13,
                            color: isEmpty
                                ? colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
                                : colorScheme.onSurfaceVariant,
                            fontStyle: isEmpty ? FontStyle.italic : FontStyle.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unreadCount > 0)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unreadCount.toString(),
                            style: TextStyle(
                              color: colorScheme.onPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';

    final DateTime dateTime = (timestamp as Timestamp).toDate();
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      if (difference.inDays == 1) return 'Ayer';
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }
}
