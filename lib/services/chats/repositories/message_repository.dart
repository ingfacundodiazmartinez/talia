import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/chat_message.dart';
import '../../../utils/release_logger.dart';

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
  ///
  /// ✅ FIX: Filtrar mensajes anteriores a clearedAt si está configurado
  Stream<QuerySnapshot> watchMessages({
    required String chatId,
    bool isGroup = false,
    int limit = 50,
    Timestamp? clearedAt, // ✅ NEW: Timestamp desde cuando el usuario limpió el chat
  }) {
    // ✅ FIX: Usar groups_v2 para grupos (no 'groups' legacy)
    final collection = isGroup ? 'groups_v2' : 'chats';

    var query = _firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)  // ✅ FIX: Use 'timestamp' to match model and Firestore indexes
        .limit(limit);

    // ✅ FIX: Si hay clearedAt, solo mostrar mensajes posteriores
    if (clearedAt != null) {
      query = query.where('timestamp', isGreaterThan: clearedAt) as Query<Map<String, dynamic>>;
    }

    return query.snapshots();
  }

  /// Crear mensaje optimista
  /// ✅ FIX: Actualiza también el chat document con lastMessage, lastMessageId, etc.
  Future<String> createOptimisticMessage({
    required String chatId,
    required ChatMessage message,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      // ✅ FIX: Verificar si el chat document existe antes de intentar actualizarlo
      // Solo Cloud Functions pueden crear chats, así que si no existe, solo creamos el mensaje
      final chatRef = _firestore.collection(collection).doc(chatId);
      final chatDoc = await chatRef.get();
      final chatExists = chatDoc.exists;

      // ✅ Usar batch write para operación atómica
      final batch = _firestore.batch();

      // 1. Crear mensaje en subcollection
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(); // Genera ID automáticamente

      final messageId = messageRef.id;

      // ✅ FIX: Usar serverTimestamp para ordenamiento correcto
      // El timestamp local se ignora y el servidor genera el timestamp real
      final messageData = message.toMap();
      messageData['timestamp'] = FieldValue.serverTimestamp();

      batch.set(messageRef, messageData);

      // 2. Actualizar chat document con metadata del mensaje
      // ✅ FIX: Solo actualizar si el documento existe (para evitar permission-denied en create)
      if (chatExists) {
        // Extraer texto preview (máximo 100 caracteres)
        // ✅ FIX: Usar type como criterio principal para media, URL como fallback
        String messagePreview = '';
        final messageType = message.type ?? 'text';

        if (message.text != null && message.text!.isNotEmpty) {
          messagePreview = message.text!.length > 100
              ? '${message.text!.substring(0, 97)}...'
              : message.text!;
        } else if (messageType == 'image' || message.imageUrl != null) {
          messagePreview = '📷 Imagen';
        } else if (messageType == 'video' || message.videoUrl != null) {
          messagePreview = '🎥 Video';
        } else if (messageType == 'audio' || message.audioUrl != null) {
          messagePreview = '🎤 Audio';
        } else if (messageType == 'missed_call') {
          // ✅ FIX: Manejar llamadas perdidas
          final isVideo = message.callType == 'video';
          messagePreview = isVideo ? '📹 Videollamada perdida' : '📞 Llamada perdida';
        } else if (messageType == 'answered_call') {
          // ✅ FIX: Manejar llamadas contestadas
          final isVideo = message.callType == 'video';
          messagePreview = isVideo ? '📹 Videollamada' : '📞 Llamada';
        }

        final chatUpdateData = {
          'lastMessage': messagePreview,
          'lastMessageType': messageType, // ✅ NEW: Guardar tipo para notificaciones
          'lastMessageAt': FieldValue.serverTimestamp(), // ✅ FIX: Usar serverTimestamp
          'lastMessageTime': FieldValue.serverTimestamp(), // ✅ FIX: Usar serverTimestamp
          'lastMessageSender': currentUserId,
          'lastMessageId': messageId, // ✅ CRÍTICO: Para anti-duplicados Stream Detector vs FCM
          'updatedAt': FieldValue.serverTimestamp(), // ✅ FIX: Usar serverTimestamp
        };

        batch.update(chatRef, chatUpdateData);
      }

      // 3. Commit batch (atómico)
      await batch.commit();

      if (!chatExists) {
        ReleaseLogger.warning('Chat document no existía - mensaje creado sin actualizar metadata', tag: 'MessageRepository');
      }

      ReleaseLogger.log('✅ Mensaje creado${chatExists ? " Y chat actualizado" : ""} con ID: $messageId', tag: 'MessageRepository');

      return messageId;
    } catch (e) {
      ReleaseLogger.error('Error creando mensaje optimista: $e', tag: 'MessageRepository');
      throw Exception('Error creando mensaje optimista: $e');
    }
  }

  /// Crear mensaje con ID específico
  ///
  /// Usado para crear mensajes aprobados después de moderación
  Future<void> createMessageWithId({
    required String chatId,
    required String messageId,
    required Map<String, dynamic> data,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .set(data);
    } catch (e) {
      throw Exception('Error creando mensaje con ID: $e');
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
      final collection = isGroup ? 'groups_v2' : 'chats';

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
      final collection = isGroup ? 'groups_v2' : 'chats';

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
      final collection = isGroup ? 'groups_v2' : 'chats';

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
      final collection = isGroup ? 'groups_v2' : 'chats';

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
      final collection = isGroup ? 'groups_v2' : 'chats';

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

      final collection = isGroup ? 'groups_v2' : 'chats';
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

      final collection = isGroup ? 'groups_v2' : 'chats';
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
  /// ✅ FIX: Query simplificada + filtrado en cliente (Firestore no soporta whereNotIn con arrays)
  Future<List<String>> getUnreadMessageIds({
    required String chatId,
    bool isGroup = false,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      final collection = isGroup ? 'groups_v2' : 'chats';

      // Obtener últimos 100 mensajes (optimización: no cargar todos)
      final snapshot = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();

      // Filtrar en cliente: mensajes de otros usuarios que no me incluyen en readBy
      final unreadIds = <String>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final senderId = data['senderId'] as String?;
        final readBy = List<String>.from(data['readBy'] ?? []);

        // Solo mensajes de otros usuarios que no he leído
        if (senderId != null &&
            senderId != currentUserId &&
            !readBy.contains(currentUserId)) {
          unreadIds.add(doc.id);
        }
      }

      return unreadIds;
    } catch (e) {
      throw Exception('Error obteniendo mensajes no leídos: $e');
    }
  }

  /// @deprecated Usar getUnreadMessageIds en su lugar
  Future<QuerySnapshot> getUnreadMessages({
    required String chatId,
    bool isGroup = false,
  }) async {
    // Mantener por compatibilidad pero redirigir internamente
    final collection = isGroup ? 'groups_v2' : 'chats';
    return await _firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .limit(0) // Retornar vacío, usar getUnreadMessageIds
        .get();
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

      final collection = isGroup ? 'groups_v2' : 'chats';

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

      final collection = isGroup ? 'groups_v2' : 'chats';

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