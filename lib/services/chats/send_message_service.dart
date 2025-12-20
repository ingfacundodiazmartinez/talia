import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/chat_message.dart';
import '../../utils/release_logger.dart';

/// Servicio atómico: Enviar mensaje
///
/// Responsabilidad única: Crear un nuevo mensaje en un chat
///
/// Nota: Este servicio crea el mensaje con optimistic update.
/// El mensaje se muestra inmediatamente en UI mientras se confirma.
///
/// Para mensajes con media (imágenes, videos), usar SendMediaMessageService
/// que maneja el upload a Storage primero.
class SendMessageService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  SendMessageService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Enviar mensaje de texto
  ///
  /// [chatId] - ID del chat
  /// [text] - Texto del mensaje
  /// [isGroup] - true si es grupo
  /// [replyTo] - Mensaje al que responde (opcional)
  ///
  /// Retorna (success, messageId, message, optimisticMessage)
  Future<
      ({
        bool success,
        String? messageId,
        String message,
        ChatMessage? optimisticMessage,
      })> call({
    required String chatId,
    required String text,
    bool isGroup = false,
    Map<String, dynamic>? replyTo,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          messageId: null,
          message: 'Usuario no autenticado',
          optimisticMessage: null,
        );
      }

      if (text.trim().isEmpty) {
        return (
          success: false,
          messageId: null,
          message: 'El mensaje no puede estar vacío',
          optimisticMessage: null,
        );
      }

      // Generar ID temporal para optimistic update
      final localId = 'local_${DateTime.now().millisecondsSinceEpoch}';

      // Crear mensaje optimista para mostrar en UI inmediatamente
      final optimisticMessage = ChatMessage.optimistic(
        id: localId,
        senderId: userId,
        text: text.trim(),
        replyTo: replyTo,
        type: 'text',
      );

      // Crear mensaje en Firestore
      final collection = isGroup ? 'groups_v2' : 'chats';
      final batch = _firestore.batch();

      // 1. Crear mensaje
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc();

      final messageId = messageRef.id;

      final messageData = {
        'senderId': userId,
        'text': text.trim(),
        'type': 'text',
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
        'readBy': [userId], // El sender ya lo leyó
        'localId': localId, // Para deduplicación
        if (replyTo != null) 'replyTo': replyTo,
      };

      batch.set(messageRef, messageData);

      // 2. Actualizar chat con metadata del mensaje
      final chatRef = _firestore.collection(collection).doc(chatId);

      final chatUpdateData = {
        'lastMessage': _getMessagePreview(text.trim()),
        'lastMessageType': 'text',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSender': userId,
        'lastMessageId': messageId,
        'lastActivity': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      batch.update(chatRef, chatUpdateData);

      // 3. Commit batch
      await batch.commit();

      ReleaseLogger.log(
        'Mensaje enviado: $messageId',
        tag: 'SendMessage',
      );

      return (
        success: true,
        messageId: messageId,
        message: 'Mensaje enviado',
        optimisticMessage: optimisticMessage,
      );
    } catch (e) {
      ReleaseLogger.error('Error enviando mensaje: $e', tag: 'SendMessage');
      return (
        success: false,
        messageId: null,
        message: 'Error al enviar mensaje',
        optimisticMessage: null,
      );
    }
  }

  /// Enviar mensaje reenviado (forwarded)
  Future<
      ({
        bool success,
        String? messageId,
        String message,
      })> forward({
    required String chatId,
    required ChatMessage originalMessage,
    required String originalContactName,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          messageId: null,
          message: 'Usuario no autenticado',
        );
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final batch = _firestore.batch();

      // 1. Crear mensaje reenviado
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc();

      final messageId = messageRef.id;

      final messageData = {
        'senderId': userId,
        'text': originalMessage.text,
        'type': originalMessage.type ?? 'text',
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
        'readBy': [userId],
        'isForwarded': true,
        'originalSenderId': originalMessage.senderId,
        'originalChatId': originalMessage.id,
        'originalContactName': originalContactName,
        if (originalMessage.imageUrl != null)
          'imageUrl': originalMessage.imageUrl,
        if (originalMessage.videoUrl != null)
          'videoUrl': originalMessage.videoUrl,
        if (originalMessage.audioUrl != null)
          'audioUrl': originalMessage.audioUrl,
      };

      batch.set(messageRef, messageData);

      // 2. Actualizar chat
      final chatRef = _firestore.collection(collection).doc(chatId);
      final preview = _getMessagePreview(
        originalMessage.text ?? originalMessage.preview,
      );

      batch.update(chatRef, {
        'lastMessage': '↪️ $preview',
        'lastMessageType': originalMessage.type ?? 'text',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSender': userId,
        'lastMessageId': messageId,
        'lastActivity': FieldValue.serverTimestamp(),
      });

      await batch.commit();

      ReleaseLogger.log(
        'Mensaje reenviado: $messageId',
        tag: 'SendMessage',
      );

      return (
        success: true,
        messageId: messageId,
        message: 'Mensaje reenviado',
      );
    } catch (e) {
      ReleaseLogger.error('Error reenviando mensaje: $e', tag: 'SendMessage');
      return (
        success: false,
        messageId: null,
        message: 'Error al reenviar mensaje',
      );
    }
  }

  /// Obtener preview del mensaje para lastMessage
  String _getMessagePreview(String text) {
    if (text.length > 100) {
      return '${text.substring(0, 97)}...';
    }
    return text;
  }
}
