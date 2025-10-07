import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../services/contact_alias_service.dart';
import '../services/media_service.dart';
import '../services/reaction_service.dart';
import '../widgets/reaction_picker.dart';
import 'group_profile/group_profile_screen.dart';

class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();
  final TypingIndicatorService _typingService = TypingIndicatorService();
  final ContactAliasService _aliasService = ContactAliasService();
  final MediaService _mediaService = MediaService();
  final ReactionService _reactionService = ReactionService();

  // Paginación de mensajes
  static const int _messagesPerPage = 30;
  DocumentSnapshot? _lastDocument;
  bool _hasMoreMessages = true;
  bool _isLoadingMore = false;
  final List<DocumentSnapshot> _loadedMessages = [];
  int _lastMessageCount = 0;

  // Cache de nombres de usuarios
  final Map<String, String> _userNames = {};
  final Map<String, String> _userPhotos = {};

  // Control de emoji picker
  bool _showEmojiPicker = false;

  // Control de grabación de audio
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _audioPath;

  // Control de respuesta (reply)
  Map<String, dynamic>? _replyingTo;
  OverlayEntry? _reactionOverlay;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTypingChanged);
    _loadGroupMembers();
  }

  @override
  void dispose() {
    _typingService.stopTyping();
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _onTypingChanged() {
    if (_messageController.text.isNotEmpty) {
      _typingService.setTyping(widget.groupId, true, isGroup: true);
    } else {
      _typingService.setTyping(widget.groupId, false, isGroup: true);
    }
    setState(() {}); // Actualizar UI del botón
  }

  void _onScroll() {
    if (_scrollController.position.pixels <= 100 &&
        _hasMoreMessages &&
        !_isLoadingMore) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadGroupMembers() async {
    try {
      final groupDoc = await _firestore.collection('groups').doc(widget.groupId).get();
      final members = List<String>.from(groupDoc.data()?['members'] ?? []);

      for (final memberId in members) {
        final userDoc = await _firestore.collection('users').doc(memberId).get();
        final userData = userDoc.data();
        if (userData != null) {
          final realName = userData['name'] ?? 'Usuario';
          final displayName = await _aliasService.getDisplayName(memberId, realName);
          setState(() {
            _userNames[memberId] = displayName;
            _userPhotos[memberId] = userData['photoURL'] ?? '';
          });
        }
      }
    } catch (e) {
      print('❌ Error cargando miembros del grupo: $e');
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      Query query = _firestore
          .collection('groups')
          .doc(widget.groupId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(_messagesPerPage);

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();

      if (snapshot.docs.isEmpty) {
        setState(() {
          _hasMoreMessages = false;
          _isLoadingMore = false;
        });
        return;
      }

      setState(() {
        _loadedMessages.addAll(snapshot.docs);
        _lastDocument = snapshot.docs.last;
        _hasMoreMessages = snapshot.docs.length == _messagesPerPage;
        _isLoadingMore = false;
      });

      print('📥 Cargados ${snapshot.docs.length} mensajes más antiguos del grupo');
    } catch (e) {
      print('❌ Error cargando más mensajes: $e');
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  void _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final messageText = _messageController.text.trim();
    final currentUserId = _auth.currentUser!.uid;

    _messageController.clear();

    try {
      // Enviar mensaje a Firestore
      final messageData = {
        'senderId': currentUserId,
        'text': messageText,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      };

      // Agregar información de reply si existe
      if (_replyingTo != null) {
        messageData['replyTo'] = {
          'messageId': _replyingTo!['id'],
          'text': _replyingTo!['text'] ?? '',
          'senderId': _replyingTo!['senderId'],
          'senderName': _replyingTo!['senderName'] ?? 'Usuario',
        };
      }

      await _firestore
          .collection('groups')
          .doc(widget.groupId)
          .collection('messages')
          .add(messageData);

      // Limpiar reply
      setState(() {
        _replyingTo = null;
      });

      // Actualizar último mensaje del grupo
      await _firestore.collection('groups').doc(widget.groupId).update({
        'lastMessage': messageText,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': currentUserId,
        'lastActivity': FieldValue.serverTimestamp(),
        'messageCount': FieldValue.increment(1),
      });

      // Obtener datos del usuario actual para notificaciones
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final userData = currentUserDoc.data();
      final senderName = userData?['name'] ?? 'Usuario';
      final senderPhotoUrl = userData?['photoURL'];

      // Obtener lista de miembros del grupo para enviar notificaciones
      final groupDoc = await _firestore.collection('groups').doc(widget.groupId).get();
      final members = List<String>.from(groupDoc.data()?['members'] ?? []);

      // Enviar notificación a todos los miembros excepto al remitente
      for (final memberId in members) {
        if (memberId != currentUserId) {
          try {
            await _notificationService.sendChatMessageNotification(
              recipientId: memberId,
              senderId: currentUserId,
              senderName: senderName,
              senderPhotoUrl: senderPhotoUrl,
              messageText: messageText,
              chatId: widget.groupId,
              isGroup: true,
              groupName: widget.groupName,
            );
          } catch (e) {
            print('⚠️ Error enviando notificación a $memberId: $e');
          }
        }
      }

      print('✅ Mensaje enviado al grupo exitosamente');
    } catch (e) {
      print('❌ Error enviando mensaje al grupo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar mensaje'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => GroupProfileScreen(groupId: widget.groupId),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.groupName, style: TextStyle(fontSize: 16)),
              StreamBuilder<DocumentSnapshot>(
                stream: _firestore
                    .collection('groups')
                    .doc(widget.groupId)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return SizedBox();
                  final groupData = snapshot.data!.data() as Map<String, dynamic>?;
                  final memberCount = (groupData?['members'] as List?)?.length ?? 0;
                  return Text(
                    '$memberCount miembros',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onPrimary.withValues(alpha: 0.7),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.info_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => GroupProfileScreen(groupId: widget.groupId),
                ),
              );
            },
            tooltip: 'Perfil del grupo',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('groups')
                  .doc(widget.groupId)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .limit(_messagesPerPage)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error: ${snapshot.error}'),
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting &&
                    _loadedMessages.isEmpty) {
                  return Center(child: CircularProgressIndicator());
                }

                final recentMessages = snapshot.data?.docs ?? [];
                final recentIds = recentMessages.map((doc) => doc.id).toSet();
                final olderMessages = _loadedMessages
                    .where((doc) => !recentIds.contains(doc.id))
                    .toList();

                final allMessages = [...recentMessages, ...olderMessages];

                if (allMessages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.group_outlined,
                          size: 64,
                          color: colorScheme.outlineVariant,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Comienza la conversación grupal',
                          style: TextStyle(
                            fontSize: 16,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                final hasLoader = _isLoadingMore ? 1 : 0;
                final totalCount = allMessages.length + hasLoader;

                return ListView.builder(
                  controller: _scrollController,
                  reverse: true, // Empieza desde abajo naturalmente
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  itemCount: totalCount,
                  itemBuilder: (context, index) {
                    // Primero mensajes (orden descendente = más recientes primero)
                    if (index < allMessages.length) {
                      final messageDoc = allMessages[index];
                      final messageData =
                          messageDoc.data() as Map<String, dynamic>;
                      final senderId = messageData['senderId'] ?? '';
                      final isMe = senderId == _auth.currentUser!.uid;
                      final timestamp = messageData['timestamp'] as Timestamp?;
                      final timeString = timestamp != null
                          ? '${timestamp.toDate().hour}:${timestamp.toDate().minute.toString().padLeft(2, '0')}'
                          : '';

                      final senderName = _userNames[senderId] ?? 'Usuario';

                      return _buildGroupMessageBubble(
                        key: ValueKey('msg_${messageDoc.id}'),
                        messageId: messageDoc.id,
                        text: messageData['text'],
                        imageUrl: messageData['imageUrl'],
                        videoUrl: messageData['videoUrl'],
                        audioUrl: messageData['audioUrl'],
                        replyTo: messageData['replyTo'],
                        reactions: messageData['reactions'],
                        isMe: isMe,
                        time: timeString,
                        senderName: senderName,
                        senderId: senderId,
                      );
                    }

                    // Loader al final si está cargando más
                    return Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Indicador de escritura para grupos
          _buildGroupTypingIndicator(),
          // Reply bar
          if (_replyingTo != null) _buildReplyBar(),
          _buildMessageInput(),
          // Emoji Picker
          if (_showEmojiPicker) _buildEmojiPicker(),
        ],
      ),
    );
  }

  Widget _buildGroupTypingIndicator() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('groups')
          .doc(widget.groupId)
          .collection('typing')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return SizedBox.shrink();
        }

        final currentUserId = _auth.currentUser!.uid;
        final now = DateTime.now();

        // Filtrar usuarios que están escribiendo (excluyendo al usuario actual)
        final typingUsers = snapshot.data!.docs.where((doc) {
          if (doc.id == currentUserId) return false;

          final data = doc.data() as Map<String, dynamic>;
          final isTyping = data['isTyping'] as bool? ?? false;
          final timestamp = data['timestamp'] as Timestamp?;

          if (!isTyping || timestamp == null) return false;

          // Solo considerar válido si fue en los últimos 5 segundos
          final diff = now.difference(timestamp.toDate());
          return diff.inSeconds < 5;
        }).toList();

        if (typingUsers.isEmpty) {
          return SizedBox.shrink();
        }

        // Obtener nombres de usuarios que están escribiendo
        final typingNames = typingUsers
            .map((doc) => _userNames[doc.id] ?? 'Alguien')
            .toList();

        String typingText;
        if (typingNames.length == 1) {
          typingText = '${typingNames[0]} está escribiendo...';
        } else if (typingNames.length == 2) {
          typingText = '${typingNames[0]} y ${typingNames[1]} están escribiendo...';
        } else if (typingNames.length == 3) {
          typingText = '${typingNames[0]}, ${typingNames[1]} y ${typingNames[2]} están escribiendo...';
        } else {
          typingText = '${typingNames[0]}, ${typingNames[1]} y ${typingNames.length - 2} más están escribiendo...';
        }

        final colorScheme = Theme.of(context).colorScheme;

        return Container(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          color: colorScheme.surfaceVariant.withValues(alpha: 0.3),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  typingText,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReplyBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode ? Color(0xFF1C1B1F) : colorScheme.surface,
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 40,
              color: colorScheme.primary,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Respondiendo a ${_replyingTo!['senderName']}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: colorScheme.primary,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    _replyingTo!['text'] ?? '',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 20),
              color: colorScheme.onSurfaceVariant,
              onPressed: () {
                setState(() {
                  _replyingTo = null;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupMessageBubble({
    Key? key,
    required String messageId,
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? audioUrl,
    Map<String, dynamic>? replyTo,
    Map<String, dynamic>? reactions,
    required bool isMe,
    required String time,
    required String senderName,
    required String senderId,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Align(
      key: key,
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Dismissible(
        key: Key('group_dismiss_$messageId'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (direction) async {
          setState(() {
            _replyingTo = {
              'id': messageId,
              'text': text ?? '',
              'senderId': senderId,
              'senderName': senderName,
            };
          });
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.only(left: 20),
          child: Icon(
            Icons.reply,
            color: colorScheme.primary,
            size: 30,
          ),
        ),
        child: GestureDetector(
          onLongPress: () => _showReactionPicker(context, messageId),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
          // Mostrar nombre del remitente solo si no es el usuario actual
          if (!isMe)
            Padding(
              padding: EdgeInsets.only(left: 12, bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: colorScheme.primaryContainer,
                    backgroundImage: _userPhotos[senderId] != null &&
                            _userPhotos[senderId]!.isNotEmpty
                        ? NetworkImage(_userPhotos[senderId]!)
                        : null,
                    child: _userPhotos[senderId] == null ||
                            _userPhotos[senderId]!.isEmpty
                        ? Text(
                            senderName.isNotEmpty
                                ? senderName[0].toUpperCase()
                                : 'U',
                            style: TextStyle(
                              fontSize: 10,
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: 8),
                  Text(
                    senderName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          Container(
            margin: EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            decoration: BoxDecoration(
              color: isMe ? colorScheme.primary : colorScheme.surfaceVariant,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: isMe ? Radius.circular(16) : Radius.circular(4),
                bottomRight: isMe ? Radius.circular(4) : Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Reply preview
                if (replyTo != null) ...[
                  Container(
                    padding: EdgeInsets.all(8),
                    margin: EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: (isMe ? Colors.white : colorScheme.primary).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(
                        left: BorderSide(
                          color: isMe ? Colors.white : colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          replyTo['senderName'] ?? 'Usuario',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: isMe ? Colors.white : colorScheme.primary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          replyTo['text'] ?? '',
                          style: TextStyle(
                            fontSize: 12,
                            color: isMe
                                ? Colors.white.withValues(alpha: 0.8)
                                : colorScheme.onSurface.withValues(alpha: 0.8),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
                // Imagen
                if (imageUrl != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      imageUrl,
                      width: MediaQuery.of(context).size.width * 0.6,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          width: MediaQuery.of(context).size.width * 0.6,
                          height: 200,
                          color: colorScheme.surfaceContainerHighest,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          width: MediaQuery.of(context).size.width * 0.6,
                          height: 200,
                          color: colorScheme.errorContainer,
                          child: Icon(Icons.error, color: colorScheme.error),
                        );
                      },
                    ),
                  ),
                  if (text != null && text.isNotEmpty) SizedBox(height: 8),
                ],
                // Video
                if (videoUrl != null) ...[
                  Container(
                    width: MediaQuery.of(context).size.width * 0.6,
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(Icons.play_circle_outline, size: 64, color: Colors.white),
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '🎥 Video',
                              style: TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (text != null && text.isNotEmpty) SizedBox(height: 8),
                ],
                // Audio
                if (audioUrl != null) ...[
                  _AudioPlayerWidget(
                    audioUrl: audioUrl,
                    isMe: isMe,
                    colorScheme: colorScheme,
                  ),
                  if (text != null && text.isNotEmpty) SizedBox(height: 8),
                ],
                // Texto
                if (text != null && text.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      text,
                      style: TextStyle(
                        color: isMe ? Colors.white : colorScheme.onSurface,
                        fontSize: 15,
                      ),
                    ),
                  ),
                SizedBox(height: 4),
                // Timestamp
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    time,
                    style: TextStyle(
                      color: isMe
                          ? Colors.white.withValues(alpha: 0.9)
                          : colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Reacciones
          if (reactions != null && reactions.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 4, left: isMe ? 0 : 12),
              child: Wrap(
                spacing: 4,
                children: reactions.entries.map((entry) {
                  final reaction = entry.key;
                  final users = entry.value as List;
                  final count = users.length;
                  final hasReacted = users.contains(_auth.currentUser?.uid);

                  return GestureDetector(
                    onTap: () => _reactionService.toggleReaction(
                      chatId: widget.groupId,
                      messageId: messageId,
                      reaction: reaction,
                      isGroup: true,
                    ),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: hasReacted
                            ? colorScheme.primary.withValues(alpha: 0.2)
                            : (isDarkMode
                                ? colorScheme.surfaceContainerHighest
                                : Colors.grey.withValues(alpha: 0.2)),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: hasReacted
                              ? colorScheme.primary
                              : Colors.transparent,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(reaction, style: TextStyle(fontSize: 16)),
                          if (count > 1) ...[
                            SizedBox(width: 4),
                            Text(
                              count.toString(),
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  void _showReactionPicker(BuildContext context, String messageId) {
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);

    _reactionOverlay?.remove();
    _reactionOverlay = OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: () {
          _reactionOverlay?.remove();
          _reactionOverlay = null;
        },
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                top: position.dy - 60,
                left: position.dx,
                child: Material(
                  color: Colors.transparent,
                  child: ReactionPicker(
                    onReactionSelected: (reaction) {
                      _reactionOverlay?.remove();
                      _reactionOverlay = null;
                      _reactionService.toggleReaction(
                        chatId: widget.groupId,
                        messageId: messageId,
                        reaction: reaction,
                        isGroup: true,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_reactionOverlay!);

    Future.delayed(Duration(seconds: 5), () {
      _reactionOverlay?.remove();
      _reactionOverlay = null;
    });
  }

  Widget _buildMessageInput() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode ? Color(0xFF1C1B1F) : colorScheme.surface,
      child: SafeArea(
        child: Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.transparent,
          ),
          child: Row(
          children: [
            Expanded(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    // Botón emoji
                    IconButton(
                      icon: Icon(
                        _showEmojiPicker
                            ? Icons.emoji_emotions
                            : Icons.emoji_emotions_outlined,
                        size: 22,
                      ),
                      color: _showEmojiPicker
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      padding: EdgeInsets.all(8),
                      constraints: BoxConstraints(),
                      onPressed: () {
                        setState(() {
                          _showEmojiPicker = !_showEmojiPicker;
                        });
                      },
                      tooltip: 'Emojis',
                    ),
                    // TextField de mensaje
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        style: TextStyle(color: colorScheme.onSurface),
                        decoration: InputDecoration(
                          hintText: 'Escribe un mensaje al grupo...',
                          hintStyle: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            overflow: TextOverflow.ellipsis,
                          ),
                          fillColor: Colors.transparent,
                          filled: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                        ),
                        maxLines: 1,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    // Botón adjuntar
                    IconButton(
                      icon: Icon(Icons.attach_file, size: 22),
                      color: colorScheme.onSurfaceVariant,
                      padding: EdgeInsets.all(8),
                      constraints: BoxConstraints(),
                      onPressed: _showAttachmentOptions,
                      tooltip: 'Adjuntar',
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: 8),
            // Botón enviar o micrófono
            Container(
              decoration: BoxDecoration(
                color: colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  _isRecording
                      ? Icons.stop
                      : _messageController.text.trim().isEmpty
                          ? Icons.mic
                          : Icons.send,
                  color: Colors.white,
                ),
                onPressed: () {
                  if (_isRecording) {
                    _stopRecording();
                  } else if (_messageController.text.trim().isEmpty) {
                    _startRecording();
                  } else {
                    _sendMessage();
                  }
                },
                tooltip: _isRecording
                    ? 'Detener grabación'
                    : _messageController.text.trim().isEmpty
                        ? 'Grabar audio'
                        : 'Enviar',
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiPicker() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 250,
      child: EmojiPicker(
        onEmojiSelected: (category, emoji) {
          _messageController.text += emoji.emoji;
        },
        config: Config(
          height: 250,
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            columns: 7,
            emojiSizeMax: 32.0,
            verticalSpacing: 0,
            horizontalSpacing: 0,
            gridPadding: EdgeInsets.zero,
            backgroundColor: isDarkMode
                ? colorScheme.surface
                : Color(0xFFF2F2F2),
            buttonMode: ButtonMode.MATERIAL,
            recentsLimit: 28,
            noRecents: Text(
              'Sin emojis recientes',
              style: TextStyle(fontSize: 20, color: Colors.black26),
              textAlign: TextAlign.center,
            ),
            loadingIndicator: const SizedBox.shrink(),
          ),
          skinToneConfig: SkinToneConfig(
            enabled: true,
            dialogBackgroundColor: Colors.white,
            indicatorColor: Colors.grey,
          ),
          categoryViewConfig: CategoryViewConfig(
            initCategory: Category.RECENT,
            indicatorColor: colorScheme.primary,
            iconColor: Colors.grey,
            iconColorSelected: colorScheme.primary,
            backspaceColor: colorScheme.primary,
            tabIndicatorAnimDuration: kTabScrollDuration,
            categoryIcons: const CategoryIcons(),
          ),
        ),
      ),
    );
  }

  void _showAttachmentOptions() {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enviar archivo',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildAttachmentOption(
                  icon: Icons.photo_camera,
                  label: 'Cámara',
                  color: Colors.pink,
                  onTap: () {
                    Navigator.pop(context);
                    _sendImage(ImageSource.camera);
                  },
                ),
                _buildAttachmentOption(
                  icon: Icons.photo_library,
                  label: 'Galería',
                  color: Colors.purple,
                  onTap: () {
                    Navigator.pop(context);
                    _sendImage(ImageSource.gallery);
                  },
                ),
                _buildAttachmentOption(
                  icon: Icons.videocam,
                  label: 'Video',
                  color: Colors.red,
                  onTap: () {
                    Navigator.pop(context);
                    _sendVideo();
                  },
                ),
              ],
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 32),
          ),
          SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _sendImage(ImageSource source) async {
    final currentUserId = _auth.currentUser!.uid;

    try {
      final imageUrl = await _mediaService.uploadImage(
        source: source,
        chatId: widget.groupId,
        userId: currentUserId,
      );

      if (imageUrl != null) {
        await _firestore
            .collection('groups')
            .doc(widget.groupId)
            .collection('messages')
            .add({
          'senderId': currentUserId,
          'imageUrl': imageUrl,
          'type': 'image',
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
        });

        await _firestore.collection('groups').doc(widget.groupId).update({
          'lastMessage': '📷 Imagen',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': currentUserId,
        });

        print('✅ Imagen enviada al grupo exitosamente');
      }
    } catch (e) {
      print('❌ Error enviando imagen al grupo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar imagen'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _sendVideo() async {
    final currentUserId = _auth.currentUser!.uid;

    try {
      final videoUrl = await _mediaService.uploadVideo(
        chatId: widget.groupId,
        userId: currentUserId,
      );

      if (videoUrl != null) {
        await _firestore
            .collection('groups')
            .doc(widget.groupId)
            .collection('messages')
            .add({
          'senderId': currentUserId,
          'videoUrl': videoUrl,
          'type': 'video',
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
        });

        await _firestore.collection('groups').doc(widget.groupId).update({
          'lastMessage': '🎥 Video',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': currentUserId,
        });

        print('✅ Video enviado al grupo exitosamente');
      }
    } catch (e) {
      print('❌ Error enviando video al grupo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar video'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getApplicationDocumentsDirectory();
        final path = '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: path,
        );

        setState(() {
          _isRecording = true;
          _audioPath = path;
        });

        print('🎤 Iniciando grabación de audio');
      }
    } catch (e) {
      print('❌ Error iniciando grabación: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar grabación'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() {
        _isRecording = false;
      });

      if (path != null && path.isNotEmpty) {
        await _sendAudio(path);
      }

      print('🛑 Grabación detenida');
    } catch (e) {
      print('❌ Error deteniendo grabación: $e');
    }
  }

  Future<void> _sendAudio(String audioPath) async {
    final currentUserId = _auth.currentUser!.uid;

    try {
      final audioUrl = await _mediaService.uploadAudio(
        audioPath: audioPath,
        chatId: widget.groupId,
        userId: currentUserId,
      );

      if (audioUrl != null) {
        await _firestore
            .collection('groups')
            .doc(widget.groupId)
            .collection('messages')
            .add({
          'senderId': currentUserId,
          'audioUrl': audioUrl,
          'type': 'audio',
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
        });

        await _firestore.collection('groups').doc(widget.groupId).update({
          'lastMessage': '🎤 Audio',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': currentUserId,
        });

        print('✅ Audio enviado al grupo exitosamente');
      }
    } catch (e) {
      print('❌ Error enviando audio al grupo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar audio'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showGroupInfo() async {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    try {
      final groupDoc = await _firestore.collection('groups').doc(widget.groupId).get();
      final groupData = groupDoc.data();

      if (groupData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo cargar la información del grupo')),
          );
        }
        return;
      }

      final members = List<String>.from(groupData['members'] ?? []);
      final admins = List<String>.from(groupData['admins'] ?? []);
      final description = groupData['description'] ?? '';
      final currentUserId = _auth.currentUser!.uid;
      final isAdmin = admins.contains(currentUserId);

      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: colorScheme.onPrimary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Text(
                      widget.groupName,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimary,
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      SizedBox(height: 8),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onPrimary.withValues(alpha: 0.7),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    SizedBox(height: 8),
                    Text(
                      '${members.length} miembros',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onPrimary.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: EdgeInsets.all(16),
                  children: [
                    Text(
                      'Miembros',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 12),
                    ...members.map((memberId) {
                      final isUserAdmin = admins.contains(memberId);
                      final userName = _userNames[memberId] ?? 'Cargando...';
                      final userPhoto = _userPhotos[memberId] ?? '';

                      return StreamBuilder<String>(
                        stream: _aliasService.watchDisplayName(memberId, userName),
                        initialData: userName,
                        builder: (context, snapshot) {
                          final displayName = snapshot.data ?? userName;

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: colorScheme.primaryContainer,
                              backgroundImage: userPhoto.isNotEmpty
                                  ? NetworkImage(userPhoto)
                                  : null,
                              child: userPhoto.isEmpty
                                  ? Text(
                                      displayName.isNotEmpty
                                          ? displayName[0].toUpperCase()
                                          : 'U',
                                      style: TextStyle(
                                        color: colorScheme.primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                            title: Text(displayName),
                            subtitle: isUserAdmin ? Text('Admin') : null,
                            trailing: memberId == currentUserId
                                ? Text(
                                    'Tú',
                                    style: TextStyle(
                                      color: colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : null,
                          );
                        },
                      );
                    }).toList(),
                    SizedBox(height: 24),
                    if (!isAdmin)
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _leaveGroup();
                        },
                        icon: Icon(Icons.exit_to_app),
                        label: Text('Salir del grupo'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      print('❌ Error mostrando información del grupo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar información del grupo')),
        );
      }
    }
  }

  void _leaveGroup() async {
    try {
      final currentUserId = _auth.currentUser!.uid;

      // Confirmar con el usuario
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Salir del grupo'),
          content: Text('¿Estás seguro de que quieres salir de ${widget.groupName}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text('Salir'),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      // Remover al usuario de la lista de miembros
      await _firestore.collection('groups').doc(widget.groupId).update({
        'members': FieldValue.arrayRemove([currentUserId]),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Has salido del grupo'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      print('❌ Error saliendo del grupo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al salir del grupo'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Widget para reproducir audio
class _AudioPlayerWidget extends StatefulWidget {
  final String audioUrl;
  final bool isMe;
  final ColorScheme colorScheme;

  const _AudioPlayerWidget({
    required this.audioUrl,
    required this.isMe,
    required this.colorScheme,
  });

  @override
  State<_AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<_AudioPlayerWidget> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _audioPlayer.onDurationChanged.listen((duration) {
      setState(() {
        _duration = duration;
      });
    });

    _audioPlayer.onPositionChanged.listen((position) {
      setState(() {
        _position = position;
      });
    });

    _audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        _isPlaying = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      setState(() {
        _isPlaying = false;
      });
    } else {
      await _audioPlayer.play(UrlSource(widget.audioUrl));
      setState(() {
        _isPlaying = true;
      });
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Botón play/pause
          IconButton(
            icon: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: widget.isMe ? Colors.white : widget.colorScheme.primary,
            ),
            onPressed: _togglePlayPause,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(),
          ),
          SizedBox(width: 8),
          // Barra de progreso
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                    trackHeight: 3,
                    overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: _position.inSeconds.toDouble(),
                    max: _duration.inSeconds.toDouble() > 0
                        ? _duration.inSeconds.toDouble()
                        : 1.0,
                    onChanged: (value) async {
                      final position = Duration(seconds: value.toInt());
                      await _audioPlayer.seek(position);
                    },
                    activeColor:
                        widget.isMe ? Colors.white : widget.colorScheme.primary,
                    inactiveColor: widget.isMe
                        ? Colors.white.withValues(alpha: 0.3)
                        : widget.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.isMe
                          ? Colors.white.withValues(alpha: 0.7)
                          : widget.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Icono de audio
          Icon(
            Icons.mic,
            size: 20,
            color: widget.isMe
                ? Colors.white.withValues(alpha: 0.7)
                : widget.colorScheme.primary.withValues(alpha: 0.7),
          ),
        ],
      ),
    );
  }
}
