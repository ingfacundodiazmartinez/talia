import 'package:cloud_firestore/cloud_firestore.dart';
import '../message_cache_service.dart';
import '../delivery_receipts_service.dart';
import '../read_receipts_service.dart';

/// Servicio para acciones sobre mensajes
///
/// Responsabilidades:
/// - Eliminar mensajes (con validación de tiempo)
/// - Editar mensajes (para mensajes bloqueados)
/// - Agregar reacciones
/// - Marcar mensajes como leídos
/// - Marcar todos los mensajes como leídos
/// - Limpiar chat
class MessageActionsService {
  final FirebaseFirestore _firestore;
  final MessageCacheService _cacheService;
  final DeliveryReceiptsService _deliveryReceiptsService;
  final ReadReceiptsService _readReceiptsService;

  MessageActionsService({
    FirebaseFirestore? firestore,
    MessageCacheService? cacheService,
    DeliveryReceiptsService? deliveryReceiptsService,
    ReadReceiptsService? readReceiptsService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _cacheService = cacheService ?? MessageCacheService(),
        _deliveryReceiptsService =
            deliveryReceiptsService ?? DeliveryReceiptsService(),
        _readReceiptsService = readReceiptsService ?? ReadReceiptsService();

  /// Eliminar mensaje (solo dentro de 5 minutos)
  Future<bool> deleteMessage({
    required String chatId,
    required String messageId,
    required String currentUserId,
    Timestamp? timestamp,
  }) async {
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

      // Eliminar del cache
      await _cacheService.deleteMessage(chatId, messageId);

      // Eliminar de Firestore
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .delete();

      print('✅ Mensaje eliminado exitosamente');
      return true;
    } catch (e) {
      print('❌ Error eliminando mensaje: $e');
      return false;
    }
  }

  /// Limpiar chat (borrar todos los mensajes localmente)
  Future<bool> clearChat({
    required String chatId,
    required String currentUserId,
  }) async {
    try {
      // Marcar timestamp de limpieza en Firestore
      final now = Timestamp.now();
      await _firestore.collection('chats').doc(chatId).set({
        'clearedAt_$currentUserId': now,
      }, SetOptions(merge: true));

      // Limpiar cache
      await _cacheService.clearChat(chatId);

      print('🧹 Chat limpiado exitosamente');
      return true;
    } catch (e) {
      print('❌ Error limpiando chat: $e');
      return false;
    }
  }

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead({
    required String chatId,
    required String currentUserId,
  }) async {
    try {
      // Verificar si el chat existe
      final chatRef = _firestore.collection('chats').doc(chatId);
      final chatDoc = await chatRef.get();

      if (!chatDoc.exists) {
        print('💬 Chat vacío, no hay mensajes que marcar como leídos');
        return;
      }

      // Marcar contador de no leídos en 0
      await chatRef.update({'unreadCount_$currentUserId': 0});

      // Marcar mensajes como entregados primero
      await _deliveryReceiptsService.markMessagesAsDelivered(chatId: chatId);

      // Luego marcar como leídos
      await _readReceiptsService.markMessagesAsSeen(chatId: chatId);

      print('✅ Mensajes marcados como leídos');
    } catch (e) {
      if (e.toString().contains('permission-denied')) {
        print('💬 Chat vacío, nada que marcar como leído');
      } else {
        print('❌ Error marcando mensajes como leídos: $e');
      }
    }
  }

  /// Agregar reacción a un mensaje
  Future<void> addReaction({
    required String chatId,
    required String messageId,
    required String currentUserId,
    required String reaction,
  }) async {
    try {
      final messageRef = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();
      if (!messageDoc.exists) {
        print('❌ Mensaje no encontrado');
        return;
      }

      final messageData = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(
        messageData['reactions'] as Map<String, dynamic>? ?? {},
      );

      // Agregar o actualizar reacción
      reactions[currentUserId] = reaction;

      await messageRef.update({'reactions': reactions});
      print('✅ Reacción agregada: $reaction');
    } catch (e) {
      print('❌ Error agregando reacción: $e');
    }
  }

  /// Eliminar reacción de un mensaje
  Future<void> removeReaction({
    required String chatId,
    required String messageId,
    required String currentUserId,
  }) async {
    try {
      final messageRef = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();
      if (!messageDoc.exists) {
        print('❌ Mensaje no encontrado');
        return;
      }

      final messageData = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(
        messageData['reactions'] as Map<String, dynamic>? ?? {},
      );

      // Eliminar reacción
      reactions.remove(currentUserId);

      await messageRef.update({'reactions': reactions});
      print('✅ Reacción eliminada');
    } catch (e) {
      print('❌ Error eliminando reacción: $e');
    }
  }

  /// Editar mensaje (solo para mensajes bloqueados)
  Future<bool> editMessage({
    required String chatId,
    required String messageId,
    required String newText,
  }) async {
    try {
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'text': newText,
        'editedAt': FieldValue.serverTimestamp(),
      });

      print('✅ Mensaje editado exitosamente');
      return true;
    } catch (e) {
      print('❌ Error editando mensaje: $e');
      return false;
    }
  }
}
