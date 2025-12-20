import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/chat.dart';
import '../../utils/release_logger.dart';
import '../../utils/chat_utils.dart';

/// Servicio atómico: Crear chat individual
///
/// Responsabilidad única: Crear un nuevo chat 1-a-1 entre dos usuarios
///
/// Nota: Este servicio NO crea grupos. Para grupos usar CreateGroupService.
class CreateChatService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CreateChatService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Crear o obtener chat existente entre dos usuarios
  ///
  /// Si ya existe un chat entre los usuarios, retorna el existente.
  /// Si no existe, crea uno nuevo.
  ///
  /// [otherUserId] - ID del otro usuario
  ///
  /// Retorna (success, chatId, message, isNew)
  Future<({bool success, String? chatId, String message, bool isNew})> call({
    required String otherUserId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return (
          success: false,
          chatId: null,
          message: 'Usuario no autenticado',
          isNew: false,
        );
      }

      // No puede chatear consigo mismo
      if (currentUserId == otherUserId) {
        return (
          success: false,
          chatId: null,
          message: 'No puedes crear un chat contigo mismo',
          isNew: false,
        );
      }

      // Buscar chat existente
      final existingChat = await _findExistingChat(currentUserId, otherUserId);
      if (existingChat != null) {
        ReleaseLogger.log(
          'Chat existente encontrado: ${existingChat.id}',
          tag: 'CreateChat',
        );
        return (
          success: true,
          chatId: existingChat.id,
          message: 'Chat existente',
          isNew: false,
        );
      }

      // Crear nuevo chat
      final chatId = await _createNewChat(currentUserId, otherUserId);

      ReleaseLogger.log('Chat creado: $chatId', tag: 'CreateChat');

      return (
        success: true,
        chatId: chatId,
        message: 'Chat creado exitosamente',
        isNew: true,
      );
    } catch (e) {
      ReleaseLogger.error('Error creando chat: $e', tag: 'CreateChat');
      return (
        success: false,
        chatId: null,
        message: 'Error al crear chat: $e',
        isNew: false,
      );
    }
  }

  /// Buscar chat existente entre dos usuarios
  Future<Chat?> _findExistingChat(
    String userId1,
    String userId2,
  ) async {
    final query = await _firestore
        .collection('chats')
        .where('type', isEqualTo: 'individual')
        .where('participants', arrayContains: userId1)
        .get();

    for (final doc in query.docs) {
      final chat = Chat.fromFirestore(doc);
      if (chat.participants.contains(userId2) &&
          chat.participants.length == 2) {
        return chat;
      }
    }
    return null;
  }

  /// Crear nuevo chat individual
  Future<String> _createNewChat(
    String currentUserId,
    String otherUserId,
  ) async {
    final participants = [currentUserId, otherUserId]..sort();

    final chatData = {
      'type': 'individual',
      'participants': participants,
      'createdAt': FieldValue.serverTimestamp(),
      'lastActivity': FieldValue.serverTimestamp(),
      'lastMessage': null,
      'lastMessageTime': null,
      'lastMessageSenderId': null,
    };

    final docRef = await _firestore.collection('chats').add(chatData);
    return docRef.id;
  }

  /// Obtener ID de chat entre dos usuarios (sin crear)
  ///
  /// Útil para verificar si existe o para navigation
  String getChatIdBetweenUsers(String otherUserId) {
    final currentUserId = _auth.currentUser?.uid ?? '';
    return ChatUtils.getChatId(currentUserId, otherUserId);
  }

  /// Verificar si existe chat entre dos usuarios
  Future<bool> existsBetweenUsers(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return false;

    final existing = await _findExistingChat(currentUserId, otherUserId);
    return existing != null;
  }
}
