import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/chat_message.dart';
import 'media_viewer_screen.dart';
import 'message_bubble/blocked_message_content.dart';
import 'message_bubble/reply_preview_widget.dart';
import 'message_bubble/image_message_content.dart';
import 'message_bubble/video_message_content.dart';
import 'message_bubble/audio_message_content.dart';
import 'message_bubble/text_message_content.dart';
import 'message_bubble/message_timestamp.dart';
import 'message_bubble/message_reactions.dart';
import 'message_bubble/group_chat_avatar.dart';
import 'message_bubble/media_gallery_service.dart';
import 'message_bubble/message_options_dialog.dart';
import 'missed_call_bubble.dart';

/// Widget que muestra un mensaje individual en el chat
///
/// Responsabilidades:
/// - Renderizar burbujas de mensaje (propias y del contacto)
/// - Mostrar texto, imágenes, videos y audios
/// - Manejar reacciones a mensajes
/// - Mostrar reply/respuesta a mensajes
/// - Gesture para reply (Dismissible)
/// - Long press para mostrar picker de reacciones
/// - Opción de eliminar mensajes propios (< 5 minutos)
/// - Animación suave de entrada (fade + slide from bottom)
class MessageBubble extends StatefulWidget {
  final String messageId;
  final String chatId;
  final String? text;
  final String? imageUrl;
  final String? videoUrl;
  final String? audioUrl;
  final String? localPath;
  final MessageStatus status;
  final Map<String, dynamic>? replyTo;
  final Map<String, dynamic>? reactions;
  final bool isMe;
  final String time;
  final String senderId;
  final String senderName;
  final Timestamp? timestamp;
  final VoidCallback? onReply;
  final Function(BuildContext, String)? onLongPress;
  final Function(String, Timestamp?)? onDelete;
  final List<ChatMessage>? allMessages;

  // Campos de moderación
  final ModerationStatus? moderationStatus;
  final String? moderationReason;
  final String? moderationSeverity;

  // Campo para identificar si es chat grupal
  final bool isGroupChat;
  final String? senderPhotoURL;

  // Campos para llamadas perdidas
  final String? type; // 'missed_call', etc.
  final String? callType; // 'video' o 'audio'
  final VoidCallback? onCallBack; // Callback para devolver llamada

