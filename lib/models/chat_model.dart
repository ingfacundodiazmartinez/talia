import 'package:cloud_firestore/cloud_firestore.dart';

class ChatModel {
  final String chatId;
  final String userId;
  final String name;
  final String lastMessage;
  final String time;
  final int unreadCount;
  final bool isOnline;
  final String? photoURL;
  final bool isGroup;
  final bool isEmpty;

  ChatModel({
    required this.chatId,
    required this.userId,
    required this.name,
    required this.lastMessage,
    required this.time,
    required this.unreadCount,
    required this.isOnline,
    this.photoURL,
    this.isGroup = false,
    this.isEmpty = false,
  });

  factory ChatModel.fromFirestore(
    DocumentSnapshot doc,
    String userId,
    String name, {
    bool isOnline = false,
    String? photoURL,
    bool isEmpty = false,
  }) {
    final data = doc.data() as Map<String, dynamic>?;

    return ChatModel(
      chatId: doc.id,
      userId: userId,
      name: name,
      lastMessage: data?['lastMessage'] ?? (isEmpty ? 'Toca para iniciar conversación' : ''),
      time: _formatTime(data?['lastMessageTime']),
      unreadCount: 0, // This would need to be calculated separately
      isOnline: isOnline,
      photoURL: photoURL,
      isEmpty: isEmpty,
    );
  }

  static String _formatTime(dynamic timestamp) {
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

  Map<String, dynamic> toMap() {
    return {
      'chatId': chatId,
      'userId': userId,
      'name': name,
      'lastMessage': lastMessage,
      'time': time,
      'unreadCount': unreadCount,
      'isOnline': isOnline,
      'photoURL': photoURL,
      'isGroup': isGroup,
      'isEmpty': isEmpty,
    };
  }
}
