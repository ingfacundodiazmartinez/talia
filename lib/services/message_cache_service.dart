import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/chat_message.dart';
import '../utils/release_logger.dart';

/// Servicio para cachear mensajes localmente usando Hive
///
/// Responsabilidades:
/// - Guardar mensajes en cache local
/// - Recuperar mensajes del cache
/// - Gestionar límites de almacenamiento (200 mensajes por chat)
/// - Inicializar y cerrar Hive
class MessageCacheService {
  static final MessageCacheService _instance = MessageCacheService._internal();
  factory MessageCacheService() => _instance;
  MessageCacheService._internal();

  static const String _boxName = 'messages_cache';
  // Cache ilimitado - la paginación se maneja en los controllers
  static const int? maxMessagesPerChat = null;

  Box? _messagesBox;

  // ═══════════════════════════════════════════════════════════════════
  // LAST MESSAGE INDEX (in-memory, derivado de Hive)
  // ═══════════════════════════════════════════════════════════════════
  // Map chatId → último ChatMessage para preview en chat list.
  // O(1) lookup, mantenido al save de cada mensaje.
  // Source of truth: Hive (este servicio). Firestore.lastMessage queda como
  // legacy/backward compat solo, el cliente nuevo NO lo lee.
  final Map<String, ChatMessage> _lastMessageByChat = {};
  final StreamController<String> _lastMessageChangeController =
      StreamController<String>.broadcast();

  /// Stream que emite el chatId cada vez que cambia su último mensaje.
  /// Subscribers pueden filtrar por chatId si solo les interesa uno.
  Stream<String> get lastMessageChanges => _lastMessageChangeController.stream;

