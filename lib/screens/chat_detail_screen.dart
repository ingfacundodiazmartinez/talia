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
import 'contact_profile_screen.dart';

class ChatDetailScreen extends StatefulWidget {
  final String contactId;
  final String contactName;
  final String chatId;

  const ChatDetailScreen({
    super.key,
    required this.contactId,
    required this.contactName,
    required this.chatId,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
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

  // Información del contacto
  String _contactPhotoURL = '';
  bool _contactIsOnline = false;

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
    _loadContactInfo();
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
      _typingService.setTyping(widget.chatId, true, isGroup: false);
    } else {
      _typingService.setTyping(widget.chatId, false, isGroup: false);
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

  Future<void> _loadContactInfo() async {
    try {
      final userDoc = await _firestore
          .collection('users')
          .doc(widget.contactId)
          .get();
      final userData = userDoc.data();
      if (userData != null && mounted) {
        setState(() {
          _contactPhotoURL = userData['photoURL'] ?? '';
          _contactIsOnline = userData['isOnline'] ?? false;
        });
      }
    } catch (e) {
      print('❌ Error cargando info del contacto: $e');
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      Query query = _firestore
          .collection('chats')
          .doc(widget.chatId)
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

      print(
        '📥 Cargados ${snapshot.docs.length} mensajes más antiguos del chat',
      );
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
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add(messageData);

      // Limpiar reply
      setState(() {
        _replyingTo = null;
      });

      // Actualizar o crear documento del chat
      await _firestore.collection('chats').doc(widget.chatId).set({
        'participants': [currentUserId, widget.contactId],
        'lastMessage': messageText,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': currentUserId,
        'deletedBy': [], // Lista vacía para soft delete
      }, SetOptions(merge: true));

      // Obtener datos del usuario actual para notificaciones
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final userData = currentUserDoc.data();
      final senderName = userData?['name'] ?? 'Usuario';
      final senderPhotoUrl = userData?['photoURL'];

      // Enviar notificación al contacto
      try {
        await _notificationService.sendChatMessageNotification(
          recipientId: widget.contactId,
          senderId: currentUserId,
          senderName: senderName,
          senderPhotoUrl: senderPhotoUrl,
          messageText: messageText,
          chatId: widget.chatId,
          isGroup: false,
        );
      } catch (e) {
        print('⚠️ Error enviando notificación: $e');
      }

      print('✅ Mensaje enviado exitosamente');
    } catch (e) {
      print('❌ Error enviando mensaje: $e');
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
          Text(label, style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _sendImage(ImageSource source) async {
    final currentUserId = _auth.currentUser!.uid;

    try {
      final imageUrl = await _mediaService.uploadImage(
        source: source,
        chatId: widget.chatId,
        userId: currentUserId,
      );

      if (imageUrl != null) {
        await _firestore
            .collection('chats')
            .doc(widget.chatId)
            .collection('messages')
            .add({
              'senderId': currentUserId,
              'imageUrl': imageUrl,
              'type': 'image',
              'timestamp': FieldValue.serverTimestamp(),
              'isRead': false,
            });

        await _firestore.collection('chats').doc(widget.chatId).set({
          'participants': [currentUserId, widget.contactId],
          'lastMessage': '📷 Imagen',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': currentUserId,
          'deletedBy': [],
        }, SetOptions(merge: true));

        print('✅ Imagen enviada exitosamente');
      }
    } catch (e) {
      print('❌ Error enviando imagen: $e');
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
        chatId: widget.chatId,
        userId: currentUserId,
      );

      if (videoUrl != null) {
        await _firestore
            .collection('chats')
            .doc(widget.chatId)
            .collection('messages')
            .add({
              'senderId': currentUserId,
              'videoUrl': videoUrl,
              'type': 'video',
              'timestamp': FieldValue.serverTimestamp(),
              'isRead': false,
            });

        await _firestore.collection('chats').doc(widget.chatId).set({
          'participants': [currentUserId, widget.contactId],
          'lastMessage': '🎥 Video',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': currentUserId,
          'deletedBy': [],
        }, SetOptions(merge: true));

        print('✅ Video enviado exitosamente');
      }
    } catch (e) {
      print('❌ Error enviando video: $e');
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
        chatId: widget.chatId,
        userId: currentUserId,
      );

      if (audioUrl != null) {
        await _firestore
            .collection('chats')
            .doc(widget.chatId)
            .collection('messages')
            .add({
              'senderId': currentUserId,
              'audioUrl': audioUrl,
              'type': 'audio',
              'timestamp': FieldValue.serverTimestamp(),
              'isRead': false,
            });

        await _firestore.collection('chats').doc(widget.chatId).set({
          'participants': [currentUserId, widget.contactId],
          'lastMessage': '🎤 Audio',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': currentUserId,
          'deletedBy': [],
        }, SetOptions(merge: true));

        print('✅ Audio enviado exitosamente');
      }
    } catch (e) {
      print('❌ Error enviando audio: $e');
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
                builder: (context) => ContactProfileScreen(
                  contactId: widget.contactId,
                  contactName: widget.contactName,
                ),
              ),
            );
          },
          child: Row(
            children: [
              // Avatar del contacto
              CircleAvatar(
                radius: 18,
                backgroundColor: colorScheme.primaryContainer,
                backgroundImage: _contactPhotoURL.isNotEmpty
                    ? NetworkImage(_contactPhotoURL)
                    : null,
                child: _contactPhotoURL.isEmpty
                    ? Text(
                        widget.contactName.isNotEmpty
                            ? widget.contactName[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
              SizedBox(width: 12),
              // Nombre y estado
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.contactName,
                      style: TextStyle(fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    StreamBuilder<DocumentSnapshot>(
                      stream: _firestore
                          .collection('users')
                          .doc(widget.contactId)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) return SizedBox();
                        final userData =
                            snapshot.data!.data() as Map<String, dynamic>?;
                        final isOnline = userData?['isOnline'] ?? false;

                        return Row(
                          children: [
                            if (isOnline) ...[
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              SizedBox(width: 4),
                            ],
                            Text(
                              isOnline ? 'En línea' : 'Desconectado',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDarkMode
                                    ? colorScheme.onSurface.withValues(
                                        alpha: 0.7,
                                      )
                                    : colorScheme.onPrimary.withValues(
                                        alpha: 0.7,
                                      ),
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
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor: isDarkMode
            ? colorScheme.onSurface
            : colorScheme.onPrimary,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('chats')
                  .doc(widget.chatId)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .limit(_messagesPerPage)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
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
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: colorScheme.outlineVariant,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Comienza la conversación',
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
                  reverse: true,
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  itemCount: totalCount,
                  itemBuilder: (context, index) {
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

                      return _buildMessageBubble(
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
                        senderId: senderId,
                        senderName: widget.contactName,
                      );
                    }

                    // Loader al final si está cargando más
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Indicador de escritura
          StreamBuilder<bool>(
            stream: _typingService.watchOtherUserTyping(
              widget.chatId,
              widget.contactId,
            ),
            builder: (context, snapshot) {
              final isTyping = snapshot.data ?? false;

              if (!isTyping) {
                return SizedBox();
              }

              return Container(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colorScheme.primary,
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      '${widget.contactName} está escribiendo...',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // Reply bar
          if (_replyingTo != null)
            Container(
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
            ),
          // Input de mensaje
          Container(
            color: isDarkMode ? Color(0xFF1C1B1F) : colorScheme.surface,
            child: SafeArea(
              child: Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  boxShadow: isDarkMode
                      ? []
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 4,
                            offset: Offset(0, -2),
                          ),
                        ],
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
                                  hintText: 'Escribe un mensaje...',
                                  hintStyle: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
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
          ),
          // Emoji Picker
          if (_showEmojiPicker)
            SizedBox(
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
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble({
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
    required String senderId,
    required String senderName,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Dismissible(
        key: Key('dismiss_$messageId'),
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
          return false; // No eliminar, solo activar reply
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
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
            Container(
              key: key,
              margin: EdgeInsets.only(bottom: 4),
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                color: isMe
                    ? colorScheme.primary
                    : (isDarkMode
                          ? colorScheme.surfaceContainerHighest
                          : colorScheme.surfaceContainerHigh),
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
                    Icon(
                      Icons.play_circle_outline,
                      size: 64,
                      color: Colors.white,
                    ),
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
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
                padding: EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 4,
                  children: reactions.entries.map((entry) {
                    final reaction = entry.key;
                    final users = entry.value as List;
                    final count = users.length;
                    final hasReacted = users.contains(_auth.currentUser?.uid);

                    return GestureDetector(
                      onTap: () => _reactionService.toggleReaction(
                        chatId: widget.chatId,
                        messageId: messageId,
                        reaction: reaction,
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
                        chatId: widget.chatId,
                        messageId: messageId,
                        reaction: reaction,
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

    // Auto-cerrar después de 5 segundos
    Future.delayed(Duration(seconds: 5), () {
      _reactionOverlay?.remove();
      _reactionOverlay = null;
    });
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