  const MessageBubble({
    super.key,
    required this.messageId,
    required this.chatId,
    this.text,
    this.imageUrl,
    this.videoUrl,
    this.audioUrl,
    this.localPath,
    this.status = MessageStatus.sent,
    this.replyTo,
    this.reactions,
    required this.isMe,
    required this.time,
    required this.senderId,
    required this.senderName,
    this.timestamp,
    this.onReply,
    this.onLongPress,
    this.onDelete,
    this.allMessages,
    this.moderationStatus,
    this.moderationReason,
    this.moderationSeverity,
    this.isGroupChat = false,
    this.senderPhotoURL,
    this.type,
    this.callType,
    this.onCallBack,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3), // Desde 30% abajo
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // Iniciar animación de entrada
    _controller.forward();
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

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Align(
          alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Dismissible(
            key: Key('dismiss_${widget.messageId}'),
            direction: DismissDirection.startToEnd,
            confirmDismiss: (direction) async {
              widget.onReply?.call();
              return false; // No eliminar, solo activar reply
            },
            background: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: Icon(Icons.reply, color: colorScheme.primary, size: 30),
            ),
            child: Column(
              crossAxisAlignment:
                  widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // Mostrar nombre del remitente en chats grupales (solo para mensajes de otros)
                if (widget.isGroupChat && !widget.isMe)
                  Padding(
                    padding: const EdgeInsets.only(left: 52, bottom: 2),
                    child: Text(
                      widget.senderName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                // Fila con foto de perfil (si es chat grupal) y burbuja
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Foto de perfil del remitente (en chats grupales, solo para mensajes de otros)
                    if (widget.isGroupChat && !widget.isMe)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 4),
                        child: GroupChatAvatar(
                          senderPhotoURL: widget.senderPhotoURL,
                          senderName: widget.senderName,
                        ),
                      ),
                    // Burbuja de mensaje
                    Flexible(
                      child: RepaintBoundary(
                        child: Builder(
                          builder: (messageContext) => InkWell(
                            onLongPress: () => _showMessageOptions(messageContext),
                            child: widget.type == 'missed_call' && widget.callType != null && widget.onCallBack != null
                                ? MissedCallBubble(
                                    isMe: widget.isMe,
                                    callType: widget.callType!,
                                    time: widget.time,
                                    onCallBack: widget.onCallBack!,
                                  )
                                : Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.75,
                              ),
                              decoration: BoxDecoration(
                                color: widget.isMe
                                    ? colorScheme.primary
                                    : (isDarkMode
                                        ? colorScheme.surfaceContainerHighest
                                        : colorScheme.surfaceContainerHigh),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft:
                                      widget.isMe ? const Radius.circular(16) : const Radius.circular(4),
                                  bottomRight:
                                      widget.isMe ? const Radius.circular(4) : const Radius.circular(16),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Si el mensaje está bloqueado, mostrar UI especial
                                  if (widget.moderationStatus == ModerationStatus.blocked)
                                    BlockedMessageContent(isMe: widget.isMe)
                                  else ...[
                                    // Reply preview
                                    if (widget.replyTo != null)
                                      ReplyPreviewWidget(
                                        replyTo: widget.replyTo!,
                                        isMe: widget.isMe,
                                      ),
                                    // Imagen
                                    if (_shouldShowImage())
                                      ImageMessageContent(
                                        imageUrl: widget.imageUrl,
                                        localPath: widget.localPath,
                                        status: widget.status,
                                        text: widget.text,
                                        mediaItems: _buildMediaGallery('image').mediaItems,
                                        initialIndex: _buildMediaGallery('image').initialIndex,
                                      ),
                                    // Video
                                    if (_shouldShowVideo())
                                      VideoMessageContent(
                                        videoUrl: widget.videoUrl,
                                        localPath: widget.localPath,
                                        status: widget.status,
                                        text: widget.text,
                                        mediaItems: _buildMediaGallery('video').mediaItems,
                                        initialIndex: _buildMediaGallery('video').initialIndex,
                                      ),
                                    // Audio
                                    if (_shouldShowAudio())
                                      AudioMessageContent(
                                        audioUrl: widget.audioUrl,
                                        status: widget.status,
                                        isMe: widget.isMe,
                                        text: widget.text,
                                      ),
                                    // Texto
                                    if (widget.text != null && widget.text!.isNotEmpty)
                                      TextMessageContent(
                                        text: widget.text!,
                                        isMe: widget.isMe,
                                      ),
                                    const SizedBox(height: 4),
                                    // Timestamp
                                    MessageTimestamp(
                                      time: widget.time,
                                      isMe: widget.isMe,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Foto de perfil para mis propios mensajes (en chats grupales)
                    if (widget.isGroupChat && widget.isMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, bottom: 4),
                        child: GroupChatAvatar(
                          senderPhotoURL: widget.senderPhotoURL,
                          senderName: widget.senderName,
                        ),
                      ),
                  ],
                ),
                // Reacciones
                if (widget.reactions != null && widget.reactions!.isNotEmpty)
                  MessageReactions(
                    reactions: widget.reactions!,
                    chatId: widget.chatId,
                    messageId: widget.messageId,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Determina si debe mostrar la imagen
  bool _shouldShowImage() {
    return widget.imageUrl != null ||
        (widget.status == MessageStatus.sending &&
            widget.localPath != null &&
            (widget.localPath!.contains('.jpg') ||
                widget.localPath!.contains('.png') ||
                widget.localPath!.contains('.jpeg')));
  }

  /// Determina si debe mostrar el video
  bool _shouldShowVideo() {
    return widget.videoUrl != null ||
        (widget.status == MessageStatus.sending &&
            widget.localPath != null &&
            (widget.localPath!.contains('.mp4') ||
                widget.localPath!.contains('.mov')));
  }

  /// Determina si debe mostrar el audio
  bool _shouldShowAudio() {
    return widget.audioUrl != null ||
        (widget.status == MessageStatus.sending &&
            widget.localPath != null &&
            (widget.localPath!.contains('.m4a') ||
                widget.localPath!.contains('.mp3')));
  }

  /// Construye la galería de medios
  ({List<MediaItem> mediaItems, int initialIndex}) _buildMediaGallery(String mediaType) {
    String? currentUrl;
    if (mediaType == 'image') {
      currentUrl = widget.imageUrl;
    } else if (mediaType == 'video') {
      currentUrl = widget.videoUrl;
    }

    return MediaGalleryService.buildMediaGallery(
      currentMediaUrl: currentUrl,
      currentMediaType: mediaType,
      caption: widget.text,
      allMessages: widget.allMessages,
    );
  }

  /// Mostrar opciones del mensaje (reaccionar, eliminar)
  void _showMessageOptions(BuildContext context) {
    MessageOptionsDialog.show(
      context: context,
      isMe: widget.isMe,
      timestamp: widget.timestamp,
      onLongPress: widget.onLongPress,
      onDelete: widget.onDelete,
      messageId: widget.messageId,
      chatId: widget.chatId,
      messageText: widget.text,
    );
  }
}