  /// Inicializar Hive y abrir la box
  Future<void> initialize() async {
    try {
      await Hive.initFlutter();
      _messagesBox = await Hive.openBox(_boxName);

      // Reconstruir el índice de últimos mensajes desde lo que hay en cache.
      _rebuildLastMessageIndex();

      // Ejecutar limpieza de mensajes viejos (si es necesario)
      await _checkAndCleanupOldMessages();
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Reconstruir el índice in-memory de últimos mensajes recorriendo todo el
  /// box una sola vez (al boot). Necesario porque al cold-start no tenemos
  /// el map todavía.
  void _rebuildLastMessageIndex() {
    if (_messagesBox == null) return;
    _lastMessageByChat.clear();
    for (final raw in _messagesBox!.keys) {
      try {
        final key = raw.toString();
        if (key.startsWith('_')) continue; // metadata (_last_cleanup_timestamp)
        final data = _messagesBox!.get(raw) as Map<dynamic, dynamic>?;
        if (data == null) continue;
        // La key es '<chatId>_<messageId>' pero el chatId de chats 1:1 es
        // 'uidA_uidB' (contiene underscore), así que NO se puede cortar en el
        // primer '_'. Derivamos el chatId quitando el sufijo '_<id>' usando
        // el id guardado en la entrada.
        final msgId = data['id'] as String?;
        if (msgId == null || msgId.isEmpty) continue;
        if (!key.endsWith('_$msgId')) continue;
        final chatId = key.substring(0, key.length - msgId.length - 1);
        if (chatId.isEmpty) continue;
        final msg = _messageFromCacheData(data);
        _maybeUpdateLastMessage(chatId, msg, notify: false);
      } catch (_) {
        // Entrada corrupta — saltar y seguir con el resto del cache.
      }
    }
  }

  /// Actualizar el índice si el mensaje recibido es más reciente que el
  /// que tenemos. Emite evento al stream si cambió.
  void _maybeUpdateLastMessage(String chatId, ChatMessage msg, {bool notify = true}) {
    final current = _lastMessageByChat[chatId];

    // 🗑️ Un mensaje eliminado NO debe ser el "último mensaje" de la lista
    // (el user pidió ver el último mensaje REAL, no "Mensaje eliminado").
    // Si el que se acaba de eliminar era el último conocido, recalculamos al
    // último mensaje no eliminado del cache.
    if (msg.isDeletedForEveryone) {
      if (current != null && current.id == msg.id) {
        _recomputeLastMessageExcludingDeleted(chatId, notify: notify);
      }
      return;
    }

    final msgTs = _resolveDateTime(msg);
    final currentTs = current == null ? null : _resolveDateTime(current);
    // Si el nuevo mensaje no tiene ningún timestamp, no podemos comparar — skip.
    if (msgTs == null) return;
    if (current == null || currentTs == null || msgTs.isAfter(currentTs) || msg.id == current.id) {
      // msg.id == current.id permite ACTUALIZAR (ej. status sent → delivered)
      // del mismo último mensaje sin que el timestamp cambie.
      _lastMessageByChat[chatId] = msg;
      if (notify && !_lastMessageChangeController.isClosed) {
        _lastMessageChangeController.add(chatId);
      }
    }
  }

  /// Recalcular (sync) el último mensaje NO eliminado recorriendo el cache.
  void _recomputeLastMessageExcludingDeleted(String chatId, {bool notify = true}) {
    if (_messagesBox == null) {
      _lastMessageByChat.remove(chatId);
      return;
    }
    ChatMessage? best;
    DateTime? bestTs;
    final prefix = '${chatId}_';
    for (final raw in _messagesBox!.keys) {
      final key = raw.toString();
      if (!key.startsWith(prefix)) continue;
      final data = _messagesBox!.get(raw) as Map<dynamic, dynamic>?;
      if (data == null) continue;
      if (data['isDeletedForEveryone'] == true) continue;
      final msgId = data['id'] as String?;
      if (msgId == null || !key.endsWith('_$msgId')) continue;
      final m = _messageFromCacheData(data);
      final ts = _resolveDateTime(m);
      if (ts == null) continue;
      if (bestTs == null || ts.isAfter(bestTs)) {
        best = m;
        bestTs = ts;
      }
    }
    if (best != null) {
      _lastMessageByChat[chatId] = best;
    } else {
      _lastMessageByChat.remove(chatId);
    }
    if (notify && !_lastMessageChangeController.isClosed) {
      _lastMessageChangeController.add(chatId);
    }
  }

  /// Resolver el DateTime de un mensaje priorizando timestamp del servidor
  /// (Firestore Timestamp) sobre localTimestamp (DateTime).
  DateTime? _resolveDateTime(ChatMessage m) {
    if (m.timestamp != null) return m.timestamp!.toDate();
    return m.localTimestamp;
  }

  /// Obtener el último mensaje cacheado para un chat (O(1)).
  /// Source of truth para chat list preview.
  ChatMessage? getLastMessage(String chatId) => _lastMessageByChat[chatId];

  /// Sembrar el preview del último mensaje SOLO en el índice en memoria, sin
  /// tocar el box persistente.
  ///
  /// Se usa cuando el ChatDocsListener detecta un mensaje nuevo desde el chat
  /// doc (que YA trae lastMessage*, lastMessageTime, etc.) y queremos que la
  /// chat list lo refleje AL INSTANTE — junto con la notificación — sin
  /// esperar el fetch completo de la subcolección (prefetch, ~segundos).
  ///
  /// El mensaje real, cuando llega por el listener de la subcolección,
  /// persiste al box y reemplaza este seed (mismo id). NO escribimos al box a
  /// propósito: así la vista de mensajes del chat (que lee del box vía
  /// getMessages) no muestra un mensaje "virtual" con un preview de media como
  /// texto (ej. "📷 Imagen"). El mensaje necesita timestamp (o localTimestamp)
  /// o _maybeUpdateLastMessage lo descarta.
  void seedLastMessage(String chatId, ChatMessage message) {
    _maybeUpdateLastMessage(chatId, message);
  }

  /// Versión IDEMPOTENTE del seed: solo siembra/emite si es un mensaje
  /// genuinamente más nuevo (id distinto + timestamp posterior, o no había
  /// nada). Si el último ya es este mismo mensaje, es no-op (no re-emite) —
  /// clave para poder llamarlo en cada emisión del stream / push sin disparar
  /// rebuilds en loop. Se usa para sembrar desde el payload del FCM, que llega
  /// más rápido que el listener del chat doc (socket gRPC).
  void seedLastMessageIfNewer(String chatId, ChatMessage message) {
    final current = _lastMessageByChat[chatId];
    if (current != null && current.id == message.id) return; // ya está
    final msgTs = _resolveDateTime(message);
    if (msgTs == null) return;
    final currentTs = current == null ? null : _resolveDateTime(current);
    if (current == null || currentTs == null || msgTs.isAfter(currentTs)) {
      _lastMessageByChat[chatId] = message;
      if (!_lastMessageChangeController.isClosed) {
        _lastMessageChangeController.add(chatId);
      }
    }
  }

  /// Stream del último mensaje de un chat. Emite el valor actual y luego
  /// cualquier cambio. Reemplaza `ListMessagesService.watchLastMessage` que
  /// iba a Firestore.
  Stream<ChatMessage?> watchLastMessage(String chatId) async* {
    yield getLastMessage(chatId);
    yield* lastMessageChanges
        .where((id) => id == chatId)
        .map((_) => getLastMessage(chatId));
  }

  /// Verifica si es necesario ejecutar limpieza y la ejecuta (máximo una vez al día)
  Future<void> _checkAndCleanupOldMessages() async {
    if (_messagesBox == null) return;

    try {
      const lastCleanupKey = '_last_cleanup_timestamp';
      final lastCleanup = _messagesBox!.get(lastCleanupKey) as int?;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Si no hay registro o han pasado más de 24 horas, ejecutar limpieza
      if (lastCleanup == null || (now - lastCleanup) > 24 * 60 * 60 * 1000) {
        await cleanupOldMessages();

        // Guardar timestamp de esta limpieza
        await _messagesBox!.put(lastCleanupKey, now);
      }
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Guardar un mensaje en el cache
  Future<void> saveMessage(String chatId, ChatMessage message) async {
    if (_messagesBox == null) return;

    try {
      // ✅ FIX: Si el mensaje tiene localId, eliminar el mensaje optimista anterior
      if (message.localId != null) {
        final oldKey = '${chatId}_${message.localId}';
        await _messagesBox!.delete(oldKey);
      }

      final key = '${chatId}_${message.id}';
      final data = {
        'id': message.id,
        'senderId': message.senderId,
        'text': message.text,
        'imageUrl': message.imageUrl,
        'videoUrl': message.videoUrl,
        'audioUrl': message.audioUrl,
        'timestamp': message.timestamp?.millisecondsSinceEpoch,
        'localTimestamp': message.localTimestamp?.millisecondsSinceEpoch,
        'isRead': message.isRead,
        'replyTo': message.replyTo,
        'reactions': message.reactions,
        'type': message.type,
        'status': message.status.name,
        'retryCount': message.retryCount,
        'localId': message.localId, // ✅ FIX: Guardar localId para deduplicación
        // Campos de moderación
        'moderationStatus': message.moderationStatus?.name,
        'moderationReason': message.moderationReason,
        'originalText': message.originalText,
        // ✅ FIX #8: Campos de reenvío
        'isForwarded': message.isForwarded,
        'originalSenderId': message.originalSenderId,
        'originalChatId': message.originalChatId,
        'originalContactName': message.originalContactName,
        // ✅ FIX: Campo de eliminación
        'isDeletedForEveryone': message.isDeletedForEveryone,
        // ✅ Visibilidad por destinatario
        'visibleTo': message.visibleTo,
        'latitude': message.latitude,
        'longitude': message.longitude,
        'isLiveLocation': message.isLiveLocation,
        'liveLocationExpiresAt': message.liveLocationExpiresAt?.millisecondsSinceEpoch,
        // ✅ FIX: Persistir path local y waveform para que el preview de media
        // (imagen/audio) sobreviva salir/reentrar al chat mientras sube.
        'localPath': message.localPath,
        'waveformData': message.waveformData,
      };

      await _messagesBox!.put(key, data);
      _maybeUpdateLastMessage(chatId, message);

      // Limpiar mensajes viejos si excedemos el límite
      await _cleanOldMessages(chatId);
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Guardar múltiples mensajes
  Future<void> saveMessages(String chatId, List<ChatMessage> messages) async {
    if (_messagesBox == null) return;

    try {
      // ✅ FIX: Primero eliminar mensajes optimistas que serán reemplazados
      for (final message in messages) {
        if (message.localId != null) {
          final oldKey = '${chatId}_${message.localId}';
          await _messagesBox!.delete(oldKey);
        }
      }

      final entries = <String, Map<String, dynamic>>{};
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final message in messages) {
        final key = '${chatId}_${message.id}';

        // ✅ V2: Preservar localSavedAt si el mensaje ya existe en cache
        int? existingLocalSavedAt;
        final existingData = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (existingData != null) {
          existingLocalSavedAt = existingData['localSavedAt'] as int?;
        }

        entries[key] = {
          'id': message.id,
          'senderId': message.senderId,
          'text': message.text,
          'imageUrl': message.imageUrl,
          'videoUrl': message.videoUrl,
          'audioUrl': message.audioUrl,
          'timestamp': message.timestamp?.millisecondsSinceEpoch,
          'localTimestamp': message.localTimestamp?.millisecondsSinceEpoch,
          'localSavedAt': existingLocalSavedAt ?? now,
          'isRead': message.isRead,
          'replyTo': message.replyTo,
          'reactions': message.reactions,
          'type': message.type,
          'status': message.status.name,
          'retryCount': message.retryCount,
          'localId': message.localId, // ✅ FIX: Guardar localId para deduplicación
          // Campos de moderación
          'moderationStatus': message.moderationStatus?.name,
          'moderationReason': message.moderationReason,
          'originalText': message.originalText,
          // ✅ FIX #8: Campos de reenvío
          'isForwarded': message.isForwarded,
          'originalSenderId': message.originalSenderId,
          'originalChatId': message.originalChatId,
          'originalContactName': message.originalContactName,
          // ✅ FIX: Campo de eliminación
          'isDeletedForEveryone': message.isDeletedForEveryone,
          // ✅ Visibilidad por destinatario
          'visibleTo': message.visibleTo,
        'latitude': message.latitude,
        'longitude': message.longitude,
        'isLiveLocation': message.isLiveLocation,
        'liveLocationExpiresAt': message.liveLocationExpiresAt?.millisecondsSinceEpoch,
        };
      }

      await _messagesBox!.putAll(entries);
      // Update index para el mensaje más reciente del batch.
      for (final m in messages) {
        _maybeUpdateLastMessage(chatId, m);
      }
      await _cleanOldMessages(chatId);

    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Recuperar mensajes del cache para un chat
  /// ✅ FIX: Deduplicación por ID y localId para evitar mensajes duplicados
  /// ✅ V3: Ordenar por timestamp del servidor (orden cronológico real)
  Future<List<ChatMessage>> getMessages(String chatId) async {
    if (_messagesBox == null) return [];

    try {
      final messages = <ChatMessage>[];
      final seenIds = <String>{};
      final seenLocalIds = <String>{};
      final keys = _messagesBox!.keys.where((key) => key.toString().startsWith(chatId));

      // Primera pasada: recolectar localIds de mensajes confirmados (de Firestore)
      for (final key in keys) {
        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data != null) {
          final localId = data['localId'] as String?;
          if (localId != null) {
            seenLocalIds.add(localId);
          }
        }
      }

      // Segunda pasada: construir lista sin duplicados
      for (final key in keys) {
        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data != null) {
          final msgId = data['id'] as String?;
          if (msgId == null) continue;

          // Skip si ya vimos este ID
          if (seenIds.contains(msgId)) continue;

          // Skip si es mensaje optimista que ya tiene versión confirmada
          // PERO no si el mensaje ES la versión confirmada (su propio localId == id)
          final msgLocalId = data['localId'] as String?;
          if (seenLocalIds.contains(msgId) && msgId != msgLocalId) continue;

          final msg = _messageFromCacheData(data);
          messages.add(msg);
          seenIds.add(msgId);
        }
      }

      // ✅ Ordenar por tiempo EFECTIVO (timestamp del servidor, o localTimestamp
      // si todavía no tiene). Antes los mensajes sin timestamp de servidor iban
      // SIEMPRE primero (= abajo en la lista reverse), así que un mensaje fallido
      // (que nunca obtiene timestamp de servidor) quedaba clavado como ÚLTIMA
      // burbuja del chat para siempre. Con localTimestamp como fallback, queda en
      // su lugar cronológico y los mensajes nuevos se ubican debajo.
      messages.sort((a, b) {
        final aTime = a.timestamp?.toDate() ?? a.localTimestamp;
        final bTime = b.timestamp?.toDate() ?? b.localTimestamp;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1; // sin ningún tiempo → al final (arriba)
        if (bTime == null) return -1;
        return bTime.compareTo(aTime); // descendente: más reciente primero (index 0)
      });

      return messages;
    } catch (e) {
      return [];
    }
  }

  /// Actualizar el estado de un mensaje
  Future<void> updateMessageStatus(
    String chatId,
    String messageId,
    MessageStatus status,
  ) async {
    if (_messagesBox == null) return;

    try {
      final key = '${chatId}_$messageId';
      final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;

      if (data != null) {
        data['status'] = status.name;
        await _messagesBox!.put(key, data);
        // Si era el último mensaje del chat, refrescar el índice para que la
        // chat list vea los iconos sent/delivered/seen actualizados.
        final last = _lastMessageByChat[chatId];
        if (last != null && last.id == messageId) {
          _maybeUpdateLastMessage(
            chatId,
            _messageFromCacheData(data),
          );
        }
      }
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Actualizar un mensaje completo en el cache
  Future<void> updateMessage(String chatId, ChatMessage message) async {
    if (_messagesBox == null) return;

    try {
      // ✅ FIX: Si el mensaje tiene localId, eliminar el mensaje optimista anterior
      if (message.localId != null) {
        final oldKey = '${chatId}_${message.localId}';
        await _messagesBox!.delete(oldKey);
      }

      final key = '${chatId}_${message.id}';
      final data = {
        'id': message.id,
        'senderId': message.senderId,
        'text': message.text,
        'imageUrl': message.imageUrl,
        'videoUrl': message.videoUrl,
        'audioUrl': message.audioUrl,
        'timestamp': message.timestamp?.millisecondsSinceEpoch,
        'localTimestamp': message.localTimestamp?.millisecondsSinceEpoch,
        'isRead': message.isRead,
        'replyTo': message.replyTo,
        'reactions': message.reactions,
        'type': message.type,
        'status': message.status.name,
        'retryCount': message.retryCount,
        'localId': message.localId, // ✅ FIX: Guardar localId para deduplicación
        // Campos de moderación
        'moderationStatus': message.moderationStatus?.name,
        'moderationReason': message.moderationReason,
        'originalText': message.originalText,
        // ✅ FIX #8: Campos de reenvío
        'isForwarded': message.isForwarded,
        'originalSenderId': message.originalSenderId,
        'originalChatId': message.originalChatId,
        'originalContactName': message.originalContactName,
        // ✅ FIX: Campo de eliminación
        'isDeletedForEveryone': message.isDeletedForEveryone,
        // ✅ Visibilidad por destinatario
        'visibleTo': message.visibleTo,
        'latitude': message.latitude,
        'longitude': message.longitude,
        'isLiveLocation': message.isLiveLocation,
        'liveLocationExpiresAt': message.liveLocationExpiresAt?.millisecondsSinceEpoch,
        // ✅ FIX: Persistir path local y waveform (ver saveMessage).
        'localPath': message.localPath,
        'waveformData': message.waveformData,
      };

      await _messagesBox!.put(key, data);
      _maybeUpdateLastMessage(chatId, message);
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Eliminar mensaje del cache
  Future<void> deleteMessage(String chatId, String messageId) async {
    if (_messagesBox == null) return;

    try {
      final key = '${chatId}_$messageId';
      await _messagesBox!.delete(key);
      // Si era el último mensaje, recalcular el último real recorriendo cache.
      final last = _lastMessageByChat[chatId];
      if (last != null && last.id == messageId) {
        await _recomputeLastMessage(chatId);
      }
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Recalcular el último mensaje de un chat iterando todo el cache.
  /// Solo se llama cuando se elimina el que era el último (caso poco frecuente).
  Future<void> _recomputeLastMessage(String chatId) async {
    if (_messagesBox == null) return;
    try {
      _lastMessageByChat.remove(chatId);
      final prefix = '${chatId}_';
      for (final raw in _messagesBox!.keys) {
        if (!raw.toString().startsWith(prefix)) continue;
        final data = _messagesBox!.get(raw) as Map<dynamic, dynamic>?;
        if (data == null) continue;
        _maybeUpdateLastMessage(chatId, _messageFromCacheData(data), notify: false);
      }
      // Emitir un solo evento al final.
      if (!_lastMessageChangeController.isClosed) {
        _lastMessageChangeController.add(chatId);
      }
    } catch (_) {}
  }

  /// Limpiar mensajes viejos si excedemos el límite
  Future<void> _cleanOldMessages(String chatId) async {
    if (_messagesBox == null || maxMessagesPerChat == null) return;

    try {
      final messages = await getMessages(chatId);

      if (messages.length > maxMessagesPerChat!) {
        // Eliminar los mensajes más viejos
        final toDelete = messages.skip(maxMessagesPerChat!).toList();
        for (final message in toDelete) {
          await deleteMessage(chatId, message.id);
        }

      }
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Limpiar todos los mensajes de un chat
  Future<void> clearChat(String chatId) async {
    if (_messagesBox == null) {
      ReleaseLogger.log('⚠️ [MessageCache] clearChat: _messagesBox es null', tag: 'MessageCache');
      return;
    }

    try {
      final keys = _messagesBox!.keys
          .where((key) => key.toString().startsWith('${chatId}_'))
          .toList();

      ReleaseLogger.log('🗑️ [MessageCache] clearChat: Eliminando ${keys.length} mensajes para chat $chatId', tag: 'MessageCache');

      for (final key in keys) {
        await _messagesBox!.delete(key);
      }

      ReleaseLogger.log('✅ [MessageCache] clearChat: Chat $chatId limpiado exitosamente', tag: 'MessageCache');
    } catch (e) {
      ReleaseLogger.error('❌ [MessageCache] clearChat error: $e', tag: 'MessageCache');
    }
  }

  /// Convertir datos del cache a ChatMessage
  ChatMessage _messageFromCacheData(Map<dynamic, dynamic> data) {
    return ChatMessage(
      id: data['id'] as String,
      senderId: data['senderId'] as String,
      text: data['text'] as String?,
      imageUrl: data['imageUrl'] as String?,
      videoUrl: data['videoUrl'] as String?,
      audioUrl: data['audioUrl'] as String?,
      timestamp: data['timestamp'] != null
          ? Timestamp.fromMillisecondsSinceEpoch(data['timestamp'] as int)
          : null,
      localTimestamp: data['localTimestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['localTimestamp'] as int)
          : null,
      isRead: data['isRead'] as bool? ?? false,
      replyTo: data['replyTo'] != null
          ? Map<String, dynamic>.from(data['replyTo'] as Map)
          : null,
      reactions: data['reactions'] != null
          ? Map<String, dynamic>.from(data['reactions'] as Map)
          : null,
      type: data['type'] as String?,
      status: _parseMessageStatus(data['status'] as String?),
      retryCount: data['retryCount'] as int? ?? 0,
      localId: data['localId'] as String?, // ✅ FIX: Cargar localId desde cache
      // Campos de moderación
      moderationStatus: _parseModerationStatus(data['moderationStatus'] as String?),
      moderationReason: data['moderationReason'] as String?,
      originalText: data['originalText'] as String?,
      // ✅ FIX #8: Campos de reenvío
      isForwarded: data['isForwarded'] as bool? ?? false,
      originalSenderId: data['originalSenderId'] as String?,
      originalChatId: data['originalChatId'] as String?,
      originalContactName: data['originalContactName'] as String?,
      // ✅ FIX: Campo de eliminación
      isDeletedForEveryone: data['isDeletedForEveryone'] as bool? ?? false,
      // ✅ Visibilidad por destinatario
      visibleTo: data['visibleTo'] != null
          ? List<String>.from(data['visibleTo'] as List)
          : null,
      // ✅ FIX: Restaurar path local y waveform para el preview de media pending.
      localPath: data['localPath'] as String?,
      waveformData: data['waveformData'] != null
          ? List<double>.from(
              (data['waveformData'] as List).map((e) => (e as num).toDouble()))
          : null,
      // ✅ Ubicación
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      isLiveLocation: data['isLiveLocation'] as bool? ?? false,
      liveLocationExpiresAt: data['liveLocationExpiresAt'] != null
          ? Timestamp.fromMillisecondsSinceEpoch(
              data['liveLocationExpiresAt'] as int)
          : null,
    );
  }

  /// Parsear estado del mensaje desde string
  MessageStatus _parseMessageStatus(String? status) {
    switch (status) {
      case 'sending':
        return MessageStatus.sending;
      case 'sent':
        return MessageStatus.sent;
      case 'delivered':
        return MessageStatus.delivered;
      case 'seen':
        return MessageStatus.seen;
      case 'error':
        return MessageStatus.error;
      default:
        return MessageStatus.sent;
    }
  }

  /// Parsear estado de moderación desde string
  ModerationStatus? _parseModerationStatus(String? status) {
    if (status == null) return null;

    switch (status) {
      case 'approved':
        return ModerationStatus.approved;
      case 'blocked':
        return ModerationStatus.blocked;
      case 'pending':
        return ModerationStatus.pending;
      default:
        return null;
    }
  }

  /// Limpiar mensajes más viejos de 7 días del cache local
  Future<void> cleanupOldMessages({int daysToKeep = 7}) async {
    if (_messagesBox == null) return;

    try {
      final now = DateTime.now();
      final cutoffDate = now.subtract(Duration(days: daysToKeep));
      final cutoffMillis = cutoffDate.millisecondsSinceEpoch;

      int deletedCount = 0;
      final keysToDelete = <String>[];

      // Iterar sobre todos los mensajes en el cache
      for (final key in _messagesBox!.keys) {
        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data != null) {
          // Verificar timestamp
          final timestamp = data['timestamp'] as int?;
          final localTimestamp = data['localTimestamp'] as int?;

          // Usar el timestamp que esté disponible
          final messageTime = timestamp ?? localTimestamp;

          if (messageTime != null && messageTime < cutoffMillis) {
            keysToDelete.add(key.toString());
            deletedCount++;
          }
        }
      }

      // Eliminar mensajes viejos
      for (final key in keysToDelete) {
        await _messagesBox!.delete(key);
      }

      if (deletedCount > 0) {
      } else {
      }
    } catch (_) {
      // Silently ignored - cache errors should not crash the app
    }
  }

  /// Obtener todos los medios (imágenes y videos) del usuario desde el cache
  ///
  /// Parámetros:
  /// - userId: ID del usuario para filtrar solo sus mensajes
  /// - limit: Número máximo de medios a retornar (default: 100)
  ///
  /// Retorna lista de ChatMessage que contienen imageUrl o videoUrl
  Future<List<ChatMessage>> getAllUserMedia(String userId, {int limit = 100}) async {
    if (_messagesBox == null) return [];

    try {
      final mediaMessages = <ChatMessage>[];

      // Iterar sobre TODOS los mensajes en el cache
      for (final key in _messagesBox!.keys) {
        if (key.toString().startsWith('_')) continue; // Saltar keys de metadata

        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data == null) continue;

        // Filtrar por userId
        if (data['senderId'] != userId) continue;

        // Solo incluir mensajes con media
        final hasImage = data['imageUrl'] != null && data['imageUrl'].toString().isNotEmpty;
        final hasVideo = data['videoUrl'] != null && data['videoUrl'].toString().isNotEmpty;

        if (hasImage || hasVideo) {
          mediaMessages.add(_messageFromCacheData(data));
        }
      }

      // Ordenar por timestamp (más reciente primero)
      mediaMessages.sort((a, b) {
        final aTime = a.effectiveTimestamp;
        final bTime = b.effectiveTimestamp;
        return bTime.compareTo(aTime);
      });

      // Limitar resultados
      final limitedMessages = mediaMessages.take(limit).toList();

      return limitedMessages;
    } catch (e) {
      return [];
    }
  }

  /// Obtener todos los medios (imágenes y videos) de un chat específico desde el cache
  ///
  /// Parámetros:
  /// - chatId: ID del chat para filtrar mensajes
  /// - limit: Número máximo de medios a retornar (default: 100)
  ///
  /// Retorna lista de ChatMessage que contienen imageUrl o videoUrl
  Future<List<ChatMessage>> getChatMedia(String chatId, {int limit = 100}) async {
    if (_messagesBox == null) return [];

    try {
      final mediaMessages = <ChatMessage>[];

      // Iterar sobre los mensajes del chat específico
      // Las keys tienen formato: chatId_messageId
      for (final key in _messagesBox!.keys) {
        final keyStr = key.toString();

        // Saltar keys de metadata
        if (keyStr.startsWith('_')) continue;

        // Verificar si la key pertenece a este chat
        if (!keyStr.startsWith('${chatId}_')) continue;

        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data == null) continue;

        // Solo incluir mensajes con media (excluir audio)
        final hasImage = data['imageUrl'] != null && data['imageUrl'].toString().isNotEmpty;
        final hasVideo = data['videoUrl'] != null && data['videoUrl'].toString().isNotEmpty;

        if (hasImage || hasVideo) {
          mediaMessages.add(_messageFromCacheData(data));
        }
      }

      // Ordenar por timestamp (más reciente primero)
      mediaMessages.sort((a, b) {
        final aTime = a.effectiveTimestamp;
        final bTime = b.effectiveTimestamp;
        return bTime.compareTo(aTime);
      });

      // Limitar resultados
      final limitedMessages = mediaMessages.take(limit).toList();

      return limitedMessages;
    } catch (e) {
      return [];
    }
  }

  /// Cerrar la box al terminar
  Future<void> dispose() async {
    await _messagesBox?.close();
  }
}
