import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../services/remote_logger_service.dart';

/// Controller para la pantalla de mensajes reportados
///
/// Responsabilidades:
/// - Obtener mensajes reportados por el usuario
/// - Desbloquear mensajes reportados
/// - Gestionar estado de la pantalla
class ReportedMessagesController extends ChangeNotifier {
  final String chatId;

  // Dependencies
  final FirebaseFirestore _firestore;
  final String _currentUserId;
  final RemoteLoggerService _logger;

  // State
  bool _isLoading = false;
  String? _error;
  StreamSubscription<QuerySnapshot>? _messagesSubscription;

  ReportedMessagesController({
    required this.chatId,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    RemoteLoggerService? logger,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _currentUserId = auth?.currentUser?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
       _logger = logger ?? RemoteLoggerService();

  // Getters
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Stream de mensajes reportados
  Stream<QuerySnapshot> watchReportedMessages() {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('reported_messages')
        .where('reportedBy', isEqualTo: _currentUserId)
        .orderBy('reportedAt', descending: true)
        .snapshots();
  }

  /// Desbloquear mensaje reportado
  Future<void> unblockMessage(String docId, String chatId, String messageId) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      await _firestore.runTransaction((transaction) async {
        // 1. Eliminar el reporte
        final reportRef = _firestore
            .collection('chats')
            .doc(chatId)
            .collection('reported_messages')
            .doc(docId);

        transaction.delete(reportRef);

        // 2. Actualizar el mensaje original para marcarlo como no bloqueado
        final messageRef = _firestore
            .collection('chats')
            .doc(chatId)
            .collection('messages')
            .doc(messageId);

        transaction.update(messageRef, {
          'blockedBy': FieldValue.arrayRemove([_currentUserId]),
          'unblockedAt': FieldValue.serverTimestamp(),
          'unblockedBy': _currentUserId,
        });

        // 3. Log del desbloqueo para auditoría
        final logData = {
          'action': 'message_unblocked',
          'chatId': chatId,
          'messageId': messageId,
          'unblockedBy': _currentUserId,
          'timestamp': FieldValue.serverTimestamp(),
        };

        final logRef = _firestore
            .collection('moderation_logs')
            .doc();

        transaction.set(logRef, logData);
      });

      _logger.log(
        'Mensaje desbloqueado',
        level: 'INFO',
        extraData: {
          'chatId': chatId,
          'messageId': messageId,
          'docId': docId,
        },
      );

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error = 'Error desbloqueando mensaje: $e';
      _isLoading = false;
      notifyListeners();

      _logger.log(
        'Error desbloqueando mensaje: $e',
        level: 'ERROR',
        extraData: {
          'chatId': chatId,
          'messageId': messageId,
          'docId': docId,
        },
      );

      throw Exception(_error);
    }
  }

  /// Limpiar error
  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    super.dispose();
  }
}

/// Modelo para mensaje reportado
class ReportedMessage {
  final String id;
  final String messageId;
  final String messageContent;
  final String messageType;
  final String senderId;
  final String senderName;
  final DateTime reportedAt;
  final String reportReason;
  final String reportedBy;

  ReportedMessage({
    required this.id,
    required this.messageId,
    required this.messageContent,
    required this.messageType,
    required this.senderId,
    required this.senderName,
    required this.reportedAt,
    required this.reportReason,
    required this.reportedBy,
  });

  factory ReportedMessage.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return ReportedMessage(
      id: doc.id,
      messageId: data['messageId'] ?? '',
      messageContent: data['messageContent'] ?? '',
      messageType: data['messageType'] ?? 'text',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? 'Usuario',
      reportedAt: (data['reportedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      reportReason: data['reportReason'] ?? '',
      reportedBy: data['reportedBy'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'messageContent': messageContent,
      'messageType': messageType,
      'senderId': senderId,
      'senderName': senderName,
      'reportedAt': Timestamp.fromDate(reportedAt),
      'reportReason': reportReason,
      'reportedBy': reportedBy,
    };
  }
}