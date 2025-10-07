import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

class TypingIndicatorService {
  static final TypingIndicatorService _instance = TypingIndicatorService._internal();
  factory TypingIndicatorService() => _instance;
  TypingIndicatorService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Timer? _typingTimer;
  String? _currentChatId;
  bool _isCurrentGroup = false;

  // Indicar que el usuario está escribiendo
  Future<void> setTyping(String chatId, bool isTyping, {bool isGroup = false}) async {
    final user = _auth.currentUser;
    if (user == null) return;

    _currentChatId = chatId;
    _isCurrentGroup = isGroup;

    try {
      if (isTyping) {
        // Cancelar el timer anterior si existe
        _typingTimer?.cancel();

        // Marcar como escribiendo con timestamp
        final collection = isGroup ? 'groups' : 'chats';
        await _firestore
            .collection(collection)
            .doc(chatId)
            .collection('typing')
            .doc(user.uid)
            .set({
          'userId': user.uid,
          'isTyping': true,
          'timestamp': FieldValue.serverTimestamp(),
        });

        // Auto-remover después de 3 segundos si no hay nueva actividad
        _typingTimer = Timer(Duration(seconds: 3), () {
          setTyping(chatId, false, isGroup: isGroup);
        });
      } else {
        // Eliminar indicador de escritura
        _typingTimer?.cancel();
        final collection = isGroup ? 'groups' : 'chats';
        await _firestore
            .collection(collection)
            .doc(chatId)
            .collection('typing')
            .doc(user.uid)
            .delete();
      }
    } catch (e) {
      print('Error actualizando indicador de escritura: $e');
    }
  }

  // Escuchar si el otro usuario está escribiendo
  Stream<bool> watchOtherUserTyping(String chatId, String otherUserId) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('typing')
        .doc(otherUserId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) return false;

      final data = doc.data();
      if (data == null) return false;

      final isTyping = data['isTyping'] as bool? ?? false;
      final timestamp = data['timestamp'] as Timestamp?;

      // Solo considerar como "escribiendo" si fue en los últimos 5 segundos
      if (timestamp != null && isTyping) {
        final now = DateTime.now();
        final diff = now.difference(timestamp.toDate());
        return diff.inSeconds < 5;
      }

      return false;
    });
  }

  // Limpiar al salir del chat
  void stopTyping() {
    _typingTimer?.cancel();
    if (_currentChatId != null) {
      setTyping(_currentChatId!, false, isGroup: _isCurrentGroup);
    }
  }
}
