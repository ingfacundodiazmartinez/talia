import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Servicio para gestionar mensajes favoritos
class FavoriteService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Marca o desmarca un mensaje como favorito
  Future<void> toggleFavorite({
    required String chatId,
    required String messageId,
    required bool isGroupChat,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        throw Exception('Usuario no autenticado');
      }

      final collection = isGroupChat ? 'groups_v2' : 'chats';

      // Referencia en el mensaje (legacy)
      final favoriteRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .collection('favorites')
          .doc(currentUserId);

      // ✅ NEW: Referencia en el usuario para consultas eficientes
      final userFavoriteRef = _firestore
          .collection('users')
          .doc(currentUserId)
          .collection('favorites')
          .doc('${chatId}_$messageId');

      final favoriteDoc = await favoriteRef.get();

      if (favoriteDoc.exists) {
        // Ya está marcado como favorito, desmarcarlo
        await Future.wait([
          favoriteRef.delete(),
          userFavoriteRef.delete(),  // ✅ NEW: También borrar del índice del usuario
        ]);
      } else {
        // No está marcado, agregarlo
        await Future.wait([
          favoriteRef.set({
            'userId': currentUserId,
            'timestamp': FieldValue.serverTimestamp(),
          }),
          // ✅ NEW: También guardar en el índice del usuario
          userFavoriteRef.set({
            'chatId': chatId,
            'messageId': messageId,
            'isGroupChat': isGroupChat,
            'timestamp': FieldValue.serverTimestamp(),
          }),
        ]);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Verifica si un mensaje está marcado como favorito por el usuario actual
  Future<bool> isFavorite({
    required String chatId,
    required String messageId,
    required bool isGroupChat,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return false;

      final collection = isGroupChat ? 'groups_v2' : 'chats';
      final favoriteDoc = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .collection('favorites')
          .doc(currentUserId)
          .get();

      return favoriteDoc.exists;
    } catch (e) {
      return false;
    }
  }

  /// Obtiene todos los mensajes favoritos de un chat específico como Stream de List
  Stream<List<Map<String, dynamic>>> getFavoriteMessagesStream({
    required String chatId,
    required bool isGroupChat,
  }) {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    final collection = isGroupChat ? 'groups_v2' : 'chats';

    // Query para obtener mensajes que tienen el usuario actual en la subcolección de favoritos
    return _firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .asyncMap((snapshot) async {
      // Filtrar solo los mensajes que están marcados como favoritos por el usuario actual
      final favoriteMessages = <Map<String, dynamic>>[];

      for (final doc in snapshot.docs) {
        final isFav = await isFavorite(
          chatId: chatId,
          messageId: doc.id,
          isGroupChat: isGroupChat,
        );
        if (isFav) {
          final messageData = doc.data();
          messageData['id'] = doc.id;
          favoriteMessages.add(messageData);
        }
      }

      return favoriteMessages;
    });
  }

  /// Obtiene todos los mensajes favoritos de un chat específico (deprecated - usar getFavoriteMessagesStream)
  @Deprecated('Use getFavoriteMessagesStream instead')
  Stream<QuerySnapshot> getFavoriteMessages({
    required String chatId,
    required bool isGroupChat,
  }) {
    // Mantener por compatibilidad temporalmente, pero dirigir al nuevo método
    return Stream.empty();
  }

  /// ✅ NEW: Obtiene solo los IDs de mensajes favoritos (eficiente para UI)
  /// Retorna un Stream de Set<String> con los IDs de mensajes favoritos
  Stream<Set<String>> getFavoriteMessageIdsStream({
    required String chatId,
    required bool isGroupChat,
  }) {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return Stream.value({});
    }

    // Buscar en el índice de favoritos del usuario
    return _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('favorites')
        .where('chatId', isEqualTo: chatId)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => doc['messageId'] as String).toSet();
    });
  }

  /// ✅ NEW: Obtiene los IDs de mensajes favoritos una vez (Future)
  Future<Set<String>> getFavoriteMessageIds({
    required String chatId,
    required bool isGroupChat,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return {};

    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(currentUserId)
          .collection('favorites')
          .where('chatId', isEqualTo: chatId)
          .get();

      return snapshot.docs.map((doc) => doc['messageId'] as String).toSet();
    } catch (e) {
      return {};
    }
  }

  /// Obtiene mensajes favoritos para mostrar en el perfil público
  /// ✅ UPDATED: Ahora soporta grupos con el parámetro isGroupChat
  Future<List<Map<String, dynamic>>> getFavoriteMessagesForProfile({
    required String chatId,
    bool isGroupChat = false,  // ✅ NEW
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return [];

      final collection = isGroupChat ? 'groups_v2' : 'chats';

      // Obtener todos los mensajes del chat
      final messagesSnapshot = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .get();

      // Filtrar los que están marcados como favoritos
      final favoriteMessages = <Map<String, dynamic>>[];

      for (final messageDoc in messagesSnapshot.docs) {
        final favoriteDoc = await _firestore
            .collection(collection)
            .doc(chatId)
            .collection('messages')
            .doc(messageDoc.id)
            .collection('favorites')
            .doc(currentUserId)
            .get();

        if (favoriteDoc.exists) {
          final messageData = messageDoc.data();
          messageData['id'] = messageDoc.id;
          favoriteMessages.add(messageData);
        }
      }

      return favoriteMessages;
    } catch (e) {
      return [];
    }
  }
}
