import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Eliminar un chat (soft delete) y crear uno nuevo automáticamente
  /// Retorna el ID del nuevo chat creado
  Future<String> deleteChat(String chatId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final chatRef = _firestore.collection('chats').doc(chatId);
      final chatDoc = await chatRef.get();

      if (!chatDoc.exists) {
        throw Exception('Chat no encontrado');
      }

      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);

      if (participants.length != 2) {
        throw Exception('Solo se pueden eliminar chats de 2 participantes');
      }

      // Soft delete del chat actual para AMBOS participantes
      // Esto previene que el otro usuario vea el chat viejo cuando se crea uno nuevo
      await chatRef.set({
        'deletedBy': participants, // Marcar como eliminado para ambos participantes
        'deletedAt_${participants[0]}': FieldValue.serverTimestamp(),
        'deletedAt_${participants[1]}': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('🗑️ Chat marcado como eliminado (soft delete) para ambos participantes: $participants');

      // Crear automáticamente un nuevo chat entre los mismos participantes
      final otherUserId = participants.firstWhere((id) => id != user.uid);
      final newChatId = await createNewChat(user.uid, otherUserId);

      print('✅ Nuevo chat creado automáticamente: $newChatId');

      return newChatId;
    } catch (e) {
      print('❌ Error eliminando chat: $e');
      throw Exception('Error eliminando chat: $e');
    }
  }

  /// Verificar si un chat está eliminado
  /// Si deletedBy no está vacío, el chat está eliminado sin importar quién lo eliminó
  Future<bool> isChatDeleted(String chatId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return true;

      final chatData = chatDoc.data();
      final deletedBy = List<String>.from(chatData?['deletedBy'] ?? []);

      // Si deletedBy no está vacío, el chat está eliminado
      return deletedBy.isNotEmpty;
    } catch (e) {
      print('❌ Error verificando si chat está eliminado: $e');
      return false;
    }
  }

  /// Obtener chats del usuario (excluyendo los eliminados)
  Stream<QuerySnapshot> getUserChatsStream() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(FirebaseFirestore.instance.collection('chats').limit(0).get() as QuerySnapshot);

    return _firestore
        .collection('chats')
        .where('participants', arrayContains: user.uid)
        .orderBy('lastMessageTime', descending: true)
        .snapshots();
  }

  /// Filtrar chats eliminados de un snapshot
  /// Si un chat fue eliminado por CUALQUIER participante, no es visible para NADIE
  List<QueryDocumentSnapshot> filterDeletedChats(QuerySnapshot snapshot) {
    final user = _auth.currentUser;
    if (user == null) return [];

    return snapshot.docs.where((doc) {
      final chatData = doc.data() as Map<String, dynamic>;
      final deletedBy = List<String>.from(chatData['deletedBy'] ?? []);
      // Si deletedBy NO está vacío, significa que el chat fue eliminado
      // y NO debe ser visible para ningún participante
      return deletedBy.isEmpty;
    }).toList();
  }

  /// Filtrar chats eliminados EXCEPTO los chats con usuarios específicos (ej: padres/hijos)
  /// Si un chat fue eliminado, NO es visible para NADIE (sin excepciones)
  List<QueryDocumentSnapshot> filterDeletedChatsExcept(
    QuerySnapshot snapshot,
    List<String> exceptUserIds,
  ) {
    final user = _auth.currentUser;
    if (user == null) return [];

    return snapshot.docs.where((doc) {
      final chatData = doc.data() as Map<String, dynamic>;
      final deletedBy = List<String>.from(chatData['deletedBy'] ?? []);

      // Si deletedBy NO está vacío, significa que el chat fue eliminado
      // y NO debe ser visible para ningún participante (sin excepciones)
      return deletedBy.isEmpty;
    }).toList();
  }

  /// Restaurar un chat eliminado (solo soft delete)
  Future<void> restoreChat(String chatId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final chatRef = _firestore.collection('chats').doc(chatId);

      await chatRef.update({
        'deletedBy': FieldValue.arrayRemove([user.uid]),
        'deletedAt_${user.uid}': FieldValue.delete(),
      });

      print('♻️ Chat restaurado para usuario: ${user.uid}');
    } catch (e) {
      print('❌ Error restaurando chat: $e');
      throw Exception('Error restaurando chat: $e');
    }
  }

  /// Eliminar chat permanentemente (hard delete) - solo para admins o casos especiales
  Future<void> deleteChatPermanently(String chatId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final chatRef = _firestore.collection('chats').doc(chatId);

      // Eliminar todos los mensajes del chat
      final messagesSnapshot = await chatRef.collection('messages').get();
      final batch = _firestore.batch();

      for (var messageDoc in messagesSnapshot.docs) {
        batch.delete(messageDoc.reference);
      }

      // Eliminar el chat
      batch.delete(chatRef);

      await batch.commit();

      print('🗑️ Chat eliminado permanentemente (hard delete): $chatId');
    } catch (e) {
      print('❌ Error eliminando chat permanentemente: $e');
      throw Exception('Error eliminando chat permanentemente: $e');
    }
  }

  /// Generar ID de chat entre dos usuarios (para nuevos chats)
  String getChatId(String userId1, String userId2) {
    final sortedIds = [userId1, userId2]..sort();
    return '${sortedIds[0]}_${sortedIds[1]}';
  }

  /// Generar ID de chat único con timestamp (para chats nuevos después de eliminación)
  String generateNewChatId(String userId1, String userId2) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sortedIds = [userId1, userId2]..sort();
    return '${timestamp}_${sortedIds[0]}_${sortedIds[1]}';
  }

  /// Obtener el chat activo (no eliminado) entre dos usuarios
  /// Si hay múltiples chats, devuelve el más reciente que no esté eliminado
  Future<QueryDocumentSnapshot?> getActiveChatBetweenUsers(
    String userId1,
    String userId2,
  ) async {
    try {
      // Buscar todos los chats donde el usuario1 es participante
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId1)
          .get();

      // Filtrar y encontrar chats válidos
      List<QueryDocumentSnapshot> validChats = [];

      for (var chatDoc in chatsQuery.docs) {
        final chatData = chatDoc.data() as Map<String, dynamic>;
        final participants = List<String>.from(chatData['participants'] ?? []);
        final deletedBy = List<String>.from(chatData['deletedBy'] ?? []);

        // Verificar que ambos usuarios sean participantes
        if (participants.contains(userId1) && participants.contains(userId2)) {
          // Verificar que el chat NO esté eliminado (deletedBy debe estar vacío)
          if (deletedBy.isEmpty) {
            validChats.add(chatDoc);
          }
        }
      }

      if (validChats.isEmpty) {
        return null;
      }

      // Ordenar por createdAt o lastMessageTime (el más reciente primero)
      validChats.sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;

        final aTime = aData['lastMessageTime'] as Timestamp? ?? aData['createdAt'] as Timestamp?;
        final bTime = bData['lastMessageTime'] as Timestamp? ?? bData['createdAt'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      return validChats.first;
    } catch (e) {
      print('❌ Error obteniendo chat activo: $e');
      return null;
    }
  }

  /// Crear un nuevo chat entre dos usuarios
  Future<String> createNewChat(String userId1, String userId2) async {
    final newChatId = generateNewChatId(userId1, userId2);

    await _firestore.collection('chats').doc(newChatId).set({
      'participants': [userId1, userId2],
      'createdAt': FieldValue.serverTimestamp(),
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastMessage': '',
      'lastMessageSender': '',
      'deletedBy': [],
    });

    print('✅ Nuevo chat creado: $newChatId');
    return newChatId;
  }
}
