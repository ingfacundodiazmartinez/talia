import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/chat.dart';
import '../../utils/release_logger.dart';
import 'chat_preferences_cache.dart';

/// Servicio atómico: Buscar chats
///
/// Responsabilidad única: Buscar chats por nombre o contenido
///
/// Nota: La búsqueda por contenido de mensajes requiere Algolia o similar
/// para escalar. Por ahora, se busca por nombre de grupo y se filtran
/// chats individuales en el cliente.
class SearchChatsService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ChatPreferencesCache _preferencesCache;

  SearchChatsService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ChatPreferencesCache? preferencesCache,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  /// Buscar chats por query
  ///
  /// Para grupos: Busca por nombre del grupo (prefix match)
  /// Para individuales: Debe resolverse en el cliente con datos de usuarios
  ///
  /// [query] - Texto a buscar
  /// [limit] - Número máximo de resultados (default: 20)
  /// [includeArchived] - Incluir chats archivados (default: true para búsqueda)
  Future<List<Chat>> call({
    required String query,
    int limit = 20,
    bool includeArchived = true,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado', tag: 'SearchChats');
      return [];
    }

    if (query.trim().isEmpty) {
      return [];
    }

    final normalizedQuery = query.trim().toLowerCase();

    try {
      // Buscar grupos por nombre (prefix match)
      final groupResults = await _searchGroups(
        userId: userId,
        query: normalizedQuery,
        limit: limit,
      );

      // Obtener chats individuales del usuario para filtrar en cliente
      final individualResults = await _searchIndividualChats(
        userId: userId,
        limit: limit,
      );

      // Combinar resultados
      final allResults = [...groupResults, ...individualResults];

      // Aplicar filtros locales
      final filteredResults = _preferencesCache.applyFilters(
        chats: allResults,
        getChatId: (chat) => chat.id,
        includeArchived: includeArchived,
        includeDeleted: false,
      );

      // Limitar resultados totales
      return filteredResults.take(limit).toList();
    } catch (e) {
      ReleaseLogger.error('Error buscando chats: $e', tag: 'SearchChats');
      return [];
    }
  }

  /// Buscar grupos por nombre
  Future<List<Chat>> _searchGroups({
    required String userId,
    required String query,
    required int limit,
  }) async {
    try {
      // Firestore prefix search usando >= y < con \uf8ff
      final snapshot = await _firestore
          .collection('chats')
          .where('type', isEqualTo: 'group')
          .where('participants', arrayContains: userId)
          .where('name', isGreaterThanOrEqualTo: query)
          .where('name', isLessThan: '$query\uf8ff')
          .limit(limit)
          .get();

      return snapshot.docs.map(Chat.fromFirestore).toList();
    } catch (e) {
      // Si falla la búsqueda por nombre (ej. índice faltante), retornar vacío
      ReleaseLogger.log(
        'Búsqueda de grupos por nombre no disponible: $e',
        tag: 'SearchChats',
      );
      return [];
    }
  }

  /// Obtener chats individuales para filtrar en cliente
  ///
  /// Nota: Los chats individuales no tienen campo 'name', el nombre
  /// viene del otro participante. La búsqueda por nombre de contacto
  /// debe hacerse en el cliente con los datos de usuarios cacheados.
  Future<List<Chat>> _searchIndividualChats({
    required String userId,
    required int limit,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('chats')
          .where('type', isEqualTo: 'individual')
          .where('participants', arrayContains: userId)
          .orderBy('lastActivity', descending: true)
          .limit(limit)
          .get();

      return snapshot.docs.map(Chat.fromFirestore).toList();
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo chats individuales: $e',
        tag: 'SearchChats',
      );
      return [];
    }
  }

  /// Buscar chats por último mensaje (contenido)
  ///
  /// Nota: Esto es una búsqueda simple que solo busca en lastMessage.
  /// Para búsqueda completa de contenido de mensajes, se necesita
  /// un servicio de búsqueda externo como Algolia.
  Future<List<Chat>> searchByLastMessage({
    required String query,
    int limit = 20,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return [];

    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return [];

    try {
      // Obtener todos los chats del usuario y filtrar en cliente
      // Esto no escala bien, pero es la única opción sin Algolia
      final snapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .orderBy('lastActivity', descending: true)
          .limit(100) // Limitar para no traer demasiados
          .get();

      final chats = snapshot.docs.map(Chat.fromFirestore).toList();

      // Filtrar por contenido de lastMessage
      final matches = chats.where((chat) {
        final lastMessage = chat.lastMessage?.toLowerCase() ?? '';
        return lastMessage.contains(normalizedQuery);
      }).toList();

      // Aplicar filtros locales y limitar
      return _preferencesCache
          .applyFilters(
            chats: matches,
            getChatId: (chat) => chat.id,
            includeArchived: true,
            includeDeleted: false,
          )
          .take(limit)
          .toList();
    } catch (e) {
      ReleaseLogger.error(
        'Error buscando por último mensaje: $e',
        tag: 'SearchChats',
      );
      return [];
    }
  }

  /// Buscar chats recientes (últimos N días)
  Future<List<Chat>> searchRecent({
    int daysBack = 7,
    int limit = 50,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return [];

    try {
      final cutoffDate = DateTime.now().subtract(Duration(days: daysBack));

      final snapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .where('lastActivity', isGreaterThan: Timestamp.fromDate(cutoffDate))
          .orderBy('lastActivity', descending: true)
          .limit(limit)
          .get();

      final chats = snapshot.docs.map(Chat.fromFirestore).toList();

      return _preferencesCache.applyFilters(
        chats: chats,
        getChatId: (chat) => chat.id,
        includeArchived: false,
        includeDeleted: false,
      );
    } catch (e) {
      ReleaseLogger.error('Error buscando chats recientes: $e', tag: 'SearchChats');
      return [];
    }
  }
}
