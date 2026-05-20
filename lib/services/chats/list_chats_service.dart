import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/chat.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Listar chats del usuario
///
/// Responsabilidad única: Obtener stream/lista paginada de chats
///
/// Optimizaciones para escalar a 10,000+ chats:
/// - Query con ORDER BY en Firestore (NO en memoria)
/// - Paginación con cursor (startAfterDocument)
/// - Filtros locales via ChatPreferencesCache (archived, muted, deleted)
/// - Índice compuesto: participants (array-contains) + lastMessageTime (desc)
class ListChatsService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  ListChatsService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Stream de chats del usuario con filtros locales
  ///
  /// [limit] - Número máximo de chats a obtener (default: 50)
  /// [startAfter] - Cursor para paginación
  /// [includeArchived] - Incluir chats archivados (default: false)
  /// [includeDeleted] - Incluir chats eliminados (default: false)
  ///
  /// Retorna `Stream<List<Chat>>` ordenado por lastActivity descendente
  Stream<List<Chat>> call({
    int limit = 50,
    DocumentSnapshot? startAfter,
    bool includeArchived = false,
    bool includeDeleted = false,
  }) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'ListChats');
      return Stream.value([]);
    }

    // Query con índice existente: participants (array-contains) + lastMessageTime (desc)
    Query<Map<String, dynamic>> query = _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .limit(limit);

    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    return query.snapshots().map((snapshot) {
      // Convertir a modelo Chat
      final chats = snapshot.docs.map(Chat.fromFirestore).toList();

      // Aplicar filtros locales (archived, deleted)
      return _preferencesCache.applyFilters(
        chats: chats,
        getChatId: (chat) => chat.id,
        includeArchived: includeArchived,
        includeDeleted: includeDeleted,
      );
    });
  }

  /// Obtener lista de chats (no-stream) para paginación manual
  ///
  /// Útil para cargar más chats en scroll infinito
  Future<({List<Chat> chats, DocumentSnapshot? lastDoc})> getPage({
    int limit = 50,
    DocumentSnapshot? startAfter,
    bool includeArchived = false,
    bool includeDeleted = false,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'ListChats');
      return (chats: <Chat>[], lastDoc: null);
    }

    try {
      Query<Map<String, dynamic>> query = _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .orderBy('lastMessageTime', descending: true)
          .limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();

      // Convertir a modelo Chat
      final chats = snapshot.docs.map(Chat.fromFirestore).toList();

      // Aplicar filtros locales
      final filteredChats = _preferencesCache.applyFilters(
        chats: chats,
        getChatId: (chat) => chat.id,
        includeArchived: includeArchived,
        includeDeleted: includeDeleted,
      );

      // Retornar chats y último documento para paginación
      final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;

      return (chats: filteredChats, lastDoc: lastDoc);
    } catch (e) {
      ReleaseLogger.error('Error listando chats: $e', tag: 'ListChats');
      return (chats: <Chat>[], lastDoc: null);
    }
  }

  /// Stream de chats archivados
  Stream<List<Chat>> watchArchived({int limit = 50}) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
      final chats = snapshot.docs.map(Chat.fromFirestore).toList();

      // Solo retornar los archivados
      return chats.where((chat) {
        return _preferencesCache.isArchived(chat.id) &&
            !_preferencesCache.isDeleted(chat.id);
      }).toList();
    });
  }

  /// Contar total de chats del usuario
  Future<int> countChats() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return 0;

    try {
      final snapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .count()
          .get();

      return snapshot.count ?? 0;
    } catch (e) {
      ReleaseLogger.error('Error contando chats: $e', tag: 'ListChats');
      return 0;
    }
  }

  /// Contar chats no leídos
  int countUnreadChats() {
    final counts = _preferencesCache.getAllUnreadCounts();
    return counts.values.where((cnt) => cnt > 0).length;
  }

  /// Total de mensajes no leídos
  int getTotalUnreadMessages() {
    return _preferencesCache.getTotalUnreadCount();
  }
}
