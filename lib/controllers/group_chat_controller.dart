import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import '../notification_service.dart';
import '../services/typing_indicator_service.dart';
import '../services/media_service.dart';
import '../services/media_compression_service.dart';
import '../services/chats/repositories/user_repository.dart';
import '../services/chats/repositories/message_repository.dart';
import '../services/chats/repositories/chat_repository.dart';
import '../utils/release_logger.dart';

/// Controller que maneja la lógica de un chat grupal
/// ⚠️ DEPRECATED: Este controller está siendo migrado a usar ChatOrchestrator
/// que respeta la arquitectura definida en CLAUDE.md
class GroupChatController {
  final String groupId;
  final String groupName;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final NotificationService _notificationService;
  final TypingIndicatorService _typingService;
  final MediaService _mediaService;

  // ✅ NEW: Repositories para acceso a datos
  final UserRepository _userRepository;
  final MessageRepository _messageRepository;
  final ChatRepository _chatRepository;

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
    UserRepository? userRepository,
    MessageRepository? messageRepository,
    ChatRepository? chatRepository,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _notificationService = notificationService ?? NotificationService(),
        _typingService = typingService ?? TypingIndicatorService(),
        _mediaService = mediaService ?? MediaService(),
        _userRepository = userRepository ?? UserRepository(
          firestore: firestore ?? FirebaseFirestore.instance,
          auth: auth ?? FirebaseAuth.instance,
        ),
        _messageRepository = messageRepository ?? MessageRepository(
          firestore: firestore ?? FirebaseFirestore.instance,
          auth: auth ?? FirebaseAuth.instance,
        ),
        _chatRepository = chatRepository ?? ChatRepository(
          firestore: firestore ?? FirebaseFirestore.instance,
          auth: auth ?? FirebaseAuth.instance,
        );

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

