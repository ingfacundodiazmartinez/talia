import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../../groups/groups.dart'; // Groups V2
import '../../../../models/chat_message.dart';
import '../../../../widgets/message_status_indicator.dart';

class GroupChatListItem extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String lastMessage;
  final int memberCount;
  final int messageCount;
  final String? groupImageUrl;
  final int unreadCount;
  final VoidCallback? onLeaveGroup;
  // Campos para indicador de estado del último mensaje
  final String? lastMessageSenderId;
  final MessageStatus? lastMessageStatus;
  final ModerationStatus? lastMessageModerationStatus;

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
    this.lastMessageSenderId,
    this.lastMessageStatus,
    this.lastMessageModerationStatus,
  });


  @override
  Widget build(BuildContext context) {
    final firestore = FirebaseFirestore.instance;
    final auth = FirebaseAuth.instance;

    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: ClipRect(
        child: Container(
          color: colorScheme.primary,
          child: Slidable(
        key: Key('group_$groupId'),
        closeOnScroll: false,
        endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.2,
        openThreshold: 0.1,
        closeThreshold: 0.1,
        children: [
          Expanded(
            child: Container(
              color: colorScheme.primary,
              child: GestureDetector(
                onTap: () => onLeaveGroup?.call(),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.exit_to_app_outlined, color: Colors.white, size: 24),
                    const SizedBox(height: 4),
                    Text(
                      'Salir',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
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
                builder: (context) => GroupChatScreenV2(
                  groupId: groupId,
                  groupName: groupName,
                ),
              ),
            );
          },
          child: Container(
          padding: EdgeInsets.all(12),
          color: unreadCount > 0
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : colorScheme.surface,
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Color(0xFF4CAF50).withValues(alpha: 0.2),
                backgroundImage: groupImageUrl != null && groupImageUrl!.isNotEmpty
                    ? CachedNetworkImageProvider(groupImageUrl!)
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
                        if (unreadCount > 0) ...[
                          Container(
                            padding: EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              unreadCount.toString(),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          SizedBox(width: 8),
                        ],
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
                          .collection('groups_v2')
                          .doc(groupId)
                          .collection('typing')
                          .snapshots(),
                      builder: (context, typingSnapshot) {
                        // Si hay error de permisos, mostrar el último mensaje
                        if (typingSnapshot.hasError) {
                          final currentUserId = auth.currentUser?.uid ?? '';
                          final isOwnMessage = lastMessageSenderId == currentUserId;

                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isOwnMessage && lastMessageStatus != null) ...[
                                MessageStatusIndicator(
                                  status: lastMessageStatus!,
                                  moderationStatus: lastMessageModerationStatus,
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  lastMessage,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          );
                        }

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

                        // Mostrar lastMessage con indicador de estado (si es mensaje propio)
                        final currentUserId = auth.currentUser?.uid ?? '';
                        final isOwnMessage = lastMessageSenderId == currentUserId;

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Indicador de estado (solo para mensajes propios) - ANTES del texto
                            if (isOwnMessage && lastMessageStatus != null) ...[
                              MessageStatusIndicator(
                                status: lastMessageStatus!,
                                moderationStatus: lastMessageModerationStatus,
                                size: 12,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                lastMessage,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            ],
          ),
          ),
        ),
        ),
        ),
      ),
    );
  }
}
