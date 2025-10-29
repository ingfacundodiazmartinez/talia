import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/chat_message.dart';
import '../message_cache_service.dart';

/// Servicio para paginación y carga de mensajes
///
/// Responsabilidades:
/// - Cargar mensajes iniciales desde cache
/// - Cargar mensajes desde Firestore
/// - Paginación de mensajes (lazy loading)
/// - Filtrado por clearedAt timestamp
/// - Gestión de cache local
class MessagePaginationService {
  final FirebaseFirestore _firestore;
  final MessageCacheService _cacheService;

  static const int _messagesPerPage = 50;

  // Estado de paginación
  DocumentSnapshot? _lastDocument;
  bool _hasMoreMessages = true;
  Timestamp? _clearedAtTimestamp;

  MessagePaginationService({
    FirebaseFirestore? firestore,
    MessageCacheService? cacheService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _cacheService = cacheService ?? MessageCacheService();

  bool get hasMoreMessages => _hasMoreMessages;

  /// Cargar mensajes del cache (instantáneo)
  Future<List<ChatMessage>> loadMessagesFromCache({
    required String chatId,
  }) async {
    try {
      print('📦 Cargando mensajes desde cache...');
      final cachedMessages = await _cacheService.getMessages(chatId);

      if (cachedMessages.isNotEmpty) {
        print('📥 Cache: ${cachedMessages.length} mensajes');
        return cachedMessages;
      } else {
        print('📥 Cache vacío');
        return [];
      }
    } catch (e) {
      print('❌ Error cargando cache: $e');
      return [];
    }
  }

  /// Cargar mensajes iniciales de Firestore
  Future<List<ChatMessage>> loadInitialMessages({
    required String chatId,
    required String currentUserId,
  }) async {
    try {
      // Obtener el timestamp de cuándo se limpió el chat
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();

      if (!chatDoc.exists) {
        print('💬 Chat vacío (documento no existe), iniciando sin mensajes');
        _hasMoreMessages = false;
        return [];
      }

      final chatData = chatDoc.data();
      _clearedAtTimestamp = chatData?['clearedAt_$currentUserId'] as Timestamp?;

      if (_clearedAtTimestamp != null) {
        print('🧹 Chat limpiado en: ${_clearedAtTimestamp!.toDate()}');
      }

      // Cargar mensajes con filtro de clearedAt en Firestore
      var query = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true);

      // Filtrar por clearedAt en el servidor (más eficiente)
      if (_clearedAtTimestamp != null) {
        query = query.where('timestamp', isGreaterThan: _clearedAtTimestamp);
        print('🔍 Filtrando mensajes después de: ${_clearedAtTimestamp!.toDate()}');
      }

      final snapshot = await query.limit(_messagesPerPage).get();

      // Guardar último documento para paginación
      if (snapshot.docs.isNotEmpty) {
        _lastDocument = snapshot.docs.last;
        _hasMoreMessages = snapshot.docs.length == _messagesPerPage;
      } else {
        _hasMoreMessages = false;
      }

      // Filtrar solo por moderación (en cliente, ya que es complejo en Firestore)
      final messages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
          .where((message) => _shouldIncludeByModeration(message, currentUserId))
          .toList();

      print('📥 Cargados ${messages.length} mensajes de Firestore');
      return messages;
    } catch (e) {
      print('❌ Error cargando mensajes iniciales: $e');
      return [];
    }
  }

  /// Cargar más mensajes antiguos (paginación)
  Future<List<ChatMessage>> loadMoreMessages({
    required String chatId,
    required String currentUserId,
  }) async {
    if (!_hasMoreMessages || _lastDocument == null) {
      print('📄 No hay más mensajes para cargar');
      return [];
    }

    try {
      print('📄 Cargando más mensajes antiguos...');

      var query = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .startAfterDocument(_lastDocument!);

      // Filtrar por clearedAt en el servidor (más eficiente)
      if (_clearedAtTimestamp != null) {
        query = query.where('timestamp', isGreaterThan: _clearedAtTimestamp);
      }

      final snapshot = await query.limit(_messagesPerPage).get();

      if (snapshot.docs.isEmpty) {
        _hasMoreMessages = false;
        print('📄 No hay más mensajes');
        return [];
      }

      // Actualizar último documento
      _lastDocument = snapshot.docs.last;
      _hasMoreMessages = snapshot.docs.length == _messagesPerPage;

      // Filtrar solo por moderación (en cliente)
      final messages = snapshot.docs
          .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
          .where((message) => _shouldIncludeByModeration(message, currentUserId))
          .toList();

      print('📄 Cargados ${messages.length} mensajes adicionales');
      return messages;
    } catch (e) {
      print('❌ Error cargando más mensajes: $e');
      return [];
    }
  }

  /// Verificar si se debe incluir un mensaje por moderación
  /// (El filtrado por clearedAt se hace en Firestore)
  bool _shouldIncludeByModeration(ChatMessage message, String currentUserId) {
    // Filtrar mensajes del contacto sin moderación aprobada/bloqueada
    if (message.senderId != currentUserId) {
      if (message.moderationStatus != ModerationStatus.approved &&
          message.moderationStatus != ModerationStatus.blocked) {
        print('🔒 Ignorando mensaje pendiente: ${message.id}');
        return false;
      }
    }

    return true;
  }

  /// Guardar mensajes en cache
  Future<void> saveMessagesToCache({
    required String chatId,
    required List<ChatMessage> messages,
  }) async {
    try {
      await _cacheService.saveMessages(chatId, messages);
    } catch (e) {
      print('❌ Error guardando en cache: $e');
    }
  }

  /// Limpiar estado de paginación (para recargar)
  void resetPagination() {
    _lastDocument = null;
    _hasMoreMessages = true;
    _clearedAtTimestamp = null;
  }

  /// Obtener clearedAt timestamp
  Timestamp? get clearedAtTimestamp => _clearedAtTimestamp;

  /// Establecer clearedAt timestamp manualmente
  set clearedAtTimestamp(Timestamp? timestamp) {
    _clearedAtTimestamp = timestamp;
  }
}
