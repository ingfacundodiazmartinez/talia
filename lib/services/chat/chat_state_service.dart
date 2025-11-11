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
    for (final message in newMessages) {
      final index = _messages.indexWhere((m) => m.id == message.id);

      if (index == -1) {
        // Verificar si es un mensaje propio que reemplaza uno pendiente
        if (message.senderId == currentUserId) {
          final pendingIndex = _findMatchingPendingMessage(message);
          if (pendingIndex != -1) {
            // Reemplazar mensaje pendiente con el confirmado
            final pendingMessage = _messages[pendingIndex];
            _messages[pendingIndex] = message;
            _pendingMessages.removeWhere((m) => m.id == pendingMessage.id);
            continue;
          }
        }

        // Mensaje nuevo
        _messages.add(message);
      } else {
        // Mensaje existente - actualizar solo si es necesario
        final existingMessage = _messages[index];

        // Solo actualizar si es mensaje del contacto o hay cambios importantes
        if (message.senderId != currentUserId ||
            _hasImportantChanges(existingMessage, message)) {
          _messages[index] = message;
        }
      }
    }

    _sortMessages();
    await _cacheService.saveMessages(chatId, _messages);
  }

  /// Encontrar mensaje pendiente que coincida con el mensaje de Firestore
  /// Ahora usa localId para un match preciso en lugar de heurísticas
  int _findMatchingPendingMessage(ChatMessage firestoreMessage) {
    // Buscar por localId si existe (método nuevo y preciso)
    if (firestoreMessage.localId != null) {
      final index = _messages.indexWhere((m) =>
        m.id == firestoreMessage.localId &&
        _pendingMessages.any((p) => p.id == m.id)
      );
      if (index != -1) {
        return index;
      }
    }

    // Fallback: buscar por contenido (para compatibilidad con mensajes viejos)
    if (firestoreMessage.timestamp == null) return -1;

    return _messages.indexWhere((m) {
      // Debe estar en la lista de pendientes
      if (!_pendingMessages.any((p) => p.id == m.id)) return false;

      // Debe ser del mismo remitente
      if (m.senderId != firestoreMessage.senderId) return false;

      // Verificar coincidencia por tipo y contenido
      if (m.type != firestoreMessage.type) return false;

      // Para mensajes de texto, verificar contenido
      if (m.type == 'text' && m.text == firestoreMessage.text) {
        return true;
      }

      // Para imágenes, verificar URL (puede ser la misma si fue subida)
      if (m.type == 'image' && m.imageUrl == firestoreMessage.imageUrl) {
        return true;
      }

      // Para videos, verificar URL
      if (m.type == 'video' && m.videoUrl == firestoreMessage.videoUrl) {
        return true;
      }

      // Para audios, verificar URL (si ya fue subido) o waveform (si coincide)
      if (m.type == 'audio') {
        if (m.audioUrl == firestoreMessage.audioUrl && m.audioUrl != null) {
          return true;
        }
        // Si el mensaje pendiente tiene localPath y el de Firestore tiene audioUrl,
        // podría ser el mismo mensaje subido
        if (m.localPath != null && firestoreMessage.audioUrl != null) {
          // Verificar por timestamp cercano (dentro de 2 segundos)
          if (m.timestamp != null && firestoreMessage.timestamp != null) {
            final diff = (m.timestamp!.seconds - firestoreMessage.timestamp!.seconds).abs();
            return diff <= 2;
          }
        }
      }

      return false;
    });
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
