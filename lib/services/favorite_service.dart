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

      final collection = isGroupChat ? 'groups' : 'chats';
      final favoriteRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .collection('favorites')
          .doc(currentUserId);

      final favoriteDoc = await favoriteRef.get();

      if (favoriteDoc.exists) {
        // Ya está marcado como favorito, desmarcarlo
        await favoriteRef.delete();
        print('⭐ Favorito eliminado: $messageId');
      } else {
        // No está marcado, agregarlo
        await favoriteRef.set({
          'userId': currentUserId,
          'timestamp': FieldValue.serverTimestamp(),
        });
        print('⭐ Favorito agregado: $messageId');
      }
    } catch (e) {
      print('❌ Error al cambiar favorito: $e');
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

      final collection = isGroupChat ? 'groups' : 'chats';
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
      print('❌ Error verificando favorito: $e');
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

    final collection = isGroupChat ? 'groups' : 'chats';

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

      print('📋 [Favorites] Encontrados ${favoriteMessages.length} mensajes favoritos');
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

  /// Obtiene mensajes favoritos para mostrar en el perfil público
  Future<List<Map<String, dynamic>>> getFavoriteMessagesForProfile({
    required String chatId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return [];

      // Obtener todos los mensajes del chat
      final messagesSnapshot = await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .get();

      // Filtrar los que están marcados como favoritos
      final favoriteMessages = <Map<String, dynamic>>[];

      for (final messageDoc in messagesSnapshot.docs) {
        final favoriteDoc = await _firestore
            .collection('chats')
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
      print('❌ Error obteniendo mensajes favoritos: $e');
      return [];
    }
  }
}
