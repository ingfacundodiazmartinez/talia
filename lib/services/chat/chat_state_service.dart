import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/chat_message.dart';
import '../message_cache_service.dart';
import '../../utils/release_logger.dart';

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

  /// Trunca un string a los primeros 8 caracteres de forma segura (para logs)
  String _truncateId(String? id) {
    if (id == null) return 'null';
    return id.length > 8 ? id.substring(0, 8) : id;
  }

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
    final truncOldId = oldId.length > 8 ? oldId.substring(0, 8) : oldId;
    final truncNewId = newMessage.id.length > 8 ? newMessage.id.substring(0, 8) : newMessage.id;

    ReleaseLogger.log('🔄[StateService] updateMessage: oldId=$truncOldId... newId=$truncNewId... status=${newMessage.status}', tag: 'ChatState');
    ReleaseLogger.log('🔄[StateService] _messages count=${_messages.length}, _pendingMessages count=${_pendingMessages.length}', tag: 'ChatState');

    final index = _messages.indexWhere((m) => m.id == oldId);
    ReleaseLogger.log('🔄[StateService] indexWhere(id == oldId) = $index', tag: 'ChatState');

    if (index != -1) {
      final oldMessage = _messages[index];
      final truncOldMsgId = oldMessage.id.length > 8 ? oldMessage.id.substring(0, 8) : oldMessage.id;
      ReleaseLogger.log('🔄[StateService] Encontrado mensaje existente: id=$truncOldMsgId... status=${oldMessage.status}', tag: 'ChatState');
      _messages[index] = newMessage;
      _sortMessages();

      // Si el ID cambió, eliminar el viejo del cache
      if (oldId != newMessage.id) {
        await _cacheService.deleteMessage(chatId, oldId);
      }

      await _cacheService.saveMessage(chatId, newMessage);
      ReleaseLogger.log('✅[StateService] Mensaje actualizado exitosamente: newStatus=${newMessage.status}', tag: 'ChatState');
    } else {
      ReleaseLogger.log('⚠️[StateService] Mensaje NO encontrado con oldId=$truncOldId... - puede que ya fue reemplazado por Firestore listener', tag: 'ChatState');
      // Buscar si existe con el nuevo ID (ya fue actualizado por el listener)
      final existingWithNewId = _messages.indexWhere((m) => m.id == newMessage.id);
      if (existingWithNewId != -1) {
        ReleaseLogger.log('ℹ️[StateService] Mensaje ya existe con newId, status actual=${_messages[existingWithNewId].status}', tag: 'ChatState');
      }
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
    ReleaseLogger.log('📥[StateService] addMessages: ${newMessages.length} mensajes', tag: 'ChatState');

    for (final message in newMessages) {
      final truncId = _truncateId(message.id);
      final truncLocalId = _truncateId(message.localId);
      ReleaseLogger.log('📥[StateService] Procesando mensaje: id=$truncId... localId=$truncLocalId... status=${message.status} sender=${message.senderId == currentUserId ? "yo" : "contacto"}', tag: 'ChatState');

      final index = _messages.indexWhere((m) => m.id == message.id);
      ReleaseLogger.log('📥[StateService] indexWhere(id == message.id) = $index', tag: 'ChatState');

      if (index == -1) {
        // Verificar si es un mensaje propio que reemplaza uno pendiente
        if (message.senderId == currentUserId) {
          ReleaseLogger.log('📥[StateService] Es mensaje propio, buscando pendiente...', tag: 'ChatState');
          final pendingIndex = _findMatchingPendingMessage(message);
          ReleaseLogger.log('📥[StateService] _findMatchingPendingMessage returned: $pendingIndex', tag: 'ChatState');

          if (pendingIndex != -1) {
            // Reemplazar mensaje pendiente con el confirmado
            final pendingMessage = _messages[pendingIndex];
            final truncPendingId = _truncateId(pendingMessage.id);
            ReleaseLogger.log('✅[StateService] Reemplazando mensaje pendiente: oldId=$truncPendingId... oldStatus=${pendingMessage.status} → newStatus=${message.status}', tag: 'ChatState');
            _messages[pendingIndex] = message;
            _pendingMessages.removeWhere((m) => m.id == pendingMessage.id);
            continue;
          } else {
            ReleaseLogger.log('⚠️[StateService] No se encontró mensaje pendiente para reemplazar', tag: 'ChatState');
          }
        }

        // Mensaje nuevo
        ReleaseLogger.log('📥[StateService] Agregando como mensaje nuevo', tag: 'ChatState');
        _messages.add(message);
      } else {
        // Mensaje existente - actualizar solo si es necesario
        final existingMessage = _messages[index];
        ReleaseLogger.log('📥[StateService] Mensaje ya existe: existingStatus=${existingMessage.status} newStatus=${message.status}', tag: 'ChatState');

        // Solo actualizar si es mensaje del contacto o hay cambios importantes
        if (message.senderId != currentUserId ||
            _hasImportantChanges(existingMessage, message)) {
          ReleaseLogger.log('📥[StateService] Actualizando mensaje existente (cambios importantes)', tag: 'ChatState');
          _messages[index] = message;
        } else {
          ReleaseLogger.log('📥[StateService] No hay cambios importantes, no actualizando', tag: 'ChatState');
        }
      }
    }

    _sortMessages();
    await _cacheService.saveMessages(chatId, _messages);
  }

  /// Encontrar mensaje pendiente que coincida con el mensaje de Firestore
  /// Ahora usa localId para un match preciso en lugar de heurísticas
  int _findMatchingPendingMessage(ChatMessage firestoreMessage) {
    ReleaseLogger.log('🔍[StateService] _findMatchingPendingMessage: localId=${_truncateId(firestoreMessage.localId)}...', tag: 'ChatState');
    ReleaseLogger.log('🔍[StateService] _pendingMessages: ${_pendingMessages.map((m) => _truncateId(m.id)).toList()}', tag: 'ChatState');
    ReleaseLogger.log('🔍[StateService] _messages ids: ${_messages.map((m) => _truncateId(m.id)).toList()}', tag: 'ChatState');

    // Buscar por localId si existe (método nuevo y preciso)
    if (firestoreMessage.localId != null) {
      ReleaseLogger.log('🔍[StateService] Buscando por localId: ${_truncateId(firestoreMessage.localId)}...', tag: 'ChatState');

      final index = _messages.indexWhere((m) =>
        m.id == firestoreMessage.localId &&
        _pendingMessages.any((p) => p.id == m.id)
      );

      ReleaseLogger.log('🔍[StateService] indexWhere(id == localId) = $index', tag: 'ChatState');

      if (index != -1) {
        ReleaseLogger.log('✅[StateService] Encontrado por localId en index $index', tag: 'ChatState');
        return index;
      } else {
        // Debug: verificar si el mensaje existe pero no está en pending
        final msgIndex = _messages.indexWhere((m) => m.id == firestoreMessage.localId);
        final inPending = _pendingMessages.any((p) => p.id == firestoreMessage.localId);
        ReleaseLogger.log('⚠️[StateService] localId match failed: msgExists=$msgIndex inPending=$inPending', tag: 'ChatState');
      }
    } else {
      ReleaseLogger.log('⚠️[StateService] firestoreMessage.localId es null!', tag: 'ChatState');
    }

    // Fallback: buscar por contenido (para compatibilidad con mensajes viejos)
    ReleaseLogger.log('🔍[StateService] Intentando fallback por contenido...', tag: 'ChatState');
    if (firestoreMessage.timestamp == null) {
      ReleaseLogger.log('⚠️[StateService] firestoreMessage.timestamp es null, no se puede usar fallback', tag: 'ChatState');
      return -1;
    }

    final fallbackIndex = _messages.indexWhere((m) {
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

    ReleaseLogger.log('🔍[StateService] Fallback result: $fallbackIndex', tag: 'ChatState');
    return fallbackIndex;
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
