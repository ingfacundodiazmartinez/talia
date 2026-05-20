import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Servicio para reportar mensajes
class MessageReportService {
  static final MessageReportService _instance = MessageReportService._internal();
  factory MessageReportService() => _instance;
  MessageReportService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Reporta un mensaje como ofensivo
  Future<void> reportMessage({
    required String chatId,
    required String messageId,
    String? messageText,
    String reason = 'offensive',
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return;

    await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('reported_messages')
        .doc(messageId)
        .set({
      'messageId': messageId,
      'messageText': messageText ?? '',
      'reportedBy': currentUserId,
      'reportedAt': FieldValue.serverTimestamp(),
      'reason': reason,
    });
  }
}
