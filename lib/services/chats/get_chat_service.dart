import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/chat.dart';
import '../../utils/release_logger.dart';
import '../../utils/chat_utils.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Obtener chat individual
///
/// Responsabilidad única: Obtener un chat específico por ID o participantes
class GetChatService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  GetChatService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Obtener chat por ID
  ///
  /// Retorna el chat si existe y el usuario es participante, null si no
  Future<Chat?> call(String chatId) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'GetChat');
      return null;
    }

    try {
      final doc = await _firestore.collection('chats').doc(chatId).get();

      if (!doc.exists) {
        ReleaseLogger.log('Chat no encontrado: $chatId', tag: 'GetChat');
        return null;
      }

      final chat = Chat.fromFirestore(doc);

      // Verificar que el usuario es participante
      if (!chat.hasParticipant(userId)) {
        ReleaseLogger.error(
          'Usuario no es participante del chat: $chatId',
          tag: 'GetChat',
        );
        return null;
      }

      return chat;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo chat: $e', tag: 'GetChat');
      return null;
    }
  }

  /// Stream de un chat específico
  ///
  /// Útil para escuchar cambios en tiempo real
  Stream<Chat?> watch(String chatId) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return Stream.value(null);
    }

    return _firestore.collection('chats').doc(chatId).snapshots().map((doc) {
      if (!doc.exists) return null;

      final chat = Chat.fromFirestore(doc);

      // Verificar participación
      if (!chat.hasParticipant(userId)) return null;

      return chat;
    });
  }

  /// Buscar chat individual entre dos usuarios
  ///
  /// Retorna el chat existente o null si no existe
  Future<Chat?> findBetweenUsers(String otherUserId) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'GetChat');
      return null;
    }

    try {
      // Buscar chats individuales donde participa el usuario actual
      final query = await _firestore
          .collection('chats')
          .where('type', isEqualTo: 'individual')
          .where('participants', arrayContains: userId)
          .get();

      // Buscar el chat que también incluye al otro usuario
      for (final doc in query.docs) {
        final chat = Chat.fromFirestore(doc);
        if (chat.participants.contains(otherUserId) &&
            chat.participants.length == 2) {
          return chat;
        }
      }

      return null;
    } catch (e) {
      ReleaseLogger.error(
        'Error buscando chat entre usuarios: $e',
        tag: 'GetChat',
      );
      return null;
    }
  }

  /// Obtener o generar ID de chat entre dos usuarios
  ///
  /// Útil cuando necesitas el ID sin crear el chat
  String getChatIdBetweenUsers(String otherUserId) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return '';
    return ChatUtils.getChatId(userId, otherUserId);
  }

  /// Obtener chat con preferencias locales
  ///
  /// Retorna el chat junto con sus preferencias de cache local
  Future<({Chat? chat, ChatPreferences? preferences})> getWithPreferences(
    String chatId,
  ) async {
    final chat = await call(chatId);
    if (chat == null) {
      return (chat: null, preferences: null);
    }

    final preferences = _preferencesCache.getPreferencesFor(chatId);
    return (chat: chat, preferences: preferences);
  }

  /// Verificar si existe un chat entre dos usuarios
  Future<bool> existsBetweenUsers(String otherUserId) async {
    final chat = await findBetweenUsers(otherUserId);
    return chat != null;
  }

  /// Verificar si el usuario actual es participante de un chat
  Future<bool> isParticipant(String chatId) async {
    final chat = await call(chatId);
    return chat != null;
  }
}
