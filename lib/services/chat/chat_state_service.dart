import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/chat_message.dart';
import '../message_cache_service.dart';

/// Servicio para gestión del estado de mensajes en memoria
///
/// Responsabilidades:
/// - Mantener lista de mensajes en memoria
/// - Gestionar mensajes pendientes (optimistic updates)
/// - Merge y deduplicación de mensajes
/// - Ordenamiento de mensajes
/// - Sincronización con cache
class ChatStateService {
  final MessageCacheService _cacheService;

  // Lista de mensajes en memoria
  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  // Queue de mensajes pendientes (optimistic)
  final List<ChatMessage> _pendingMessages = [];
  List<ChatMessage> get pendingMessages => List.unmodifiable(_pendingMessages);

  // Timestamp del último mensaje cargado
  Timestamp? _lastMessageTimestamp;
  Timestamp? get lastMessageTimestamp => _lastMessageTimestamp;

  ChatStateService({
    MessageCacheService? cacheService,
  }) : _cacheService = cacheService ?? MessageCacheService();

  /// Agregar mensaje optimista
  void addOptimisticMessage(ChatMessage message) {
    _messages.insert(0, message);
    _pendingMessages.add(message);
    _sortMessages();
  }

  /// Actualizar mensaje (de temporal a confirmado)
  Future<void> updateMessage({
    required String chatId,
    required String oldId,
    required ChatMessage newMessage,
  }) async {
    final index = _messages.indexWhere((m) => m.id == oldId);
    if (index != -1) {
      _messages[index] = newMessage;
      _sortMessages();

      // Si el ID cambió, eliminar el viejo del cache
      if (oldId != newMessage.id) {
        print('🔄 Actualizando mensaje: $oldId -> ${newMessage.id}');
        await _cacheService.deleteMessage(chatId, oldId);
      }

      await _cacheService.saveMessage(chatId, newMessage);
    }
  }

  /// Eliminar mensaje pendiente
  void removePendingMessage(String messageId) {
    _pendingMessages.removeWhere((m) => m.id == messageId);
  }

  /// Eliminar mensaje de la lista
  void removeMessage(String messageId) {
    _messages.removeWhere((m) => m.id == messageId);
  }

  /// Agregar múltiples mensajes (merge con existentes)
  Future<void> addMessages({
    required String chatId,
    required List<ChatMessage> newMessages,
    required String currentUserId,
  }) async {
    int addedCount = 0;
    int updatedCount = 0;
    int skippedCount = 0;

    for (final message in newMessages) {
      final index = _messages.indexWhere((m) => m.id == message.id);

      if (index == -1) {
        // Mensaje nuevo
        _messages.add(message);
        addedCount++;
      } else {
        // Mensaje existente - actualizar solo si es necesario
        final existingMessage = _messages[index];

        // Solo actualizar si es mensaje del contacto o hay cambios importantes
        if (message.senderId != currentUserId ||
            _hasImportantChanges(existingMessage, message)) {
          _messages[index] = message;
          updatedCount++;
        } else {
          skippedCount++;
        }
      }
    }

    _sortMessages();
    await _cacheService.saveMessages(chatId, _messages);

    print('📊 Merge: $addedCount nuevos, $updatedCount actualizados, $skippedCount omitidos');
  }

  /// Verificar si hay cambios importantes entre mensajes
  bool _hasImportantChanges(ChatMessage old, ChatMessage updated) {
    return old.isRead != updated.isRead ||
        old.status != updated.status ||
        old.moderationStatus != updated.moderationStatus ||
        old.reactions != updated.reactions;
  }

  /// Reemplazar todos los mensajes
  void replaceAllMessages(List<ChatMessage> newMessages) {
    _messages.clear();
    _messages.addAll(newMessages);
    _sortMessages();
  }

  /// Limpiar todos los mensajes
  void clear() {
    _messages.clear();
    _pendingMessages.clear();
    _lastMessageTimestamp = null;
  }

  /// Ordenar mensajes por timestamp (más reciente primero)
  void _sortMessages() {
    _messages.sort((a, b) {
      final aTime = a.effectiveTimestamp;
      final bTime = b.effectiveTimestamp;
      return bTime.compareTo(aTime);
    });

    // Actualizar último timestamp
    if (_messages.isNotEmpty && _messages.first.timestamp != null) {
      _lastMessageTimestamp = _messages.first.timestamp;
    }
  }

  /// Verificar si un mensaje ya existe
  bool messageExists(String messageId) {
    return _messages.any((m) => m.id == messageId);
  }

  /// Verificar si un mensaje es duplicado (por contenido y timestamp)
  bool isDuplicateMessage({
    required String senderId,
    required Timestamp? timestamp,
    String? text,
    String? imageUrl,
  }) {
    if (timestamp == null) return false;

    return _messages.any((m) =>
        m.senderId == senderId &&
        m.timestamp != null &&
        (m.timestamp!.seconds == timestamp.seconds) &&
        (m.text == text || m.imageUrl == imageUrl));
  }

  /// Obtener mensaje por ID
  ChatMessage? getMessageById(String messageId) {
    try {
      return _messages.firstWhere((m) => m.id == messageId);
    } catch (e) {
      return null;
    }
  }

  /// Contar mensajes
  int get messageCount => _messages.length;
  int get pendingMessageCount => _pendingMessages.length;

  /// Verificar si hay mensajes
  bool get hasMessages => _messages.isNotEmpty;
  bool get hasPendingMessages => _pendingMessages.isNotEmpty;

  /// Actualizar timestamp del último mensaje
  void updateLastMessageTimestamp(Timestamp? timestamp) {
    _lastMessageTimestamp = timestamp;
  }
}
