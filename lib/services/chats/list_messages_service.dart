import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/chat_message.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Listar mensajes de un chat
///
/// Responsabilidad única: Obtener stream/lista paginada de mensajes
///
/// Optimizaciones:
/// - Query con ORDER BY en Firestore (timestamp desc)
/// - Paginación con cursor (startAfterDocument)
/// - Filtro de clearedAt desde cache local
/// - Índice: messages.timestamp (desc)
class ListMessagesService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  ListMessagesService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Stream de mensajes de un chat
  ///
  /// [chatId] - ID del chat
  /// [isGroup] - true si es grupo (usa collection 'groups_v2')
  /// [limit] - Número máximo de mensajes (default: 50)
  /// [startAfter] - Cursor para paginación
  ///
  /// Retorna Stream<List<ChatMessage>> ordenado por timestamp descendente
  Stream<List<ChatMessage>> call({
    required String chatId,
    bool isGroup = false,
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'ListMessages');
      return Stream.value([]);
    }

    // Obtener clearedAt para filtrar mensajes
    final clearedAt = _preferencesCache.getClearedAt(chatId);

    // Collection basada en tipo
    final collection = isGroup ? 'groups_v2' : 'chats';

    // Query base
    Query<Map<String, dynamic>> query = _firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(limit);

    // Filtrar por clearedAt si existe
    if (clearedAt != null) {
      query = query.where(
        'timestamp',
        isGreaterThan: Timestamp.fromDate(clearedAt),
      );
    }

    // Paginación
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return ChatMessage.fromFirestore(doc, currentUserId: userId);
      }).toList();
    });
  }

  /// Obtener página de mensajes (no-stream) para paginación manual
  ///
  /// Útil para cargar mensajes más antiguos (scroll hacia arriba)
  Future<({List<ChatMessage> messages, DocumentSnapshot? lastDoc})> getPage({
    required String chatId,
    bool isGroup = false,
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'ListMessages');
      return (messages: <ChatMessage>[], lastDoc: null);
    }

    try {
      final clearedAt = _preferencesCache.getClearedAt(chatId);
      final collection = isGroup ? 'groups_v2' : 'chats';

      Query<Map<String, dynamic>> query = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(limit);

      if (clearedAt != null) {
        query = query.where(
          'timestamp',
          isGreaterThan: Timestamp.fromDate(clearedAt),
        );
      }

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();

      final messages = snapshot.docs.map((doc) {
        return ChatMessage.fromFirestore(doc, currentUserId: userId);
      }).toList();

      final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;

      return (messages: messages, lastDoc: lastDoc);
    } catch (e) {
      ReleaseLogger.error('Error listando mensajes: $e', tag: 'ListMessages');
      return (messages: <ChatMessage>[], lastDoc: null);
    }
  }

  /// Obtener un mensaje específico por ID
  Future<ChatMessage?> getById({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return null;

    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      final doc = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get();

      if (!doc.exists) return null;

      return ChatMessage.fromFirestore(doc, currentUserId: userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo mensaje: $e', tag: 'ListMessages');
      return null;
    }
  }

  // ✅ REMOVED: countUnread - V2 usa LocalUnreadCountService (cache local)

  /// Stream del último mensaje (para preview en lista de chats)
  Stream<ChatMessage?> watchLastMessage({
    required String chatId,
    bool isGroup = false,
  }) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return Stream.value(null);
    }

    final collection = isGroup ? 'groups_v2' : 'chats';

    return _firestore
        .collection(collection)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .map((snapshot) {
      if (snapshot.docs.isEmpty) return null;
      return ChatMessage.fromFirestore(
        snapshot.docs.first,
        currentUserId: userId,
      );
    });
  }

  /// Buscar mensajes por texto
  Future<List<ChatMessage>> searchByText({
    required String chatId,
    required String query,
    bool isGroup = false,
    int limit = 50,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return [];

    if (query.trim().isEmpty) return [];

    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      // Firestore no soporta búsqueda full-text, así que obtenemos
      // mensajes recientes y filtramos en cliente
      final snapshot = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(200) // Limitar para no traer demasiados
          .get();

      final normalizedQuery = query.toLowerCase();

      return snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: userId))
          .where((msg) {
        final text = msg.text?.toLowerCase() ?? '';
        return text.contains(normalizedQuery);
      }).take(limit).toList();
    } catch (e) {
      ReleaseLogger.error('Error buscando mensajes: $e', tag: 'ListMessages');
      return [];
    }
  }

  /// Obtener mensajes con media (imágenes, videos, audios)
  Future<List<ChatMessage>> getMediaMessages({
    required String chatId,
    bool isGroup = false,
    int limit = 50,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return [];

    try {
      final collection = isGroup ? 'groups_v2' : 'chats';

      // Obtener mensajes y filtrar los que tienen media
      final snapshot = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(200)
          .get();

      return snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: userId))
          .where((msg) => msg.hasMedia)
          .take(limit)
          .toList();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo media: $e', tag: 'ListMessages');
      return [];
    }
  }
}
