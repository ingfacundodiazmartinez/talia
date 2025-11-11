import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../services/media_service.dart';

/// Controller que maneja la lógica de un chat individual (1 a 1)
class ChatController {
  final String chatId;
  final String contactId;
  final String contactName;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final NotificationService _notificationService;
  final TypingIndicatorService _typingService;
  final MediaService _mediaService;

  // Paginación
  static const int messagesPerPage = 30;
  DocumentSnapshot? _lastDocument;
  bool _hasMoreMessages = true;
  final List<DocumentSnapshot> _loadedMessages = [];

  // Estado del contacto
  String _contactPhotoURL = '';
  bool _contactIsOnline = false;

  ChatController({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    NotificationService? notificationService,
    TypingIndicatorService? typingService,
    MediaService? mediaService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _notificationService = notificationService ?? NotificationService(),
       _typingService = typingService ?? TypingIndicatorService(),
       _mediaService = mediaService ?? MediaService();

  // Getters
  String get currentUserId => _auth.currentUser?.uid ?? '';
  String get contactPhotoURL => _contactPhotoURL;
  bool get contactIsOnline => _contactIsOnline;
  bool get hasMoreMessages => _hasMoreMessages;
  List<DocumentSnapshot> get loadedMessages => _loadedMessages;

  /// Inicializar el controller
  Future<void> initialize() async {
    await loadContactInfo();
    await markMessagesAsRead();
  }

  /// Cargar información del contacto
  Future<void> loadContactInfo() async {
    try {
      final userDoc = await _firestore.collection('users').doc(contactId).get();
      final userData = userDoc.data();
      if (userData != null) {
        _contactPhotoURL = userData['photoURL'] ?? '';
        _contactIsOnline = userData['isOnline'] ?? false;
      }
    } catch (e) {
      // Error cargando info del contacto - no crítico
    }
  }

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead() async {
    try {
      if (currentUserId.isEmpty) return;

      await _firestore.collection('chats').doc(chatId).update({
        'unreadCount_$currentUserId': 0,
      });
    } catch (e) {
      // Error marcando mensajes como leídos - no crítico
    }
  }

  /// Cargar más mensajes (paginación)
  Future<List<DocumentSnapshot>> loadMoreMessages() async {
    if (!_hasMoreMessages) return [];

    try {
      Query query = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(messagesPerPage);

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();

      if (snapshot.docs.isEmpty) {
        _hasMoreMessages = false;
        return [];
      }

      _loadedMessages.addAll(snapshot.docs);
      _lastDocument = snapshot.docs.last;
      _hasMoreMessages = snapshot.docs.length == messagesPerPage;

      return snapshot.docs;
    } catch (e) {
      return [];
    }
  }

  /// Enviar mensaje de texto
  Future<bool> sendTextMessage({
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    if (text.trim().isEmpty || currentUserId.isEmpty) return false;

    try {
      final messageData = {
        'senderId': currentUserId,
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      };

      if (replyTo != null) {
        messageData['replyTo'] = replyTo;
      }

      // Enviar mensaje
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(messageData);

      // Actualizar documento del chat
      await _updateChatDocument(text);

      // Enviar notificación
      await _sendNotification(text);

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Enviar imagen
  Future<bool> sendImage({
    required String imagePath,
    required bool fromCamera,
  }) async {
    if (currentUserId.isEmpty) return false;

    try {
      final imageUrl = await _mediaService.uploadImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        chatId: chatId,
        userId: currentUserId,
      );

      if (imageUrl == null) return false;

      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'imageUrl': imageUrl,
            'type': 'image',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      await _updateChatDocument('📷 Imagen');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Enviar video
  Future<bool> sendVideo() async {
    if (currentUserId.isEmpty) return false;

    try {
      final videoUrl = await _mediaService.uploadVideo(
        chatId: chatId,
        userId: currentUserId,
      );

      if (videoUrl == null) return false;

      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'videoUrl': videoUrl,
            'type': 'video',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      await _updateChatDocument('🎥 Video');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Enviar audio
  Future<bool> sendAudio(String audioPath) async {
    if (currentUserId.isEmpty) return false;

    try {
      final audioUrl = await _mediaService.uploadAudio(
        audioPath: audioPath,
        chatId: chatId,
        userId: currentUserId,
      );

      if (audioUrl == null) return false;

      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'audioUrl': audioUrl,
            'type': 'audio',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      await _updateChatDocument('🎤 Audio');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 🔒 DEPRECADO - INSEGURO: Actualizar documento del chat
  /// Esta función permite bypass de filtros de contenido
  /// Solo Cloud Functions deben actualizar lastMessage después de validación
  @Deprecated('❌ INSEGURO: Solo Cloud Functions pueden actualizar lastMessage después de validación')
  Future<void> _updateChatDocument(String lastMessage) async {
    // 🚨 FUNCIÓN BLOQUEADA POR SEGURIDAD
    throw Exception('🔒 FUNCIÓN BLOQUEADA: _updateChatDocument es insegura. El contenido "$lastMessage" podría ser ofensivo y bypassear filtros. Solo Cloud Functions pueden actualizar lastMessage después de validación.');
  }

  /// Enviar notificación al contacto
  Future<void> _sendNotification(String messageText) async {
    try {
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final userData = currentUserDoc.data();
      final senderName = userData?['name'] ?? 'Usuario';
      final senderPhotoUrl = userData?['photoURL'];

      await _notificationService.sendChatMessageNotification(
        recipientId: contactId,
        senderId: currentUserId,
        senderName: senderName,
        senderPhotoUrl: senderPhotoUrl,
        messageText: messageText,
        chatId: chatId,
        isGroup: false,
      );
    } catch (e) {
      // Error enviando notificación - no crítico
    }
  }

  /// Stream de mensajes recientes
  Stream<QuerySnapshot> watchRecentMessages() {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(messagesPerPage)
        .snapshots(includeMetadataChanges: false);
  }

  /// Stream del estado online del contacto
  Stream<DocumentSnapshot> watchContactStatus() {
    return _firestore.collection('users').doc(contactId).snapshots();
  }

  /// Stream de indicador de escritura
  Stream<bool> watchTypingIndicator() {
    return _typingService.watchOtherUserTyping(chatId, contactId);
  }

  /// Establecer estado de escritura
  void setTyping(bool isTyping) {
    _typingService.setTyping(chatId, isTyping, isGroup: false);
  }

  /// Detener escritura
  void stopTyping() {
    _typingService.stopTyping();
  }

  /// Eliminar mensaje (solo si fue enviado por el usuario actual y hace menos de 5 minutos)
  Future<bool> deleteMessage(String messageId, Timestamp? timestamp) async {
    if (currentUserId.isEmpty) return false;

    try {
      // Verificar que no hayan pasado más de 5 minutos
      if (timestamp != null) {
        final now = DateTime.now();
        final messageTime = timestamp.toDate();
        final difference = now.difference(messageTime);

        if (difference.inMinutes >= 5) {
          return false;
        }
      }

      // Eliminar mensaje (hard delete)
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .delete();

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Limpiar recursos
  void dispose() {
    stopTyping();
  }
}
