import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import '../../../models/chat_message.dart';
import '../../../services/favorite_service.dart';
import '../../../utils/release_logger.dart';
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
import 'answered_call_bubble.dart';
import '../../message_info_screen.dart';
import '../../forward_messages_screen.dart';

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
  final List<double>? waveformData; // Datos de forma de onda para audio
  final MessageStatus status;
  final Map<String, dynamic>? replyTo;
  final Map<String, dynamic>? reactions;
  final bool isMe;
  final String time;
  final String senderId;
  final String senderName;
  final Timestamp? timestamp;
  final VoidCallback? onReply;
  final Function(String)?
  onReplyTap; // Callback para navegar al mensaje original del reply
  final Function(BuildContext, String)? onLongPress;
  final Function(String, Timestamp?)? onDelete;
  final Function(String, String)?
  onEdit; // Callback para editar mensaje bloqueado
  final VoidCallback?
  onSelectMessages; // Callback para entrar en modo selección
  final List<ChatMessage>? allMessages;

  // Campos de moderación
  final ModerationStatus? moderationStatus;
  final String? moderationReason;
  final String? moderationSeverity;
  final String? originalText; // Texto original antes de ser bloqueado

  // Campo para identificar si es chat grupal
  final bool isGroupChat;
  final String? senderPhotoURL;

  // Campos para llamadas
  final String? type; // 'missed_call', 'answered_call', etc.
  final String? callType; // 'video' o 'audio'
  final int? callDuration; // Duración en segundos (para answered_call)
  final VoidCallback? onCallBack; // Callback para devolver llamada

  // Campos para mensajes reenviados
  final bool isForwarded;
  final String? originalContactName;

  // Campo para audio generado con IA
  final bool isAiGenerated;

  // Nombre del contacto del chat actual (para reenvíos)
  final String? contactName;

  // Callback para ver información del mensaje (solo grupos)
  final VoidCallback? onViewMessageInfo;

  // ✅ NEW: Indicador de mensaje favorito
  final bool isFavorite;
  final VoidCallback? onFavoriteToggled;  // ✅ Callback para refrescar favoritos

  const MessageBubble({
    super.key,
    required this.messageId,
    required this.chatId,
    this.text,
    this.imageUrl,
    this.videoUrl,
    this.audioUrl,
    this.localPath,
    this.waveformData,
    this.status = MessageStatus.sent,
    this.replyTo,
    this.reactions,
    required this.isMe,
    required this.time,
    required this.senderId,
    required this.senderName,
    this.timestamp,
    this.onReply,
    this.onReplyTap,
    this.onLongPress,
    this.onDelete,
    this.onEdit,
    this.onSelectMessages,
    this.allMessages,
    this.moderationStatus,
    this.moderationReason,
    this.moderationSeverity,
    this.originalText,
    this.isGroupChat = false,
    this.senderPhotoURL,
    this.type,
    this.callType,
    this.callDuration,
    this.onCallBack,
    this.isForwarded = false,
    this.originalContactName,
    this.isAiGenerated = false,
    this.contactName,
    this.onViewMessageInfo,
    this.isFavorite = false,  // ✅ NEW: Default false
    this.onFavoriteToggled,  // ✅ Callback para refrescar favoritos
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
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

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
            direction: widget.isMe
                ? DismissDirection.endToStart
                : DismissDirection.startToEnd,
            confirmDismiss: (direction) async {
              widget.onReply?.call();
              return false; // No eliminar, solo activar reply
            },
            background: Container(
              alignment: widget.isMe
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              padding: widget.isMe
                  ? const EdgeInsets.only(right: 20)
                  : const EdgeInsets.only(left: 20),
              child: Icon(Icons.reply, color: colorScheme.primary, size: 30),
            ),
            child: Padding(
              padding: EdgeInsets.only(
                bottom:
                    (widget.reactions != null && widget.reactions!.isNotEmpty)
                    ? 18 // Gap más grande para las reacciones más abajo
                    : 0,
              ),
              child: Column(
                crossAxisAlignment: widget.isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
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
                  // Stack para superponer reacciones sobre la burbuja
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Fila con foto de perfil (si es chat grupal) y burbuja
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Foto de perfil del remitente (en chats grupales, solo para mensajes de otros)
                          if (widget.isGroupChat && !widget.isMe)
                            Padding(
                              padding: const EdgeInsets.only(
                                right: 8,
                                bottom: 4,
                              ),
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
                                  onLongPress: () =>
                                      _showMessageOptions(messageContext),
                                  child:
                                      widget.type == 'missed_call' &&
                                          widget.callType != null &&
                                          widget.onCallBack != null
                                      ? MissedCallBubble(
                                          isMe: widget.isMe,
                                          callType: widget.callType!,
                                          time: widget.time,
                                          onCallBack: widget.onCallBack!,
                                        )
                                      : widget.type == 'answered_call' &&
                                            widget.callType != null &&
                                            widget.onCallBack != null
                                      ? AnsweredCallBubble(
                                          isMe: widget.isMe,
                                          callType: widget.callType!,
                                          time: widget.time,
                                          callDuration: widget.callDuration,
                                          onCallBack: widget.onCallBack!,
                                        )
                                      : Container(
                                          margin: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 8,
                                          ),
                                          constraints: BoxConstraints(
                                            maxWidth:
                                                MediaQuery.of(
                                                  context,
                                                ).size.width *
                                                0.75,
                                          ),
                                          decoration: BoxDecoration(
                                            color: widget.isMe
                                                ? colorScheme.primary
                                                : (isDarkMode
                                                      ? colorScheme
                                                            .surfaceContainerHighest
                                                      : colorScheme
                                                            .surfaceContainerHigh),
                                            borderRadius: BorderRadius.only(
                                              topLeft: const Radius.circular(
                                                16,
                                              ),
                                              topRight: const Radius.circular(
                                                16,
                                              ),
                                              bottomLeft: widget.isMe
                                                  ? const Radius.circular(16)
                                                  : const Radius.circular(4),
                                              bottomRight: widget.isMe
                                                  ? const Radius.circular(4)
                                                  : const Radius.circular(16),
                                            ),
                                            // ✅ Borde dorado sutil para mensajes favoritos
                                            border: widget.isFavorite
                                                ? Border.all(
                                                    color: Colors.amber.shade400,
                                                    width: 1.5,
                                                  )
                                                : null,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              // Si el mensaje está bloqueado O tiene originalText sin text (fue bloqueado antes), mostrar UI especial
                                              // Un mensaje bloqueado debe permanecer bloqueado incluso si se desactiva la moderación
                                              if (widget.moderationStatus ==
                                                      ModerationStatus
                                                          .blocked ||
                                                  (widget.originalText !=
                                                          null &&
                                                      widget
                                                          .originalText!
                                                          .isNotEmpty &&
                                                      (widget.text == null ||
                                                          widget
                                                              .text!
                                                              .isEmpty)))
                                                BlockedMessageContent(
                                                  isMe: widget.isMe,
                                                  moderationReason:
                                                      widget.moderationReason ??
                                                      'Este mensaje fue bloqueado anteriormente por moderación',
                                                  originalText:
                                                      widget.originalText,
                                                  messageId: widget.messageId,
                                                  onEdit: widget.onEdit,
                                                )
                                              else ...[
                                                // Forwarded message indicator
                                                Builder(
                                                  builder: (context) {
                                                    // Debug logging
                                                    if (widget.isForwarded) {
                                                      if (widget
                                                              .originalContactName !=
                                                          null) {
                                                        ReleaseLogger.log(
                                                          'MessageBubble(${widget.messageId.substring(0, 8)}...): Mostrando indicador - isForwarded=true, originalContactName="${widget.originalContactName}"',
                                                          tag: 'MessageBubble',
                                                        );
                                                      } else {
                                                        ReleaseLogger.warning(
                                                          'MessageBubble(${widget.messageId.substring(0, 8)}...): isForwarded=true pero originalContactName=null! NO se muestra indicador',
                                                          tag: 'MessageBubble',
                                                        );
                                                      }
                                                    }

                                                    if (widget.isForwarded &&
                                                        widget.originalContactName !=
                                                            null) {
                                                      return Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              bottom: 6,
                                                            ),
                                                        child: Row(
                                                          children: [
                                                            Icon(
                                                              Icons.forward,
                                                              size: 14,
                                                              color: widget.isMe
                                                                  ? Colors
                                                                        .white70
                                                                  : Colors
                                                                        .grey[600],
                                                            ),
                                                            const SizedBox(
                                                              width: 4,
                                                            ),
                                                            Text(
                                                              'Reenviado de ${widget.originalContactName}',
                                                              style: TextStyle(
                                                                fontSize: 11,
                                                                fontStyle:
                                                                    FontStyle
                                                                        .italic,
                                                                color:
                                                                    widget.isMe
                                                                    ? Colors
                                                                          .white70
                                                                    : Colors
                                                                          .grey[600],
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                    }
                                                    return const SizedBox.shrink();
                                                  },
                                                ),
                                                // Reply preview
                                                if (widget.replyTo != null)
                                                  ReplyPreviewWidget(
                                                    replyTo: widget.replyTo!,
                                                    isMe: widget.isMe,
                                                    onTap:
                                                        widget.onReplyTap !=
                                                                null &&
                                                            widget.replyTo!['id'] !=
                                                                null
                                                        ? () => widget.onReplyTap!(
                                                            widget
                                                                .replyTo!['id'],
                                                          )
                                                        : null,
                                                  ),
                                                // Imagen
                                                if (_shouldShowImage())
                                                  ImageMessageContent(
                                                    imageUrl: widget.imageUrl,
                                                    localPath: widget.localPath,
                                                    status: widget.status,
                                                    text: widget.text,
                                                    mediaItems:
                                                        _buildMediaGallery(
                                                          'image',
                                                        ).mediaItems,
                                                    initialIndex:
                                                        _buildMediaGallery(
                                                          'image',
                                                        ).initialIndex,
                                                  ),
                                                // Video
                                                if (_shouldShowVideo())
                                                  VideoMessageContent(
                                                    videoUrl: widget.videoUrl,
                                                    localPath: widget.localPath,
                                                    thumbnailPath: widget.status == MessageStatus.sending ? widget.imageUrl : null,
                                                    status: widget.status,
                                                    text: widget.text,
                                                    mediaItems:
                                                        _buildMediaGallery(
                                                          'video',
                                                        ).mediaItems,
                                                    initialIndex:
                                                        _buildMediaGallery(
                                                          'video',
                                                        ).initialIndex,
                                                  ),
                                                // Audio
                                                if (_shouldShowAudio())
                                                  AudioMessageContent(
                                                    audioUrl: widget.audioUrl,
                                                    localPath: widget.localPath,
                                                    status: widget.status,
                                                    isMe: widget.isMe,
                                                    text: widget.text,
                                                    waveformData:
                                                        widget.waveformData,
                                                  ),
                                                // Texto
                                                if (widget.text != null &&
                                                    widget.text!.isNotEmpty)
                                                  TextMessageContent(
                                                    text: widget.text!,
                                                    isMe: widget.isMe,
                                                  ),
                                                const SizedBox(height: 4),
                                                // Timestamp
                                                MessageTimestamp(
                                                  time: widget.time,
                                                  isMe: widget.isMe,
                                                  status: widget.status,
                                                  isFavorite: widget.isFavorite,  // ✅ NEW
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
                              padding: const EdgeInsets.only(
                                left: 8,
                                bottom: 4,
                              ),
                              child: GroupChatAvatar(
                                senderPhotoURL: widget.senderPhotoURL,
                                senderName: widget.senderName,
                              ),
                            ),
                        ],
                      ),
                      // Reacciones superpuestas en la esquina inferior de la burbuja
                      if (widget.reactions != null &&
                          widget.reactions!.isNotEmpty)
                        Positioned(
                          bottom: -22, // Más abajo para mejor separación
                          // Si es mi mensaje: reacciones a la IZQUIERDA de la burbuja
                          // Si es mensaje del otro: reacciones a la DERECHA de la burbuja
                          left: widget.isMe
                              ? (widget.isGroupChat ? 48 : 8)
                              : null,
                          right: !widget.isMe
                              ? (widget.isGroupChat ? 48 : 8)
                              : null,
                          child: MessageReactions(
                            reactions: widget.reactions!,
                            chatId: widget.chatId,
                            messageId: widget.messageId,
                            isGroupChat: widget.isGroupChat,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Determina si debe mostrar la imagen
  bool _shouldShowImage() {
    // NO mostrar imagen si es un mensaje de video
    if (widget.type == 'video') return false;

    // ✅ FIX: Usar widget.type en vez de extensiones de archivo
    // Los paths de iOS pueden no tener extensión o tener casing diferente
    return widget.imageUrl != null ||
        (widget.type == 'image' &&
            widget.status == MessageStatus.sending &&
            widget.localPath != null);
  }

  /// Determina si debe mostrar el video
  bool _shouldShowVideo() {
    // ✅ FIX: Usar widget.type en vez de extensiones de archivo
    return widget.videoUrl != null ||
        (widget.type == 'video' &&
            widget.status == MessageStatus.sending &&
            widget.localPath != null);
  }

  /// Determina si debe mostrar el audio
  bool _shouldShowAudio() {
    // ✅ FIX: Usar widget.type en vez de extensiones de archivo
    return widget.audioUrl != null ||
        (widget.type == 'audio' &&
            widget.status == MessageStatus.sending &&
            widget.localPath != null);
  }

  /// Construye la galería de medios
  ({List<MediaItem> mediaItems, int initialIndex}) _buildMediaGallery(
    String mediaType,
  ) {
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

  /// Mostrar opciones del mensaje (reaccionar, eliminar, reenviar)
  void _showMessageOptions(BuildContext context) async {
    // Cerrar el teclado ANTES de mostrar el diálogo para evitar conflictos
    FocusScope.of(context).unfocus();

    // Verificar si el mensaje está marcado como favorito
    final favoriteService = FavoriteService();
    final isFavorite = await favoriteService.isFavorite(
      chatId: widget.chatId,
      messageId: widget.messageId,
      isGroupChat: widget.isGroupChat,
    );

    if (!mounted) return;

    MessageOptionsDialog.show(
      context: context,
      isMe: widget.isMe,
      timestamp: widget.timestamp,
      onLongPress: widget.onLongPress,
      onDelete: widget.onDelete,
      messageId: widget.messageId,
      chatId: widget.chatId,
      messageText: widget.text,
      onForward: () => _forwardMessage(context),
      onReply: widget.onReply,
      onSelectMessages: widget.onSelectMessages,
      isGroupChat: widget.isGroupChat,
      onViewInfo: widget.onViewMessageInfo, // Usar el callback del padre
      moderationStatus: widget.moderationStatus, // Pasar estado de moderación
      isFavorite: isFavorite,
      onToggleFavorite: () => _toggleFavorite(context),
    );
  }

  /// Marcar/desmarcar mensaje como favorito
  Future<void> _toggleFavorite(BuildContext context) async {
    try {
      final favoriteService = FavoriteService();
      await favoriteService.toggleFavorite(
        chatId: widget.chatId,
        messageId: widget.messageId,
        isGroupChat: widget.isGroupChat,
      );

      // ✅ Notificar al parent para refrescar favoritos
      widget.onFavoriteToggled?.call();

      if (mounted) {
        // Verificar si ahora está marcado o desmarcado
        final isFavorite = await favoriteService.isFavorite(
          chatId: widget.chatId,
          messageId: widget.messageId,
          isGroupChat: widget.isGroupChat,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isFavorite
                  ? 'Mensaje marcado como favorito'
                  : 'Mensaje eliminado de favoritos',
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error al cambiar favorito: $e', tag: 'MessageBubble');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Error al cambiar favorito'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Navegar a la pantalla de información del mensaje (solo grupos)
  void _viewMessageInfo() {
    ReleaseLogger.log('_viewMessageInfo llamado', tag: 'MessageBubble');
    ReleaseLogger.log('mounted: $mounted', tag: 'MessageBubble');
    ReleaseLogger.log('chatId: ${widget.chatId}', tag: 'MessageBubble');
    ReleaseLogger.log('messageId: ${widget.messageId}', tag: 'MessageBubble');

    if (!mounted) {
      ReleaseLogger.error('Widget no mounted, abortando navegación', tag: 'MessageBubble');
      return;
    }

    try {
      ReleaseLogger.log('Navegando a MessageInfoScreen...', tag: 'MessageBubble');
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) {
            ReleaseLogger.log('Builder de MessageInfoScreen ejecutado', tag: 'MessageBubble');
            return MessageInfoScreen(
              groupId: widget.chatId,
              messageId: widget.messageId,
            );
          },
        ),
      );
      ReleaseLogger.log('Navigator.push completado', tag: 'MessageBubble');
    } catch (e, stackTrace) {
      ReleaseLogger.error('Error en navegación: $e', tag: 'MessageBubble');
      ReleaseLogger.error('StackTrace: $stackTrace', tag: 'MessageBubble');
    }
  }

  /// Navegar a la pantalla de reenvío
  void _forwardMessage(BuildContext context) {
    // Crear un ChatMessage a partir de los datos del widget
    final message = ChatMessage(
      id: widget.messageId,
      senderId: widget.senderId,
      text: widget.text,
      timestamp: widget.timestamp,
      type: _determineMessageType(),
      imageUrl: widget.imageUrl,
      videoUrl: widget.videoUrl,
      audioUrl: widget.audioUrl,
      waveformData: widget.waveformData,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ForwardMessagesScreen(
          messages: [message],
          originalChatId: widget.chatId,
          contactName: widget.contactName ?? 'Chat',
        ),
      ),
    );
  }

  /// Determina el tipo de mensaje basado en los datos disponibles
  String _determineMessageType() {
    if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty) {
      return 'image';
    } else if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
      return 'video';
    } else if (widget.audioUrl != null && widget.audioUrl!.isNotEmpty) {
      return 'audio';
    }
    return 'text';
  }
}
