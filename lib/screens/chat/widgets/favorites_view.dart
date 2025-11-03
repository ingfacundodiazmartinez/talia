import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../services/favorite_service.dart';
import '../../../models/chat_message.dart';
import 'message_bubble.dart';

/// Widget que muestra la vista de mensajes favoritos en el chat
class FavoritesView extends StatelessWidget {
  final String chatId;
  final String contactName;
  final bool isGroupChat;
  final Function(BuildContext, String)? onShowReactionPicker;
  final Function(String, Map<String, dynamic>)? onReply;
  final Function(String)? onReplyTap;
  final Function(String, Timestamp?)? onDelete;
  final Function(String, String)? onEdit;
  final Function(String)? onSelectMessages;

  const FavoritesView({
    super.key,
    required this.chatId,
    required this.contactName,
    this.isGroupChat = false,
    this.onShowReactionPicker,
    this.onReply,
    this.onReplyTap,
    this.onDelete,
    this.onEdit,
    this.onSelectMessages,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _getFavoriteMessagesStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Cargando mensajes favoritos...'),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Colors.red.shade300,
                ),
                const SizedBox(height: 16),
                Text(
                  'Error cargando favoritos',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.red.shade300,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Intenta de nuevo más tarde',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          );
        }

        return FutureBuilder<List<ChatMessage>>(
          future: _getFavoriteMessages(snapshot.data?.docs ?? []),
          builder: (context, favoritesSnapshot) {
            if (favoritesSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final favoriteMessages = favoritesSnapshot.data ?? [];

            if (favoriteMessages.isEmpty) {
              return _buildEmptyState();
            }

            return ListView.builder(
              reverse: true, // Mostrar desde el más reciente
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: favoriteMessages.length,
              itemBuilder: (context, index) {
                final message = favoriteMessages[index];
                final isMe = message.senderId == FirebaseAuth.instance.currentUser!.uid;
                final timeString = message.timestamp != null
                  ? '${message.timestamp!.toDate().hour}:${message.timestamp!.toDate().minute.toString().padLeft(2, '0')}'
                  : '${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: MessageBubble(
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
                    moderationStatus: message.moderationStatus,
                    moderationReason: message.moderationReason,
                    moderationSeverity: message.moderationSeverity,
                    originalText: message.originalText,
                    type: message.type,
                    callType: message.callType,
                    callDuration: message.callDuration,
                    isForwarded: message.isForwarded,
                    originalContactName: message.originalContactName,
                    contactName: contactName,
                    isGroupChat: isGroupChat,
                    onReply: onReply != null ? () {
                      // Construir datos completos del mensaje incluyendo media
                      final replyData = {
                        'id': message.id,
                        'text': message.text ?? '',
                        'senderId': message.senderId,
                        'senderName': contactName,
                      };

                      // Incluir URLs de media si existen
                      if (message.imageUrl != null) {
                        replyData['imageUrl'] = message.imageUrl!;
                      }
                      if (message.videoUrl != null) {
                        replyData['videoUrl'] = message.videoUrl!;
                      }
                      if (message.audioUrl != null) {
                        replyData['audioUrl'] = message.audioUrl!;
                      }

                      onReply!(message.id, replyData);
                    } : null,
                    onReplyTap: onReplyTap,
                    onLongPress: onShowReactionPicker,
                    onDelete: onDelete,
                    onEdit: onEdit,
                    onSelectMessages: onSelectMessages != null ? () => onSelectMessages!(message.id) : null,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.star_border_rounded,
            size: 80,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 24),
          Text(
            'No hay mensajes favoritos',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              'Mantén presionado cualquier mensaje y marca como favorito para verlo aquí',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade600,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.amber.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Colors.amber.shade700,
                ),
                const SizedBox(width: 8),
                Text(
                  'Tip: Usa el ⭐ en las opciones del mensaje',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.amber.shade800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Stream<QuerySnapshot> _getFavoriteMessagesStream() {
    final collection = isGroupChat ? 'groups' : 'chats';
    return FirebaseFirestore.instance
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  Future<List<ChatMessage>> _getFavoriteMessages(List<QueryDocumentSnapshot> allMessages) async {
    final favoriteService = FavoriteService();
    final favoriteMessages = <ChatMessage>[];

    for (final doc in allMessages) {
      try {
        final isFav = await favoriteService.isFavorite(
          chatId: chatId,
          messageId: doc.id,
          isGroupChat: isGroupChat,
        );

        if (isFav) {
          final message = ChatMessage.fromFirestore(doc);
          favoriteMessages.add(message);
        }
      } catch (e) {
        print('❌ Error verificando favorito para mensaje ${doc.id}: $e');
      }
    }

    // Ordenar por timestamp (más reciente primero)
    favoriteMessages.sort((a, b) {
      if (a.timestamp == null && b.timestamp == null) return 0;
      if (a.timestamp == null) return 1;
      if (b.timestamp == null) return -1;
      return b.timestamp!.compareTo(a.timestamp!);
    });
    return favoriteMessages;
  }

}