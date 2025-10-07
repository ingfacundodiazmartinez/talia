import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../screens/group_chat_screen.dart';

class GroupChatListItem extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String lastMessage;
  final int memberCount;
  final int messageCount;
  final String? groupImageUrl;
  final VoidCallback? onLeaveGroup;

  const GroupChatListItem({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.lastMessage,
    required this.memberCount,
    required this.messageCount,
    this.groupImageUrl,
    this.onLeaveGroup,
  });

  @override
  Widget build(BuildContext context) {
    final firestore = FirebaseFirestore.instance;
    final auth = FirebaseAuth.instance;

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
            CircleAvatar(
              radius: 28,
              backgroundColor: Color(0xFF4CAF50).withValues(alpha: 0.2),
              backgroundImage: groupImageUrl != null && groupImageUrl!.isNotEmpty
                  ? NetworkImage(groupImageUrl!)
                  : null,
              child: groupImageUrl == null || groupImageUrl!.isEmpty
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          groupName,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Color(0xFF4CAF50).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$memberCount miembros',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF4CAF50),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  StreamBuilder<QuerySnapshot>(
                    stream: firestore
                        .collection('groups')
                        .doc(groupId)
                        .collection('typing')
                        .snapshots(),
                    builder: (context, typingSnapshot) {
                      if (typingSnapshot.hasData && typingSnapshot.data!.docs.isNotEmpty) {
                        final currentUserId = auth.currentUser!.uid;
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
                          // Obtener nombres de los usuarios que están escribiendo
                          return FutureBuilder<List<String>>(
                            future: Future.wait<String>(
                              typingUserIds.map<Future<String>>((userId) async {
                                try {
                                  final userDoc = await firestore.collection('users').doc(userId).get();
                                  return userDoc.data()?['name'] as String? ?? 'Alguien';
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

                      return Text(
                        lastMessage,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ],
              ),
            ),
            if (onLeaveGroup != null)
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'leave') {
                    onLeaveGroup?.call();
                  }
                },
                itemBuilder: (BuildContext context) => [
                  PopupMenuItem<String>(
                    value: 'leave',
                    child: Row(
                      children: [
                        Icon(Icons.exit_to_app, size: 20, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Salir del grupo', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