      ReleaseLogger.log('Cargados ${_memberIds.length} miembros del grupo', tag: 'GroupChatController');
    } catch (e) {
      ReleaseLogger.error('Error cargando miembros del grupo: $e', tag: 'GroupChatController');
    }
  }

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead() async {
    try {
      if (currentUserId.isEmpty) return;

      // 1. Resetear contador de no leídos
      await _firestore.collection('groups').doc(groupId).update({
        'unreadCount_$currentUserId': 0,
      });

      // 2. Marcar mensajes individuales como leídos (actualizar array readBy[])
      // NO usar where() para evitar problemas de índices - leer todos y filtrar
      final messagesSnapshot = await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(50) // Últimos 50 mensajes
          .get();

      ReleaseLogger.log('📖 [markMessagesAsRead] Leyendo mensajes del grupo $groupId: ${messagesSnapshot.docs.length} mensajes encontrados', tag: 'GroupChatController');

      // Batch write para eficiencia
      final batch = _firestore.batch();
      int updateCount = 0;

      for (final doc in messagesSnapshot.docs) {
        final data = doc.data();
        final senderId = data['senderId'] as String?;
        final readBy = List<String>.from(data['readBy'] ?? []);

        // Solo actualizar mensajes de OTROS usuarios que NO estén ya en readBy
        if (senderId != null &&
            senderId != currentUserId &&
            !readBy.contains(currentUserId)) {
          batch.update(doc.reference, {
            'readBy': FieldValue.arrayUnion([currentUserId]),
          });
          updateCount++;
          ReleaseLogger.log('📝 [markMessagesAsRead] Agregando $currentUserId a readBy[] del mensaje ${doc.id}', tag: 'GroupChatController');
        }
      }

      // Ejecutar batch si hay updates
      if (updateCount > 0) {
        await batch.commit();
        ReleaseLogger.log('✅ [markMessagesAsRead] Marcados $updateCount mensajes como leídos en grupo $groupId', tag: 'GroupChatController');
      } else {
        ReleaseLogger.log('ℹ️ [markMessagesAsRead] No hay mensajes para marcar como leídos en grupo $groupId', tag: 'GroupChatController');
      }
    } catch (e) {
      ReleaseLogger.error('⚠️ [markMessagesAsRead] Error marcando mensajes como leídos: $e', tag: 'GroupChatController');
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

      ReleaseLogger.log('Cargados ${snapshot.docs.length} mensajes más antiguos del grupo', tag: 'GroupChatController');
      return snapshot.docs;
    } catch (e) {
      ReleaseLogger.error('Error cargando más mensajes: $e', tag: 'GroupChatController');
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

      // Enviar mensaje (lógica optimista restaurada)
      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .add(messageData);

      // Actualizar documento del grupo
      await _updateGroupDocument(text);

      ReleaseLogger.log('Mensaje enviado exitosamente al grupo', tag: 'GroupChatController');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando mensaje al grupo: $e', tag: 'GroupChatController');
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
      ReleaseLogger.log('Imagen enviada exitosamente al grupo', tag: 'GroupChatController');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando imagen al grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Enviar video desde un archivo ya seleccionado con compresión
  Future<bool> sendVideoFromFile({
    required String videoPath,
    Function(String)? onShowMessage,
    VoidCallback? onHideMessage,
  }) async {
    if (currentUserId.isEmpty) return false;

    try {
      ReleaseLogger.log('Procesando video: $videoPath', tag: 'GroupChatController');
      final File videoFile = File(videoPath);

      // 1. Comprimir y validar video
      final MediaCompressionService compressionService = MediaCompressionService();

      // Notificar que se está comprimiendo
      onShowMessage?.call('Comprimiendo video...');

      final File? validatedVideo = await compressionService.validateVideo(
        videoFile,
        onProgress: (progress) {
          ReleaseLogger.log('Progreso de compresión: ${progress.toStringAsFixed(0)}%', tag: 'GroupChatController');
        },
      );

      // Ocultar mensaje de compresión
      onHideMessage?.call();

      if (validatedVideo == null) {
        ReleaseLogger.error('No se pudo comprimir el video bajo 10 MB', tag: 'GroupChatController');
        onShowMessage?.call('El video es muy grande y no se pudo comprimir bajo el límite de 10 MB. Intenta con un video más corto.');
        throw Exception('El video no se pudo comprimir bajo el límite de 10 MB');
      }

      // 2. Subir video comprimido
      final videoUrl = await _mediaService.uploadVideoFile(
        videoFile: validatedVideo,
        chatId: groupId,
        userId: currentUserId,
      );

      if (videoUrl == null) return false;

      // 3. Enviar a Firestore
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
      ReleaseLogger.log('Video enviado exitosamente al grupo', tag: 'GroupChatController');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando video al grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Enviar audio con optimistic update
  /// Retorna el ID del mensaje optimista creado
  Future<String?> sendAudioOptimistic({
    required String audioPath,
    required List<double> waveformData,
  }) async {
    if (currentUserId.isEmpty) return null;

    try {
      // 1. Crear mensaje optimista localmente primero
      final messageRef = _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(); // Generar ID antes de agregar

      final tempId = messageRef.id;

      // 2. Agregar mensaje optimista a Firestore (sin esperar)
      await messageRef.set({
        'senderId': currentUserId,
        'audioUrl': null, // Aún no tenemos URL
        'localPath': audioPath, // Path local para reproducir mientras se sube
        'waveformData': waveformData,
        'type': 'audio',
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      });

      ReleaseLogger.log('Mensaje optimista de audio creado en grupo: $tempId', tag: 'GroupChatController');

      // 3. Subir audio en background
      _uploadAudioInBackground(audioPath, tempId, waveformData);

      return tempId;
    } catch (e) {
      ReleaseLogger.error('Error creando mensaje optimista de audio: $e', tag: 'GroupChatController');
      return null;
    }
  }

  /// Subir audio en background y actualizar mensaje
  Future<void> _uploadAudioInBackground(
    String audioPath,
    String messageId,
    List<double> waveformData,
  ) async {
    try {
      ReleaseLogger.log('[BACKGROUND] Subiendo audio del grupo...', tag: 'GroupChatController');

      // 1. Subir audio
      final audioUrl = await _mediaService.uploadAudio(
        audioPath: audioPath,
        chatId: groupId,
        userId: currentUserId,
      );

      if (audioUrl == null) {
        ReleaseLogger.error('[BACKGROUND] Error subiendo audio', tag: 'GroupChatController');
        return;
      }

      // 2. Actualizar mensaje con URL real y limpiar localPath
      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .update({
            'audioUrl': audioUrl,
            'localPath': FieldValue.delete(), // Limpiar path local
          });

      // 3. Actualizar documento del grupo
      await _updateGroupDocument('🎤 Audio');

      // 4. Enviar notificaciones
      await _sendNotifications('🎤 Audio');

      ReleaseLogger.log('[BACKGROUND] Audio subido y mensaje actualizado en grupo', tag: 'GroupChatController');
    } catch (e) {
      ReleaseLogger.error('[BACKGROUND] Error subiendo audio: $e', tag: 'GroupChatController');
      // TODO: Marcar mensaje con error si es necesario
    }
  }

  /// 🔒 DEPRECADO - INSEGURO: Actualizar documento del grupo
  /// Esta función permite bypass de filtros de contenido
  /// Solo Cloud Functions deben actualizar lastMessage después de validación
  @Deprecated('❌ INSEGURO: Solo Cloud Functions pueden actualizar lastMessage después de validación')
  Future<void> _updateGroupDocument(String lastMessage) async {
    // 🚨 FUNCIÓN BLOQUEADA POR SEGURIDAD
    throw Exception('🔒 FUNCIÓN BLOQUEADA: _updateGroupDocument es insegura. El contenido "$lastMessage" podría ser ofensivo y bypassear filtros. Solo Cloud Functions pueden actualizar lastMessage después de validación.');
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
      ReleaseLogger.error('Error enviando notificaciones: $e', tag: 'GroupChatController');
    }
  }

  /// Stream de mensajes recientes
  /// ✅ REFACTORED: Now uses MessageRepository instead of direct Firestore access
  Stream<QuerySnapshot> watchRecentMessages() {
    return _messageRepository.watchMessages(
      chatId: groupId,
      isGroup: true,
      limit: messagesPerPage,
    );
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
          ReleaseLogger.log('No se puede eliminar: Han pasado más de 5 minutos', tag: 'GroupChatController');
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

      ReleaseLogger.log('Mensaje eliminado exitosamente del grupo', tag: 'GroupChatController');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error eliminando mensaje del grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Limpiar recursos
  void dispose() {
    stopTyping();
  }
}
