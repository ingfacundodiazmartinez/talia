import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../controllers/chat_controller_cache_first.dart';
import '../../../models/chat_message.dart';
import 'message_bubble.dart';
import 'date_separator_widget.dart';

/// Widget que renderiza la lista de mensajes del chat
///
/// Responsabilidades:
/// - Renderizar lista de mensajes con scroll inverso
/// - Manejar estados vacío y carga
/// - Integrar separadores de fecha
/// - Manejar modo de selección
/// - Coordinar highlight de mensajes
class MessageListWidget extends StatelessWidget {
  final ChatControllerCacheFirst controller;
  final ScrollController scrollController;
  final String chatId;
  final String contactName;
  final bool isSelectionMode;
  final Set<String> selectedMessageIds;
  final String? highlightedMessageId;
  final VoidCallback onToggleSelection;
  final Function(String messageId) onToggleMessageSelection;
  final Function(BuildContext context, String messageId) onShowReactionPicker;
  final Function(String messageId, Map<String, dynamic> messageData) onReply;
  final Function(String messageId) onReplyTap;
  final Future<void> Function(String messageId, Timestamp? timestamp) onDelete;
  final Future<void> Function(String messageId, String originalText) onEdit;
  final Function(String messageId) onSelectMessages;
  final Future<void> Function(String callType) onCallBack;

  const MessageListWidget({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.chatId,
    required this.contactName,
    required this.isSelectionMode,
    required this.selectedMessageIds,
    required this.highlightedMessageId,
    required this.onToggleSelection,
    required this.onToggleMessageSelection,
    required this.onShowReactionPicker,
    required this.onReply,
    required this.onReplyTap,
    required this.onDelete,
    required this.onEdit,
    required this.onSelectMessages,
    required this.onCallBack,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Estado de carga inicial
    if (controller.isLoading && controller.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // Estado vacío
    if (controller.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
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

    // Lista de mensajes
    return ListView.builder(
      controller: scrollController,
      reverse: true,
      physics: const ClampingScrollPhysics(),
      cacheExtent: 1000,
      addAutomaticKeepAlives: true,
      addRepaintBoundaries: true,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 16),
      itemCount: controller.messages.length,
      findChildIndexCallback: (Key key) {
        if (key is ValueKey<String>) {
          final messageId = key.value.replaceFirst('msg_', '');
          final index = controller.messages.indexWhere(
            (msg) => msg.id == messageId,
          );
          return index >= 0 ? index : null;
        }
        return null;
      },
      itemBuilder: (context, index) {
        return _buildMessageItem(context, index);
      },
    );
  }

  Widget _buildMessageItem(BuildContext context, int index) {
    final message = controller.messages[index];
    final isMe = message.senderId == FirebaseAuth.instance.currentUser!.uid;
    final timeString =
        '${message.effectiveTimestamp.hour}:${message.effectiveTimestamp.minute.toString().padLeft(2, '0')}';
    final isSelected = selectedMessageIds.contains(message.id);

    // Verificar si necesitamos mostrar separador de fecha
    final bool showDateSeparator = _shouldShowDateSeparator(index);

    // Aplicar highlight si es el mensaje buscado
    final isHighlighted = highlightedMessageId == message.id;

    // ✅ Handle deleted messages
    if (message.isDeletedForEveryone) {
      return _buildDeletedMessageBubble(context, message, isMe, timeString, showDateSeparator, index);
    }

    Widget messageBubble = MessageBubble(
      key: ValueKey('msg_${message.id}'),
      messageId: message.id,
      chatId: chatId,
      text: message.text,
      imageUrl: message.imageUrl,
      videoUrl: message.videoUrl,
      audioUrl: message.audioUrl,
      localPath: message.localPath,
      waveformData: message.waveformData,
      status: message.status,
      replyTo: message.replyTo,
      reactions: message.reactions,
      isMe: isMe,
      time: timeString,
      senderId: message.senderId,
      senderName: contactName,
      timestamp: message.timestamp,
      allMessages: controller.messages,
      moderationStatus: message.moderationStatus,
      moderationReason: message.moderationReason,
      moderationSeverity: message.moderationSeverity,
      originalText: message.originalText,
      type: message.type,
      callType: message.callType,
      callDuration: message.callDuration,
      onCallBack: message.callType != null
          ? () => onCallBack(message.callType!)
          : null,
      isForwarded: message.isForwarded,
      originalContactName: message.originalContactName,
      contactName: contactName,
      isGroupChat: false,
      isFavorite: controller.favoriteIds.contains(message.id),  // ✅ NEW
      onFavoriteToggled: () => controller.refreshFavorites(),  // ✅ Refresh tras toggle
      localTimestamp: message.localTimestamp,  // ✅ NEW: Para timeout de pending
      onRetry: isMe && message.status == MessageStatus.sending
          ? () => _retryMessage(context, message)
          : null,  // ✅ NEW: Callback para reenviar
      onReply: () {
        // Construir datos completos del mensaje incluyendo media
        // IMPORTANTE: Usar message.type como fuente primaria (se guarda en Firestore)
        // porque las URLs pueden ser null si el archivo fue eliminado por TTL
        final replyData = {
          'id': message.id,
          'text': message.text ?? '',
          'senderId': message.senderId,
          'senderName': contactName,
          // Usar type del mensaje (más confiable que derivar de URLs)
          'contentType': message.type ?? message.contentType,
        };

        // Incluir URLs de media si existen
        if (message.imageUrl != null && message.imageUrl!.isNotEmpty) {
          replyData['imageUrl'] = message.imageUrl!;
        }
        if (message.videoUrl != null && message.videoUrl!.isNotEmpty) {
          replyData['videoUrl'] = message.videoUrl!;
        }
        if (message.audioUrl != null && message.audioUrl!.isNotEmpty) {
          replyData['audioUrl'] = message.audioUrl!;
        }

        // Llamar al callback pasando los datos completos
        onReply(message.id, replyData);
      },
      onReplyTap: onReplyTap,
      onLongPress: onShowReactionPicker,
      onDelete: onDelete,
      onEdit: onEdit,
      onSelectMessages: () {
        onSelectMessages(message.id);
      },
    );

    // Wrap con highlight si es necesario
    if (isHighlighted) {
      messageBubble = Container(
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: messageBubble,
      );
    }

    // Wrap con soporte de modo selección
    Widget finalWidget;
    if (isSelectionMode) {
      finalWidget = GestureDetector(
        onTap: () {
          onToggleMessageSelection(message.id);
        },
        child: Container(
          color: isSelected
              ? Colors.blue.withValues(alpha: 0.1)
              : Colors.transparent,
          child: Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: (value) {
                  onToggleMessageSelection(message.id);
                },
              ),
              Expanded(child: messageBubble),
            ],
          ),
        ),
      );
    } else {
      finalWidget = messageBubble;
    }

