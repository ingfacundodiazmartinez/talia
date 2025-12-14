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

      return true;
    } catch (e) {
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

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Marcar mensajes como leídos
  ///
  /// Este método delega a ReadReceiptsService que se encarga de:
  /// 1. Resetear unreadCount (SIEMPRE)
  /// 2. Marcar mensajes como leídos (solo si showReadReceipts está activado)
  Future<void> markMessagesAsRead({
    required String chatId,
    required String currentUserId,
  }) async {
    try {
      // Marcar mensajes como entregados primero
      await _deliveryReceiptsService.markMessagesAsDelivered(chatId: chatId);

      // ReadReceiptsService maneja tanto el unreadCount como los read receipts
      // El unreadCount SIEMPRE se resetea, independiente de la configuración
      await _readReceiptsService.markMessagesAsSeen(chatId: chatId);
    } catch (e) {
      // Error silencioso
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
        return;
      }

      final messageData = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(
        messageData['reactions'] as Map<String, dynamic>? ?? {},
      );

      // Agregar o actualizar reacción
      reactions[currentUserId] = reaction;

      await messageRef.update({'reactions': reactions});
    } catch (e) {
      // Error silencioso
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
        return;
      }

      final messageData = messageDoc.data()!;
      final reactions = Map<String, dynamic>.from(
        messageData['reactions'] as Map<String, dynamic>? ?? {},
      );

      // Eliminar reacción
      reactions.remove(currentUserId);

      await messageRef.update({'reactions': reactions});
    } catch (e) {
      // Error silencioso
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

      return true;
    } catch (e) {
      return false;
    }
  }
}
