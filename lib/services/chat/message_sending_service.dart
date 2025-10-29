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
import '../network_status_service.dart';
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
  }) async {
    // 1. Verificar moderación a nivel de CHAT
    final chatDoc = await _firestore.collection('chats').doc(chatId).get();
    bool moderationEnabled = chatDoc.data()?['moderationEnabled'] ?? false;

    // 2. Verificar moderación a nivel de CONTACTO (del receptor)
    if (!moderationEnabled) {
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
          final senderSettings =
              moderationSettings[currentUserId] as Map<String, dynamic>?;
          if (senderSettings != null && senderSettings['enabled'] == true) {
            moderationEnabled = true;
            print('🔒 Usuario emisor tiene moderación activa');
          }
        }
      }
    }

    // 3. Verificar moderación si está activada
    String? tempId;
    if (moderationEnabled) {
      print('🔒 Moderación activa, verificando mensaje...');

      tempId = const Uuid().v4();
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('checkMessageBeforeSending').call({
        'chatId': chatId,
        'text': text,
        'type': 'text',
        'localId': tempId,
      });

      final approved = result.data['approved'] as bool;

      if (!approved) {
        final reason =
            result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
        print('🚫 Mensaje bloqueado: $reason');
        throw Exception(reason);
      }

      print('✅ Mensaje aprobado por moderación');
    }

    // 4. Enviar mensaje a Firestore
    final messageData = {
      'senderId': currentUserId,
      'text': text,
      'timestamp': FieldValue.serverTimestamp(),
      'isRead': false,
    };

    if (replyTo != null) {
      messageData['replyTo'] = replyTo;
    }

    final docRef = await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add(messageData)
        .timeout(_sendTimeout);

    print('✅ Mensaje enviado: $text');
    return docRef.id;
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

    print('📷 Imagen seleccionada: ${image.path}');

    // 2. Comprimir imagen
    final MediaCompressionService compressionService = MediaCompressionService();
    final File originalFile = File(image.path);

    print('⏳ Comprimiendo imagen...');
    final File? compressedFile = await compressionService.compressImage(originalFile);

    if (compressedFile == null) {
      throw Exception('La imagen es muy grande o no se pudo comprimir');
    }

    final sizeMB = await compressionService.getFileSizeMB(compressedFile);
    print('✅ Imagen comprimida: ${sizeMB.toStringAsFixed(2)} MB');

    // 3. Subir imagen comprimida
    final imageUrl = await _mediaService.uploadImageFile(
      imageFile: compressedFile,
      chatId: chatId,
      userId: currentUserId,
    );

    if (imageUrl == null) throw Exception('Error subiendo imagen');

    // 4. Enviar a Firestore
    final docRef = await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add({
          'senderId': currentUserId,
          'imageUrl': imageUrl,
          'type': 'image',
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
        })
        .timeout(_sendTimeout);

    print('✅ Imagen enviada');
    return docRef.id;
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

    // 3. Enviar a Firestore
    final docRef = await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add({
          'senderId': currentUserId,
          'videoUrl': videoUrl,
          'type': 'video',
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
        })
        .timeout(_sendTimeout);

    print('✅ Video enviado');
    return docRef.id;
  }

  /// Enviar audio con waveform
  Future<String> sendAudioMessage({
    required String chatId,
    required String currentUserId,
    required String audioPath,
  }) async {
    print('🎤 Audio seleccionado: $audioPath');

    // 1. Validar tamaño del audio
    final MediaCompressionService compressionService = MediaCompressionService();
    final File audioFile = File(audioPath);
    final File? validatedAudio = await compressionService.validateAudio(audioFile);

    if (validatedAudio == null) {
      throw Exception('El audio excede el límite de 10 MB');
    }

    // 2. Procesar waveform
    print('🎵 Procesando waveform del audio...');
    final AudioProcessingService audioProcessing = AudioProcessingService();
    final waveformData = await audioProcessing.extractWaveform(validatedAudio);
    print('✅ Waveform procesado: ${waveformData.length} puntos');

    // 3. Subir audio
    final audioUrl = await _mediaService.uploadAudioFile(
      audioFile: validatedAudio,
      chatId: chatId,
      userId: currentUserId,
    );

    if (audioUrl == null) throw Exception('Error subiendo audio');

    // 4. Enviar a Firestore con waveform
    final docRef = await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add({
          'senderId': currentUserId,
          'audioUrl': audioUrl,
          'type': 'audio',
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
          'waveformData': waveformData,
        })
        .timeout(_sendTimeout);

    print('✅ Audio enviado con waveform');
    return docRef.id;
  }

  /// Forward mensaje a otro chat
  Future<String> forwardMessage({
    required String targetChatId,
    required String currentUserId,
    required ChatMessage originalMessage,
    required String originalContactName,
  }) async {
    final messageData = {
      'senderId': currentUserId,
      'timestamp': FieldValue.serverTimestamp(),
      'isRead': false,
      'isForwarded': true,
      'originalSenderId': originalMessage.senderId,
      'originalChatId': originalMessage.id,
      'originalContactName': originalContactName,
    };

    // Copiar contenido según tipo
    if (originalMessage.text != null) {
      messageData['text'] = originalMessage.text!;
      messageData['type'] = 'text';
    } else if (originalMessage.imageUrl != null) {
      messageData['imageUrl'] = originalMessage.imageUrl!;
      messageData['type'] = 'image';
    } else if (originalMessage.videoUrl != null) {
      messageData['videoUrl'] = originalMessage.videoUrl!;
      messageData['type'] = 'video';
    } else if (originalMessage.audioUrl != null) {
      messageData['audioUrl'] = originalMessage.audioUrl!;
      messageData['type'] = 'audio';
      if (originalMessage.waveformData != null) {
        messageData['waveformData'] = originalMessage.waveformData!;
      }
    }

    final docRef = await _firestore
        .collection('chats')
        .doc(targetChatId)
        .collection('messages')
        .add(messageData)
        .timeout(_sendTimeout);

    print('✅ Mensaje reenviado');
    return docRef.id;
  }

  /// Actualizar mensaje bloqueado (re-moderar)
  Future<void> updateBlockedMessage({
    required String chatId,
    required String messageId,
    required String newText,
  }) async {
    print('🔄 Actualizando mensaje bloqueado ${messageId.substring(0, 8)}...');

    final functions = FirebaseFunctions.instance;
    final result = await functions.httpsCallable('checkMessageBeforeSending').call({
      'chatId': chatId,
      'text': newText,
      'type': 'text',
      'messageId': messageId,
    });

    final approved = result.data['approved'] as bool;

    if (!approved) {
      final reason =
          result.data['reason'] as String? ?? 'Contenido inapropiado detectado';
      print('🚫 Mensaje re-bloqueado: $reason');
      throw Exception(reason);
    }

    print('✅ Mensaje actualizado y aprobado');
  }

  /// Encolar mensaje para envío offline
  Future<void> enqueueOfflineMessage({
    required String chatId,
    required String currentUserId,
    required String text,
    required String tempId,
    Map<String, dynamic>? replyTo,
  }) async {
    print('📴 Sin conexión - encolando mensaje para envío posterior');

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
