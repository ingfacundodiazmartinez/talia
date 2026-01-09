import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../models/chat_message.dart';
import '../media_service.dart';
import '../media_compression_service.dart';
import '../sound_service.dart';
import '../audio_processing_service.dart';
import '../offline_queue_service.dart';

/// Servicio para envío de mensajes (texto, media, audio)
///
/// Responsabilidades:
/// - Enviar mensajes de texto con moderación
/// - Enviar imágenes con compresión
/// - Enviar videos con compresión y thumbnail
/// - Enviar audios con waveform
/// - Forward de mensajes
/// - Gestión de optimistic updates
/// - Queue de mensajes offline
class MessageSendingService {
  final FirebaseFirestore _firestore;
  final MediaService _mediaService;
  final SoundService _soundService;

  static const Duration _sendTimeout = Duration(seconds: 20);

  MessageSendingService({
    FirebaseFirestore? firestore,
    MediaService? mediaService,
    SoundService? soundService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _mediaService = mediaService ?? MediaService(),
        _soundService = soundService ?? SoundService();

  /// Enviar mensaje de texto con moderación
  Future<String> sendTextMessage({
    required String chatId,
    required String currentUserId,
    required String text,
    required String contactId,
    Map<String, dynamic>? replyTo,
    String? localId, // ✅ Agregar parámetro localId
  }) async {
    // 1. Verificar moderación a nivel de CHAT (solo si el chat existe)
    bool moderationEnabled = false;
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (chatDoc.exists) {
        moderationEnabled = chatDoc.data()?['moderationEnabled'] ?? false;
      }
    } catch (e) {
      // Continuar sin moderación del chat si hay error
    }

    // 2. Verificar moderación a nivel de CONTACTO (del receptor)
    // ✅ FIX: Cuando A activa moderación para B, se guarda en moderationSettings[A]
    // Significa: "A quiere moderar los mensajes que RECIBE"
    // Por lo tanto, cuando el sender (currentUserId) envía a contactId,
    // debemos verificar si contactId tiene moderación activada
    if (!moderationEnabled) {
      try {
        final sortedUsers = [currentUserId, contactId]..sort();
        final contactsQuery = await _firestore
            .collection('contacts')
            .where('users', isEqualTo: sortedUsers)
            .limit(1)
            .get();

        if (contactsQuery.docs.isNotEmpty) {
          final contactDoc = contactsQuery.docs.first;
          final moderationSettings =
              contactDoc.data()['moderationSettings'] as Map<String, dynamic>?;

          if (moderationSettings != null) {
            // ✅ FIX: Verificar settings del SENDER (currentUserId)
            // Cuando un padre activa moderación para un hijo, se guarda en moderationSettings[childId]
            // Por lo tanto, cuando el sender (currentUserId) envía mensajes,
            // debemos verificar si el sender tiene moderación activada
            final senderSettings =
                moderationSettings[currentUserId] as Map<String, dynamic>?;
            if (senderSettings != null && senderSettings['enabled'] == true) {
              moderationEnabled = true;
            }
          }
        }
      } catch (e) {
        // Continuar sin moderación del contacto si hay error
      }
    }

    // 3. Verificar moderación si está activada
    String? tempId;
    if (moderationEnabled) {
      tempId = const Uuid().v4();
      final functions = FirebaseFunctions.instance;
      // ✅ FIX: Agregar timeout para evitar que el mensaje quede "enviando" indefinidamente
      final result = await functions.httpsCallable('checkMessageBeforeSending').call({
        'chatId': chatId,
        'text': text,
        'type': 'text',
        'localId': tempId,
      }).timeout(_sendTimeout);

      final approved = result.data['approved'] as bool;

      if (!approved) {
        final reason =
            result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
        throw Exception(reason);
      }
    }

    // 🔒 SEGURIDAD: NO actualizar lastMessage desde frontend para evitar bypass de filtros
    // La Cloud Function actualizará lastMessage DESPUÉS de validar el contenido

    // 5. Enviar mensaje via Cloud Function
    final functions = FirebaseFunctions.instance;
    final result = await functions.httpsCallable('sendChatMessage').call({
      'chatId': chatId,
      'text': text,
      if (replyTo != null) 'replyTo': replyTo,
      if (localId != null) 'localId': localId, // ✅ Enviar localId a Cloud Function
    }).timeout(_sendTimeout);

    final success = result.data['success'] as bool;
    if (!success) {
      throw Exception(result.data['error'] ?? 'Error enviando mensaje');
    }

    final messageId = result.data['messageId'] as String;
    return messageId;
  }

  /// Enviar imagen con compresión
  Future<String> sendImageMessage({
    required String chatId,
    required String currentUserId,
    required ImageSource source,
  }) async {
    // 1. Seleccionar imagen
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1920,
      maxHeight: 1920,
    );

    if (image == null) throw Exception('No se seleccionó imagen');

    // 2. Comprimir imagen
    final MediaCompressionService compressionService = MediaCompressionService();
    final File originalFile = File(image.path);

    final File? compressedFile = await compressionService.compressImage(originalFile);

    if (compressedFile == null) {
      throw Exception('La imagen es muy grande o no se pudo comprimir');
    }

    // 3. Subir imagen comprimida
    final imageUrl = await _mediaService.uploadImageFile(
      imageFile: compressedFile,
      chatId: chatId,
      userId: currentUserId,
    );

    if (imageUrl == null) throw Exception('Error subiendo imagen');

    // 🔒 SEGURIDAD: NO actualizar lastMessage desde frontend para evitar bypass de filtros
    // La Cloud Function actualizará lastMessage DESPUÉS de validar el contenido

    // 5. Enviar via Cloud Function
    final functions = FirebaseFunctions.instance;
    final result = await functions.httpsCallable('sendChatMessage').call({
      'chatId': chatId,
      'imageUrl': imageUrl,
    }).timeout(_sendTimeout);

    final success = result.data['success'] as bool;
    if (!success) {
      throw Exception(result.data['error'] ?? 'Error enviando imagen');
    }

    final messageId = result.data['messageId'] as String;
    return messageId;
  }

