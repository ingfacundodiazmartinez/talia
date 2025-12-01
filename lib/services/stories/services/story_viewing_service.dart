import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import '../repositories/story_repository.dart';
import '../managers/story_upload_manager.dart';
import '../utils/auth_validation_helper.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado para visualización e interacción con historias
///
/// Responsabilidades:
/// - Marcar historias como vistas
/// - Responder a historias
/// - Gestionar interacciones de viewing
/// - Tracking de visualizaciones
class StoryViewingService {
  final StoryRepository _storyRepository;
  final StoryUploadManager? _uploadManager;
  final FirebaseFunctions _functions;

  StoryViewingService({
    required StoryRepository storyRepository,
    StoryUploadManager? uploadManager,
    FirebaseFunctions? functions,
  }) : _storyRepository = storyRepository,
       _uploadManager = uploadManager,
       _functions = functions ?? FirebaseFunctions.instance;

  // ═══════════════════════════════════════════════════════════════
  // VIEWING ACTIONS
  // ═══════════════════════════════════════════════════════════════

  /// Marcar historia como vista
  Future<void> markStoryAsViewed(String storyId) async {
    final currentUserId = AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'markStoryAsViewed'
    );

    try {
      await _storyRepository.markAsViewed(storyId, currentUserId);
    } catch (e) {
      ReleaseLogger.error('Error marcando historia como vista: $e', tag: 'StoryViewing');
      throw Exception('Error marcando historia como vista: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // STORY REPLIES
  // ═══════════════════════════════════════════════════════════════

  /// Responder a historia
  ///
  /// LÓGICA (igual que mensajes):
  /// - Si NO hay moderación → Escribe directo a Firestore
  /// - Si hay moderación → Usa Cloud Function
  Future<void> replyToStory({
    required String storyId,
    required String replyText,
    String? replyMediaPath,
    String? replyMediaType,
  }) async {
    final currentUserId = AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'replyToStory'
    );

    try {
      final story = await _storyRepository.getById(storyId);
      if (story == null) throw Exception('Historia no encontrada');
      if (currentUserId == story.userId) throw Exception('No puedes responder tu propia historia');

      final replyMediaUrl = await _uploadMediaIfNeeded(replyMediaPath, currentUserId);
      final localId = const Uuid().v4();
      final needsModeration = await _checkModerationEnabled(currentUserId, story.userId);

      if (needsModeration) {
        await _replyViaCloudFunction(storyId, replyText, replyMediaUrl, replyMediaType, localId);
      } else {
        await _replyDirectToFirestore(storyId, story, currentUserId, replyText, replyMediaUrl, replyMediaType, localId);
      }
    } catch (e) {
      ReleaseLogger.error('Error respondiendo historia: $e', tag: 'StoryReply');
      _handleReplyError(e);
    }
  }

  /// Upload media si es necesario
  Future<String?> _uploadMediaIfNeeded(String? mediaPath, String userId) async {
    if (mediaPath == null || _uploadManager == null) return null;
    return await _uploadManager.uploadStoryMedia(
      filePath: mediaPath,
      storyId: 'reply_${DateTime.now().millisecondsSinceEpoch}',
      userId: userId,
    );
  }

  /// Verificar si hay moderación activada para este contacto
  Future<bool> _checkModerationEnabled(String senderId, String receiverId) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final sortedUsers = [senderId, receiverId]..sort();

      // Verificar en chat
      final chatMod = await _checkChatModeration(firestore, sortedUsers);
      if (chatMod) return true;

      // Verificar en contacto
      return await _checkContactModeration(firestore, sortedUsers, receiverId);
    } catch (e) {
      ReleaseLogger.warning('Error verificando moderación: $e', tag: 'StoryReply');
      return true; // Por seguridad, usar Cloud Function si hay error
    }
  }

  Future<bool> _checkChatModeration(FirebaseFirestore firestore, List<String> sortedUsers) async {
    final chatQuery = await firestore
        .collection('chats')
        .where('participants', isEqualTo: sortedUsers)
        .limit(1)
        .get();
    if (chatQuery.docs.isEmpty) return false;
    return chatQuery.docs.first.data()['moderationEnabled'] == true;
  }

  Future<bool> _checkContactModeration(FirebaseFirestore firestore, List<String> sortedUsers, String receiverId) async {
    final contactQuery = await firestore
        .collection('contacts')
        .where('users', isEqualTo: sortedUsers)
        .limit(1)
        .get();
    if (contactQuery.docs.isEmpty) return false;

    final moderationSettings = contactQuery.docs.first.data()['moderationSettings'] as Map<String, dynamic>?;
    final receiverSettings = moderationSettings?[receiverId] as Map<String, dynamic>?;
    return receiverSettings?['enabled'] == true;
  }

  /// Responder via Cloud Function (con moderación)
  Future<void> _replyViaCloudFunction(String storyId, String replyText, String? mediaUrl, String? mediaType, String localId) async {
    ReleaseLogger.log('🔒 [StoryReply] Usando Cloud Function (moderación activa)', tag: 'StoryReply');
    final result = await _functions.httpsCallable('replyToStory').call({
      'storyId': storyId,
      'replyText': replyText.trim(),
      'replyMediaUrl': mediaUrl,
      'replyMediaType': mediaType,
      'localId': localId,
    });
    if ((result.data as Map<String, dynamic>)['success'] != true) {
      throw Exception('Cloud Function falló');
    }

    // ✅ FIX Issue 2: También guardar respuesta en el documento de la historia
    // para que el owner pueda verla en el visor
    try {
      final userInfo = await _getCurrentUserInfo();
      await _storyRepository.addReply(
        storyId: storyId,
        userId: userInfo['userId']!,
        userName: userInfo['userName']!,
        userPhotoURL: userInfo['userPhotoURL'],
        text: replyText.trim(),
      );
      ReleaseLogger.log('✅ [StoryReply] Respuesta guardada en story document', tag: 'StoryReply');
    } catch (e) {
      // No lanzar excepción - el mensaje ya se envió al chat
      ReleaseLogger.warning('⚠️ [StoryReply] No se pudo guardar en story: $e', tag: 'StoryReply');
    }
  }

  /// Responder directo a Firestore (sin moderación)
  Future<void> _replyDirectToFirestore(String storyId, dynamic story, String senderId, String replyText, String? mediaUrl, String? mediaType, String localId) async {
    ReleaseLogger.log('⚡ [StoryReply] Escribiendo directo a Firestore', tag: 'StoryReply');
    final firestore = FirebaseFirestore.instance;
    final chatId = await _getOrCreateChat(firestore, senderId, story.userId);
    final messageData = _buildMessageData(story, storyId, senderId, replyText, mediaUrl, mediaType, localId);

    await firestore.collection('chats').doc(chatId).collection('messages').add(messageData);
    await _updateChatLastMessage(firestore, chatId, senderId, replyText);
    await _storyRepository.markAsViewed(storyId, senderId);

    // ✅ FIX Issue 2: También guardar respuesta en el documento de la historia
    // para que el owner pueda verla en el visor
    try {
      final userInfo = await _getCurrentUserInfo();
      await _storyRepository.addReply(
        storyId: storyId,
        userId: userInfo['userId']!,
        userName: userInfo['userName']!,
        userPhotoURL: userInfo['userPhotoURL'],
        text: replyText.trim(),
      );
      ReleaseLogger.log('✅ [StoryReply] Respuesta guardada en story document', tag: 'StoryReply');
    } catch (e) {
      // No lanzar excepción - el mensaje ya se envió al chat
      ReleaseLogger.warning('⚠️ [StoryReply] No se pudo guardar en story: $e', tag: 'StoryReply');
    }
  }

  Future<String> _getOrCreateChat(FirebaseFirestore firestore, String userId1, String userId2) async {
    final sortedUsers = [userId1, userId2]..sort();
    final chatQuery = await firestore.collection('chats').where('participants', isEqualTo: sortedUsers).limit(1).get();

    if (chatQuery.docs.isNotEmpty) return chatQuery.docs.first.id;

    final newChat = await firestore.collection('chats').add({
      'participants': sortedUsers,
      'createdAt': FieldValue.serverTimestamp(),
      'lastMessage': '',
      'lastMessageTime': null,
      'lastMessageSender': null,
    });
    return newChat.id;
  }

  Map<String, dynamic> _buildMessageData(dynamic story, String storyId, String senderId, String replyText, String? mediaUrl, String? mediaType, String localId) {
    // ✅ TTL: deleteAt = now + 7 días (para auto-eliminación via Firestore TTL Policy)
    final deleteAt = DateTime.now().add(const Duration(days: 7));

    final data = <String, dynamic>{
      'senderId': senderId,
      'text': '📖 Respuesta a historia: ${replyText.trim()}',
      'type': 'text',
      'timestamp': FieldValue.serverTimestamp(),
      'deleteAt': Timestamp.fromDate(deleteAt), // ✅ TTL: Firestore eliminará automáticamente
      'isRead': false,
      'localId': localId,
      'replyTo': {
        'type': 'story_reply',
        'storyId': storyId,
        'storyUserId': story.userId,
        'storyUserName': story.userName ?? 'Usuario',
        'storyMediaUrl': story.mediaUrl ?? '',
        'storyCaption': story.caption ?? '',
        'storyCreatedAt': story.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      },
    };
    if (mediaUrl != null && mediaType != null) {
      data['${mediaType}Url'] = mediaUrl;
    }
    return data;
  }

  Future<void> _updateChatLastMessage(FirebaseFirestore firestore, String chatId, String senderId, String replyText) async {
    await firestore.collection('chats').doc(chatId).update({
      'lastMessage': '📖 Respuesta a historia: ${replyText.trim()}',
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastMessageSender': senderId,
    });
  }

  Never _handleReplyError(dynamic e) {
    if (e.toString().contains('permission-denied')) throw Exception('No tienes permisos para responder esta historia');
    if (e.toString().contains('not-found')) throw Exception('Historia no encontrada');
    if (e.toString().contains('invalid-argument')) throw Exception('Datos de respuesta inválidos');
    throw e;
  }

  /// ✅ FIX Issue 2: Obtener información del usuario actual para replies
  Future<Map<String, String?>> _getCurrentUserInfo() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) throw Exception('Usuario no autenticado');

    String? userName = currentUser.displayName;
    String? userPhotoURL = currentUser.photoURL;

    // Si no hay displayName en Auth, buscar en Firestore
    if (userName == null || userName.isEmpty) {
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .get();
        if (userDoc.exists) {
          userName = userDoc.data()?['name'] as String? ?? 'Usuario';
          userPhotoURL ??= userDoc.data()?['photoURL'] as String?;
        }
      } catch (e) {
        ReleaseLogger.warning('⚠️ No se pudo obtener nombre de Firestore: $e', tag: 'StoryReply');
        userName = 'Usuario';
      }
    }

    return {
      'userId': currentUser.uid,
      'userName': userName ?? 'Usuario',
      'userPhotoURL': userPhotoURL,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // STORY LIKES
  // ═══════════════════════════════════════════════════════════════

  /// Dar like a una historia
  /// Usa Cloud Function para:
  /// - Agregar userId a likedBy
  /// - Crear chat si no existe (padre-hijo puede no tener chat)
  /// - Enviar mensaje "❤️ Le gustó tu historia"
  Future<void> likeStory(String storyId) async {
    AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'likeStory'
    );

    try {
      ReleaseLogger.log('Llamando Cloud Function likeStory para historia $storyId', tag: 'StoryLike');

      final callable = _functions.httpsCallable('likeStory');
      final result = await callable.call({'storyId': storyId});

      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['success'] != true) {
        throw Exception(data['message'] ?? 'Error desconocido');
      }

      if (data['alreadyLiked'] == true) {
        ReleaseLogger.log('Usuario ya dio like a esta historia', tag: 'StoryLike');
      } else {
        ReleaseLogger.log('✅ Like agregado a historia $storyId via Cloud Function', tag: 'StoryLike');
      }

    } catch (e) {
      ReleaseLogger.error('Error dando like a historia: $e', tag: 'StoryLike');
      throw Exception('Error dando like a historia: $e');
    }
  }

  /// Quitar like de una historia
  /// Solo remueve userId de likedBy (no borra el mensaje del chat)
  Future<void> unlikeStory(String storyId) async {
    final currentUserId = AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'unlikeStory'
    );

    try {
      final story = await _storyRepository.getById(storyId);
      if (story == null) throw Exception('Historia no encontrada');

      // Verificar si tiene like
      if (!story.likedBy.contains(currentUserId)) {
        ReleaseLogger.log('Usuario no tiene like en esta historia', tag: 'StoryLike');
        return;
      }

      // Remover like en Firestore
      await _storyRepository.removeLike(storyId, currentUserId);
      ReleaseLogger.log('✅ Like removido de historia $storyId', tag: 'StoryLike');

    } catch (e) {
      ReleaseLogger.error('Error quitando like de historia: $e', tag: 'StoryLike');
      throw Exception('Error quitando like de historia: $e');
    }
  }

  /// Enviar mensaje de like al chat del owner
  Future<void> _sendLikeMessage(dynamic story, String senderId) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final chatId = await _getOrCreateChat(firestore, senderId, story.userId);
      final localId = const Uuid().v4();

      // ✅ TTL: deleteAt = now + 7 días
      final deleteAt = DateTime.now().add(const Duration(days: 7));

      // ✅ FIX: Obtener el nombre del owner de la historia desde Firestore
      String storyOwnerName = story.userName ?? '';
      if (storyOwnerName.isEmpty || storyOwnerName == 'Usuario') {
        try {
          final ownerDoc = await firestore.collection('users').doc(story.userId).get();
          if (ownerDoc.exists) {
            storyOwnerName = ownerDoc.data()?['name'] ?? 'Usuario';
          }
        } catch (e) {
          storyOwnerName = 'Usuario';
        }
      }

      final messageData = {
        'senderId': senderId,
        'text': '❤️ Me gustó tu historia',
        'type': 'text',
        'timestamp': FieldValue.serverTimestamp(),
        'deleteAt': Timestamp.fromDate(deleteAt),
        'isRead': false,
        'localId': localId,
        'replyTo': {
          'type': 'story_like',
          'storyId': story.id,
          'storyUserId': story.userId,
          'storyUserName': storyOwnerName,
          'storyMediaUrl': story.mediaUrl ?? '',
          'storyCaption': story.caption ?? '',
          'storyCreatedAt': story.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
        },
      };

      await firestore.collection('chats').doc(chatId).collection('messages').add(messageData);
      await firestore.collection('chats').doc(chatId).update({
        'lastMessage': '❤️ Me gustó tu historia',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': senderId,
      });

      ReleaseLogger.log('✅ Mensaje de like enviado al chat $chatId', tag: 'StoryLike');
    } catch (e) {
      ReleaseLogger.error('Error enviando mensaje de like: $e', tag: 'StoryLike');
      // No lanzar excepción - el like ya se guardó
    }
  }
}