    // Agregar separador de fecha si es necesario
    if (showDateSeparator) {
      return Column(
        children: [
          DateSeparatorWidget(date: message.effectiveTimestamp),
          const SizedBox(height: 16),
          finalWidget,
        ],
      );
    }

    return finalWidget;
  }

  /// Reintenta enviar un mensaje que falló o está en timeout
  /// Mantiene el mensaje en su posición original y solo cambia el estado
  void _retryMessage(BuildContext context, ChatMessage message) {
    // Mostrar snackbar de reintento
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reenviando mensaje...'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    // Reenviar usando el método retryMessage del controller
    // Esto mantiene el mensaje en su posición original
    controller.retryMessage(message.id);
  }

  /// Determina si se debe mostrar un separador de fecha antes de este mensaje
  bool _shouldShowDateSeparator(int index) {
    final messages = controller.messages;

    return DateSeparatorWidget.shouldShowSeparator(
      index: index,
      totalMessages: messages.length,
      currentMessageDate: messages[index].effectiveTimestamp,
      nextMessageDate: index < messages.length - 1
          ? messages[index + 1].effectiveTimestamp
          : messages[index].effectiveTimestamp,
    );
  }

  /// ✅ Build placeholder for deleted messages
  Widget _buildDeletedMessageBubble(
    BuildContext context,
    ChatMessage message,
    bool isMe,
    String timeString,
    bool showDateSeparator,
    int index,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    final bubble = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.block,
                size: 16,
                color: colorScheme.onSurfaceVariant.withOpacity(0.6),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Este mensaje fue eliminado',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: colorScheme.onSurfaceVariant.withOpacity(0.6),
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                timeString,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (showDateSeparator) {
      return Column(
        children: [
          DateSeparatorWidget(date: message.effectiveTimestamp),
          const SizedBox(height: 16),
          bubble,
        ],
      );
    }

    return bubble;
  }
}