  /// Enviar video con compresión
  Future<String> sendVideoMessage({
    required String chatId,
    required String currentUserId,
    required String videoPath,
  }) async {
    // 1. Comprimir y validar video
    final MediaCompressionService compressionService = MediaCompressionService();
    final File videoFile = File(videoPath);

    final File? validatedVideo = await compressionService.validateVideo(videoFile);

    if (validatedVideo == null) {
      throw Exception('El video no se pudo comprimir bajo el límite de 10 MB');
    }

    // 2. Subir video
    final videoUrl = await _mediaService.uploadVideoFile(
      videoFile: validatedVideo,
      chatId: chatId,
      userId: currentUserId,
    );

    if (videoUrl == null) throw Exception('Error subiendo video');

    // 3. Actualización optimista del lastMessage (solo para el sender)
    try {
      await _firestore.collection('chats').doc(chatId).update({
        'lastMessage': '🎥 Video',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': currentUserId,
      });
    } catch (e) {
      // Continuar - la Cloud Function creará el chat
    }

    // 4. Enviar via Cloud Function
    final functions = FirebaseFunctions.instance;
    final result = await functions.httpsCallable('sendChatMessage').call({
      'chatId': chatId,
      'videoUrl': videoUrl,
    }).timeout(_sendTimeout);

    final success = result.data['success'] as bool;
    if (!success) {
      throw Exception(result.data['error'] ?? 'Error enviando video');
    }

    final messageId = result.data['messageId'] as String;
    return messageId;
  }

