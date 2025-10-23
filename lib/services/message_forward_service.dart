import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/chat_message.dart';

/// Servicio para reenviar mensajes a otros chats
class MessageForwardService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Reenvía múltiples mensajes a una lista de chats
  ///
  /// [originalMessages] - Lista de mensajes originales a reenviar
  /// [targetChatIds] - Lista de IDs de chats a los que reenviar
  /// [targetGroupIds] - Lista de IDs de grupos a los que reenviar
  /// [originalChatId] - ID del chat original (para contexto)
  /// [originalContactName] - Nombre del contacto original (para contexto)
  ///
  /// Retorna un Map con el resultado: {'success': bool, 'forwardedCount': int, 'error': String?}
  Future<Map<String, dynamic>> forwardMultipleMessages({
    required List<ChatMessage> originalMessages,
    List<String>? targetChatIds,
    List<String>? targetGroupIds,
    String? originalChatId,
    String? originalContactName,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return {
          'success': false,
          'forwardedCount': 0,
          'error': 'Usuario no autenticado'
        };
      }

      int forwardedCount = 0;

      // Reenviar a chats individuales
      if (targetChatIds != null && targetChatIds.isNotEmpty) {
        for (final chatId in targetChatIds) {
          for (final message in originalMessages) {
            await _forwardToChat(
              chatId: chatId,
              originalMessage: message,
              senderId: currentUserId,
              originalChatId: originalChatId,
              originalContactName: originalContactName,
            );
          }
          forwardedCount++;
        }
      }

      // Reenviar a chats grupales
      if (targetGroupIds != null && targetGroupIds.isNotEmpty) {
        for (final groupId in targetGroupIds) {
          for (final message in originalMessages) {
            await _forwardToGroup(
              groupId: groupId,
              originalMessage: message,
              senderId: currentUserId,
              originalChatId: originalChatId,
              originalContactName: originalContactName,
            );
          }
          forwardedCount++;
        }
      }

      print('✅ ${originalMessages.length} mensajes reenviados a $forwardedCount chats');
      return {
        'success': true,
        'forwardedCount': forwardedCount,
      };
    } catch (e) {
      print('❌ Error reenviando mensajes: $e');
      return {
        'success': false,
        'forwardedCount': 0,
        'error': e.toString(),
      };
    }
  }

  /// Reenvía un mensaje a una lista de chats
  ///
  /// [originalMessage] - Mensaje original a reenviar
  /// [targetChatIds] - Lista de IDs de chats a los que reenviar
  /// [targetGroupIds] - Lista de IDs de grupos a los que reenviar
  /// [originalChatId] - ID del chat original (para contexto)
  /// [originalContactName] - Nombre del contacto original (para contexto)
  ///
  /// Retorna un Map con el resultado: {'success': bool, 'forwardedCount': int, 'error': String?}
  Future<Map<String, dynamic>> forwardMessage({
    required ChatMessage originalMessage,
    List<String>? targetChatIds,
    List<String>? targetGroupIds,
    String? originalChatId,
    String? originalContactName,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return {
          'success': false,
          'forwardedCount': 0,
          'error': 'Usuario no autenticado'
        };
      }

      int forwardedCount = 0;

      // Reenviar a chats individuales
      if (targetChatIds != null && targetChatIds.isNotEmpty) {
        for (final chatId in targetChatIds) {
          await _forwardToChat(
            chatId: chatId,
            originalMessage: originalMessage,
            senderId: currentUserId,
            originalChatId: originalChatId,
            originalContactName: originalContactName,
          );
          forwardedCount++;
        }
      }

      // Reenviar a chats grupales
      if (targetGroupIds != null && targetGroupIds.isNotEmpty) {
        for (final groupId in targetGroupIds) {
          await _forwardToGroup(
            groupId: groupId,
            originalMessage: originalMessage,
            senderId: currentUserId,
            originalChatId: originalChatId,
            originalContactName: originalContactName,
          );
          forwardedCount++;
        }
      }

      print('✅ Mensaje reenviado a $forwardedCount chats');
      return {
        'success': true,
        'forwardedCount': forwardedCount,
      };
    } catch (e) {
      print('❌ Error reenviando mensaje: $e');
      return {
        'success': false,
        'forwardedCount': 0,
        'error': e.toString(),
      };
    }
  }

  /// Reenvía un mensaje a un chat individual
  Future<void> _forwardToChat({
    required String chatId,
    required ChatMessage originalMessage,
    required String senderId,
    String? originalChatId,
    String? originalContactName,
  }) async {
    print('📤 FORWARD TO CHAT: originalContactName recibido = "$originalContactName"');

    // Crear nuevo mensaje basado en el original
    final newMessage = {
      'senderId': senderId,
      'text': originalMessage.text,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'sent',
      'type': originalMessage.type,
      'isForwarded': true, // Marcar como reenviado
      'originalSenderId': originalMessage.senderId, // Referencia al sender original
    };

    // Agregar contexto del chat original si está disponible
    if (originalChatId != null) {
      newMessage['originalChatId'] = originalChatId;
    }
    if (originalContactName != null) {
      newMessage['originalContactName'] = originalContactName;
      print('✅ FORWARD TO CHAT: Guardando originalContactName = "$originalContactName" en Firestore');
    } else {
      print('⚠️ FORWARD TO CHAT: originalContactName es null, NO se guardará en Firestore!');
    }

    // Copiar campos opcionales si existen
    if (originalMessage.imageUrl != null && originalMessage.imageUrl!.isNotEmpty) {
      newMessage['imageUrl'] = originalMessage.imageUrl!;
    }

    if (originalMessage.videoUrl != null && originalMessage.videoUrl!.isNotEmpty) {
      newMessage['videoUrl'] = originalMessage.videoUrl!;
    }

    if (originalMessage.audioUrl != null && originalMessage.audioUrl!.isNotEmpty) {
      newMessage['audioUrl'] = originalMessage.audioUrl!;
    }

    if (originalMessage.waveformData != null && originalMessage.waveformData!.isNotEmpty) {
      newMessage['waveformData'] = originalMessage.waveformData!;
    }

    // Guardar mensaje en el chat
    await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add(newMessage);

    // Actualizar el último mensaje del chat
    await _firestore.collection('chats').doc(chatId).update({
      'lastMessage': originalMessage.text,
      'lastMessageTimestamp': FieldValue.serverTimestamp(),
      'lastMessageSenderId': senderId,
    });

    print('✅ Mensaje reenviado a chat: $chatId');
  }

  /// Reenvía un mensaje a un chat grupal
  Future<void> _forwardToGroup({
    required String groupId,
    required ChatMessage originalMessage,
    required String senderId,
    String? originalChatId,
    String? originalContactName,
  }) async {
    print('📤 FORWARD TO GROUP: originalContactName recibido = "$originalContactName"');

    // Crear nuevo mensaje basado en el original
    final newMessage = {
      'senderId': senderId,
      'text': originalMessage.text,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'sent',
      'type': originalMessage.type,
      'isForwarded': true, // Marcar como reenviado
      'originalSenderId': originalMessage.senderId, // Referencia al sender original
    };

    // Agregar contexto del chat original si está disponible
    if (originalChatId != null) {
      newMessage['originalChatId'] = originalChatId;
    }
    if (originalContactName != null) {
      newMessage['originalContactName'] = originalContactName;
      print('✅ FORWARD TO GROUP: Guardando originalContactName = "$originalContactName" en Firestore');
    } else {
      print('⚠️ FORWARD TO GROUP: originalContactName es null, NO se guardará en Firestore!');
    }

    // Copiar campos opcionales si existen
    if (originalMessage.imageUrl != null && originalMessage.imageUrl!.isNotEmpty) {
      newMessage['imageUrl'] = originalMessage.imageUrl!;
    }

    if (originalMessage.videoUrl != null && originalMessage.videoUrl!.isNotEmpty) {
      newMessage['videoUrl'] = originalMessage.videoUrl!;
    }

    if (originalMessage.audioUrl != null && originalMessage.audioUrl!.isNotEmpty) {
      newMessage['audioUrl'] = originalMessage.audioUrl!;
    }

    if (originalMessage.waveformData != null && originalMessage.waveformData!.isNotEmpty) {
      newMessage['waveformData'] = originalMessage.waveformData!;
    }

    // Guardar mensaje en el grupo
    await _firestore
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .add(newMessage);

    // Actualizar el último mensaje del grupo
    await _firestore.collection('groups').doc(groupId).update({
      'lastMessage': originalMessage.text,
      'lastMessageTimestamp': FieldValue.serverTimestamp(),
      'lastMessageSenderId': senderId,
    });

    print('✅ Mensaje reenviado a grupo: $groupId');
  }
}
