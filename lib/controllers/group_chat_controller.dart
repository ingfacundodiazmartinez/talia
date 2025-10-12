import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../services/media_service.dart';

/// Controller que maneja la lógica de un chat grupal
class GroupChatController {
  final String groupId;
  final String groupName;

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

  // Cache de usuarios del grupo
  final Map<String, String> _userNames = {};
  final Map<String, String> _userPhotos = {};
  List<String> _memberIds = [];

  GroupChatController({
    required this.groupId,
    required this.groupName,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    NotificationService? notificationService,
    TypingIndicatorService? typingService,
    MediaService? mediaService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _notificationService = notificationService ?? NotificationService(),
        _typingService = typingService ?? TypingIndicatorService(),
        _mediaService = mediaService ?? MediaService();

  // Getters
  String get currentUserId => _auth.currentUser?.uid ?? '';
  bool get hasMoreMessages => _hasMoreMessages;
  List<DocumentSnapshot> get loadedMessages => _loadedMessages;
  Map<String, String> get userNames => _userNames;
  Map<String, String> get userPhotos => _userPhotos;
  List<String> get memberIds => _memberIds;

  /// Inicializar el controller
  Future<void> initialize() async {
    await loadGroupMembers();
    await markMessagesAsRead();
  }

  /// Cargar miembros del grupo
  Future<void> loadGroupMembers() async {
    try {
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();
      final groupData = groupDoc.data();

      if (groupData != null) {
        _memberIds = List<String>.from(groupData['members'] ?? []);

        // Cargar información de cada miembro
        for (final memberId in _memberIds) {
          final userDoc =
              await _firestore.collection('users').doc(memberId).get();
          final userData = userDoc.data();

          if (userData != null) {
            _userNames[memberId] = userData['name'] ?? 'Usuario';
            _userPhotos[memberId] = userData['photoURL'] ?? '';
          }
        }
      }

      print('✅ Cargados ${_memberIds.length} miembros del grupo');
    } catch (e) {
      print('❌ Error cargando miembros del grupo: $e');
    }
  }

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead() async {
    try {
      if (currentUserId.isEmpty) return;

      await _firestore.collection('groups').doc(groupId).update({
        'unreadCount_$currentUserId': 0,
      });

      print('✅ Mensajes marcados como leídos para grupo: $groupId');
    } catch (e) {
      print('❌ Error marcando mensajes como leídos: $e');
    }
  }

  /// Cargar más mensajes (paginación)
  Future<List<DocumentSnapshot>> loadMoreMessages() async {
    if (!_hasMoreMessages) return [];

    try {
      Query query = _firestore
          .collection('groups')
          .doc(groupId)
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

      print('📥 Cargados ${snapshot.docs.length} mensajes más antiguos del grupo');
      return snapshot.docs;
    } catch (e) {
      print('❌ Error cargando más mensajes: $e');
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
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .add(messageData);

      // Actualizar documento del grupo
      await _updateGroupDocument(text);

      // Enviar notificaciones a todos los miembros (excepto el remitente)
      await _sendNotifications(text);

      print('✅ Mensaje enviado exitosamente al grupo');
      return true;
    } catch (e) {
      print('❌ Error enviando mensaje al grupo: $e');
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
        chatId: groupId,
        userId: currentUserId,
      );

      if (imageUrl == null) return false;

      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'imageUrl': imageUrl,
            'type': 'image',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      await _updateGroupDocument('📷 Imagen');
      print('✅ Imagen enviada exitosamente al grupo');
      return true;
    } catch (e) {
      print('❌ Error enviando imagen al grupo: $e');
      return false;
    }
  }

  /// Enviar video
  Future<bool> sendVideo() async {
    if (currentUserId.isEmpty) return false;

    try {
      final videoUrl = await _mediaService.uploadVideo(
        chatId: groupId,
        userId: currentUserId,
      );

      if (videoUrl == null) return false;

      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'videoUrl': videoUrl,
            'type': 'video',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      await _updateGroupDocument('🎥 Video');
      print('✅ Video enviado exitosamente al grupo');
      return true;
    } catch (e) {
      print('❌ Error enviando video al grupo: $e');
      return false;
    }
  }

  /// Enviar audio
  Future<bool> sendAudio(String audioPath) async {
    if (currentUserId.isEmpty) return false;

    try {
      final audioUrl = await _mediaService.uploadAudio(
        audioPath: audioPath,
        chatId: groupId,
        userId: currentUserId,
      );

      if (audioUrl == null) return false;

      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .add({
            'senderId': currentUserId,
            'audioUrl': audioUrl,
            'type': 'audio',
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      await _updateGroupDocument('🎤 Audio');
      print('✅ Audio enviado exitosamente al grupo');
      return true;
    } catch (e) {
      print('❌ Error enviando audio al grupo: $e');
      return false;
    }
  }

  /// Actualizar documento del grupo
  Future<void> _updateGroupDocument(String lastMessage) async {
    // Preparar mapa de actualización
    final updateData = <String, dynamic>{
      'lastMessage': lastMessage,
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastMessageSender': currentUserId,
    };

    // Incrementar contador de no leídos para cada miembro (excepto el remitente)
    for (final memberId in _memberIds) {
      if (memberId != currentUserId) {
        updateData['unreadCount_$memberId'] = FieldValue.increment(1);
      }
    }

    await _firestore.collection('groups').doc(groupId).update(updateData);
  }

  /// Enviar notificaciones a todos los miembros (excepto el remitente)
  Future<void> _sendNotifications(String messageText) async {
    try {
      final currentUserDoc =
          await _firestore.collection('users').doc(currentUserId).get();
      final userData = currentUserDoc.data();
      final senderName = userData?['name'] ?? 'Usuario';
      final senderPhotoUrl = userData?['photoURL'];

      // Enviar notificación a cada miembro (excepto el remitente)
      for (final memberId in _memberIds) {
        if (memberId != currentUserId) {
          await _notificationService.sendChatMessageNotification(
            recipientId: memberId,
            senderId: currentUserId,
            senderName: senderName,
            senderPhotoUrl: senderPhotoUrl,
            messageText: messageText,
            chatId: groupId,
            isGroup: true,
            groupName: groupName,
          );
        }
      }
    } catch (e) {
      print('⚠️ Error enviando notificaciones: $e');
    }
  }

  /// Stream de mensajes recientes
  Stream<QuerySnapshot> watchRecentMessages() {
    return _firestore
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(messagesPerPage)
        .snapshots(includeMetadataChanges: false);
  }

  /// Stream de usuarios escribiendo
  Stream<List<String>> watchTypingUsers() {
    return _typingService.watchGroupTypingUsers(groupId, currentUserId);
  }

  /// Establecer estado de escritura
  void setTyping(bool isTyping) {
    _typingService.setTyping(groupId, isTyping, isGroup: true);
  }

  /// Detener escritura
  void stopTyping() {
    _typingService.stopTyping();
  }

  /// Obtener nombre de usuario por ID
  String getUserName(String userId) {
    return _userNames[userId] ?? 'Usuario';
  }

  /// Obtener foto de usuario por ID
  String getUserPhoto(String userId) {
    return _userPhotos[userId] ?? '';
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
          print('⚠️ No se puede eliminar: Han pasado más de 5 minutos');
          return false;
        }
      }

      // Eliminar mensaje (hard delete)
      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .delete();

      print('✅ Mensaje eliminado exitosamente del grupo');
      return true;
    } catch (e) {
      print('❌ Error eliminando mensaje del grupo: $e');
      return false;
    }
  }

  /// Limpiar recursos
  void dispose() {
    stopTyping();
  }
}