  /// Enviar audio con waveform
  Future<String> sendAudioMessage({
    required String chatId,
    required String currentUserId,
    required String audioPath,
    bool isAiGenerated = false,
  }) async {
    // 1. Validar tamaño del audio
    final MediaCompressionService compressionService = MediaCompressionService();
    final File audioFile = File(audioPath);
    final File? validatedAudio = await compressionService.validateAudio(audioFile);

    if (validatedAudio == null) {
      throw Exception('El audio excede el límite de 10 MB');
    }

    // 2. Procesar waveform
    final AudioProcessingService audioProcessing = AudioProcessingService();
    final waveformData = await audioProcessing.extractWaveform(validatedAudio);

    // 3. Subir audio
    final audioUrl = await _mediaService.uploadAudioFile(
      audioFile: validatedAudio,
      chatId: chatId,
      userId: currentUserId,
    );

    if (audioUrl == null) throw Exception('Error subiendo audio');

    // 4. Actualización optimista del lastMessage (solo para el sender)
    // ✅ FIX: Incluir todos los campos necesarios para evitar inconsistencias
    try {
      await _firestore.collection('chats').doc(chatId).update({
        'lastMessage': '🎤 Audio',
        'lastMessageType': 'audio',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSender': currentUserId,
        'lastActivity': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Continuar - la Cloud Function creará el chat
    }

    // 5. Enviar via Cloud Function con waveform
    final functions = FirebaseFunctions.instance;
    final result = await functions.httpsCallable('sendChatMessage').call({
      'chatId': chatId,
      'audioUrl': audioUrl,
      'waveformData': waveformData,
      'isAiGenerated': isAiGenerated,
    }).timeout(_sendTimeout);

    final success = result.data['success'] as bool;
    if (!success) {
      throw Exception(result.data['error'] ?? 'Error enviando audio');
    }

    final messageId = result.data['messageId'] as String;
    return messageId;
  }

  /// Forward mensaje a otro chat
  Future<String> forwardMessage({
    required String targetChatId,
    required String currentUserId,
    required ChatMessage originalMessage,
    required String originalContactName,
  }) async {
    final Map<String, dynamic> callData = {
      'chatId': targetChatId,
    };

    // Copiar contenido según tipo
    if (originalMessage.text != null) {
      callData['text'] = originalMessage.text!;
    } else if (originalMessage.imageUrl != null) {
      callData['imageUrl'] = originalMessage.imageUrl!;
    } else if (originalMessage.videoUrl != null) {
      callData['videoUrl'] = originalMessage.videoUrl!;
    } else if (originalMessage.audioUrl != null) {
      callData['audioUrl'] = originalMessage.audioUrl!;
      if (originalMessage.waveformData != null) {
        callData['waveformData'] = originalMessage.waveformData!;
      }
    }

    // Enviar via Cloud Function
    final functions = FirebaseFunctions.instance;
    final result = await functions.httpsCallable('sendChatMessage').call(callData).timeout(_sendTimeout);

    final success = result.data['success'] as bool;
    if (!success) {
      throw Exception(result.data['error'] ?? 'Error reenviando mensaje');
    }

    final messageId = result.data['messageId'] as String;
    return messageId;
  }

  /// Actualizar mensaje bloqueado (re-moderar)
  Future<void> updateBlockedMessage({
    required String chatId,
    required String messageId,
    required String newText,
  }) async {
    final functions = FirebaseFunctions.instance;
    // ✅ FIX: Agregar timeout para evitar espera indefinida
    final result = await functions.httpsCallable('checkMessageBeforeSending').call({
      'chatId': chatId,
      'text': newText,
      'type': 'text',
      'messageId': messageId,
    }).timeout(_sendTimeout);

    final approved = result.data['approved'] as bool;

    if (!approved) {
      final reason =
          result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
      throw Exception(reason);
    }
  }

  /// Encolar mensaje para envío offline
  Future<void> enqueueOfflineMessage({
    required String chatId,
    required String currentUserId,
    required String text,
    required String tempId,
    Map<String, dynamic>? replyTo,
  }) async {
    await OfflineQueueService().enqueueOperation(
      type: OfflineQueueService.OP_SEND_MESSAGE,
      data: {
        'chatId': chatId,
        'message': {
          'senderId': currentUserId,
          'text': text,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'isRead': false,
          if (replyTo != null) 'replyTo': replyTo,
        },
        'tempId': tempId,
      },
      priority: 2,
    );
  }

  /// Reproducir sonido de envío
  void playSendSound() {
    _soundService.playSendSound();
  }
}
