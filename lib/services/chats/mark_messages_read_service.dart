import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Marcar mensajes como leídos
///
/// Responsabilidad única: Actualizar estado de lectura de mensajes
///
/// Actualiza:
/// 1. readBy en cada mensaje no leído (Firestore)
/// 2. unreadCount en cache local (Hive)
///
/// El readBy se guarda en Firestore porque es compartido entre usuarios
/// (el otro usuario necesita ver que su mensaje fue leído).
class MarkMessagesReadService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  MarkMessagesReadService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Marcar todos los mensajes de un chat como leídos
  ///
  /// [chatId] - ID del chat
  /// [isGroup] - true si es grupo
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String chatId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';

      // Obtener mensajes no leídos por el usuario actual
      final unreadMessages = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .where('senderId', isNotEqualTo: userId)
          .get();

      // Filtrar los que el usuario no ha leído
      final messagesToUpdate = <DocumentSnapshot>[];
      for (final doc in unreadMessages.docs) {
        final readBy = List<String>.from(doc.data()['readBy'] ?? []);
        if (!readBy.contains(userId)) {
          messagesToUpdate.add(doc);
        }
      }

      if (messagesToUpdate.isEmpty) {
        // Actualizar cache local de todos modos
        await _preferencesCache.markAsRead(chatId);
        return (success: true, message: 'No hay mensajes sin leer');
      }

      // Actualizar en batches (Firestore limit: 500 operaciones)
      final batches = <WriteBatch>[];
      var currentBatch = _firestore.batch();
      var operationCount = 0;

      for (final doc in messagesToUpdate) {
        currentBatch.update(doc.reference, {
          'readBy': FieldValue.arrayUnion([userId]),
          'isRead': true,
        });
        operationCount++;

        if (operationCount >= 450) {
          batches.add(currentBatch);
          currentBatch = _firestore.batch();
          operationCount = 0;
        }
      }

      if (operationCount > 0) {
        batches.add(currentBatch);
      }

      // Ejecutar todos los batches
      for (final batch in batches) {
        await batch.commit();
      }

      // Actualizar cache local
      await _preferencesCache.markAsRead(chatId);

      ReleaseLogger.log(
        'Mensajes marcados como leídos: ${messagesToUpdate.length} en $chatId',
        tag: 'MarkRead',
      );

      return (
        success: true,
        message: '${messagesToUpdate.length} mensajes marcados como leídos',
      );
    } catch (e) {
      ReleaseLogger.error('Error marcando como leídos: $e', tag: 'MarkRead');
      return (success: false, message: 'Error al marcar como leídos');
    }
  }

  /// Marcar un mensaje específico como leído
  Future<({bool success, String message})> markOne({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'readBy': FieldValue.arrayUnion([userId]),
        'isRead': true,
      });

      ReleaseLogger.log(
        'Mensaje marcado como leído: $messageId',
        tag: 'MarkRead',
      );

      return (success: true, message: 'Mensaje marcado como leído');
    } catch (e) {
      ReleaseLogger.error('Error marcando mensaje: $e', tag: 'MarkRead');
      return (success: false, message: 'Error al marcar mensaje');
    }
  }

  /// Verificar si hay mensajes no leídos en un chat
  Future<bool> hasUnread({
    required String chatId,
    bool isGroup = false,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return false;

    // Primero verificar cache local
    if (_preferencesCache.getUnreadCount(chatId) > 0) {
      return true;
    }

    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      // Verificar en Firestore
      final snapshot = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .where('senderId', isNotEqualTo: userId)
          .limit(50)
          .get();

      for (final doc in snapshot.docs) {
        final readBy = List<String>.from(doc.data()['readBy'] ?? []);
        if (!readBy.contains(userId)) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Obtener conteo de mensajes no leídos
  int getUnreadCount(String chatId) {
    return _preferencesCache.getUnreadCount(chatId);
  }

  /// Obtener total de mensajes no leídos
  int getTotalUnreadCount() {
    return _preferencesCache.getTotalUnreadCount();
  }

  /// Incrementar contador de no leídos (llamado cuando llega mensaje nuevo)
  Future<void> incrementUnread(String chatId, {int by = 1}) async {
    await _preferencesCache.incrementUnreadCount(chatId, by: by);
  }
}
