import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/chat_message.dart';

/// Repository especializado para operaciones de mensajes en Firestore
///
/// Responsabilidades:
/// - SOLO acceso a datos de mensajes (Firestore)
/// - Queries optimizadas para mensajería
/// - NO lógica de negocio
/// - Manejo de errores de red/Firestore
class MessageRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  MessageRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) : _firestore = firestore,
       _auth = auth;

  String? get currentUserId => _auth.currentUser?.uid;

  /// Stream de mensajes de un chat
  Stream<QuerySnapshot> watchMessages({
    required String chatId,
    bool isGroup = false,
    int limit = 50,
  }) {
    final collection = isGroup ? 'groups' : 'chats';

    return _firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)  // ✅ FIX: Use 'timestamp' to match model and Firestore indexes
        .limit(limit)
        .snapshots();
  }

  /// Crear mensaje optimista
  Future<String> createOptimisticMessage({
    required String chatId,
    required ChatMessage message,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      final docRef = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .add(message.toMap());

      return docRef.id;
    } catch (e) {
      throw Exception('Error creando mensaje optimista: $e');
    }
  }

  /// Actualizar mensaje (ej: URL de media después de upload)
  Future<void> updateMessage({
    required String chatId,
    required String messageId,
    required Map<String, dynamic> updates,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update(updates);
    } catch (e) {
      throw Exception('Error actualizando mensaje: $e');
    }
  }

  /// Eliminar mensaje
  Future<void> deleteMessage({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .delete();
    } catch (e) {
      throw Exception('Error eliminando mensaje: $e');
    }
  }

  /// Obtener mensaje por ID
  Future<DocumentSnapshot?> getMessageById({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      final doc = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get();

      return doc.exists ? doc : null;
    } catch (e) {
      throw Exception('Error obteniendo mensaje: $e');
    }
  }

  /// Buscar mensajes por contenido
  Future<QuerySnapshot> searchMessages({
    required String chatId,
    required String query,
    bool isGroup = false,
    int limit = 50,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      // Búsqueda simple por contenido de texto
      return await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .where('type', isEqualTo: 'text')
          .where('content', isGreaterThanOrEqualTo: query)
          .where('content', isLessThan: '$query\uf8ff')
          .orderBy('content')
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
    } catch (e) {
      throw Exception('Error buscando mensajes: $e');
    }
  }

  /// Cargar mensajes anteriores (paginación)
  Future<QuerySnapshot> loadMoreMessages({
    required String chatId,
    required DocumentSnapshot lastDocument,
    bool isGroup = false,
    int limit = 20,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      return await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .startAfterDocument(lastDocument)
          .limit(limit)
          .get();
    } catch (e) {
      throw Exception('Error cargando más mensajes: $e');
    }
  }

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead({
    required String chatId,
    required List<String> messageIds,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      final collection = isGroup ? 'groups' : 'chats';
      final batch = _firestore.batch();

      for (final messageId in messageIds) {
        final messageRef = _firestore
            .collection(collection)
            .doc(chatId)
            .collection('messages')
            .doc(messageId);

        batch.update(messageRef, {
          'readBy': FieldValue.arrayUnion([currentUserId]),
          'readAt.$currentUserId': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
    } catch (e) {
      throw Exception('Error marcando mensajes como leídos: $e');
    }
  }

  /// Marcar mensajes como entregados
  Future<void> markMessagesAsDelivered({
    required String chatId,
    required List<String> messageIds,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      final collection = isGroup ? 'groups' : 'chats';
      final batch = _firestore.batch();

      for (final messageId in messageIds) {
        final messageRef = _firestore
            .collection(collection)
            .doc(chatId)
            .collection('messages')
            .doc(messageId);

        batch.update(messageRef, {
          'deliveredTo': FieldValue.arrayUnion([currentUserId]),
          'deliveredAt.$currentUserId': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
    } catch (e) {
      throw Exception('Error marcando mensajes como entregados: $e');
    }
  }

  /// Obtener mensajes no leídos
  Future<QuerySnapshot> getUnreadMessages({
    required String chatId,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      final collection = isGroup ? 'groups' : 'chats';

      return await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .where('senderId', isNotEqualTo: currentUserId)
          .where('readBy', whereNotIn: [currentUserId])
          .orderBy('senderId')
          .orderBy('createdAt', descending: true)
          .get();
    } catch (e) {
      throw Exception('Error obteniendo mensajes no leídos: $e');
    }
  }

  /// Reaccionar a mensaje
  Future<void> addReaction({
    required String chatId,
    required String messageId,
    required String reaction,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      final collection = isGroup ? 'groups' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'reactions.$reaction': FieldValue.arrayUnion([currentUserId]),
      });
    } catch (e) {
      throw Exception('Error añadiendo reacción: $e');
    }
  }

  /// Quitar reacción de mensaje
  Future<void> removeReaction({
    required String chatId,
    required String messageId,
    required String reaction,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      final collection = isGroup ? 'groups' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'reactions.$reaction': FieldValue.arrayRemove([currentUserId]),
      });
    } catch (e) {
      throw Exception('Error quitando reacción: $e');
    }
  }
}