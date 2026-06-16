import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/group_message.dart';

/// Servicio para cachear mensajes de grupo localmente usando Hive
///
/// Responsabilidades:
/// - Guardar mensajes de grupo en cache local persistente
/// - Recuperar TODOS los mensajes del cache (sin límite)
/// - La consulta a Firestore solo sincroniza los últimos 50
class GroupMessageCacheService {
  static final GroupMessageCacheService _instance = GroupMessageCacheService._internal();
  factory GroupMessageCacheService() => _instance;
  GroupMessageCacheService._internal();

  static const String _boxName = 'group_messages_cache';

  Box? _messagesBox;
  bool _isInitialized = false;

  // ═══════════════════════════════════════════════════════════════════
  // LAST MESSAGE INDEX (in-memory) — para preview en chat list.
  // ═══════════════════════════════════════════════════════════════════
  final Map<String, GroupMessage> _lastMessageByGroup = {};
  final StreamController<String> _lastMessageChangeController =
      StreamController<String>.broadcast();

  Stream<String> get lastMessageChanges => _lastMessageChangeController.stream;

  /// Obtener el último mensaje cacheado para un grupo (O(1)).
  GroupMessage? getLastMessage(String groupId) => _lastMessageByGroup[groupId];

  /// Seed IDEMPOTENTE del preview (solo índice en memoria, sin tocar el box).
  /// Siembra/emite solo si es un mensaje genuinamente más nuevo; no-op si el
  /// último ya es este mismo id. Se usa para sembrar desde el payload del FCM
  /// (que llega antes que el listener de la subcolección).
  void seedLastMessageIfNewer(String groupId, GroupMessage message) {
    final current = _lastMessageByGroup[groupId];
    if (current != null && current.id == message.id) return; // ya está
    if (current == null || message.timestamp.isAfter(current.timestamp)) {
      _lastMessageByGroup[groupId] = message;
      if (!_lastMessageChangeController.isClosed) {
        _lastMessageChangeController.add(groupId);
      }
    }
  }

  /// Stream del último mensaje. Emite el valor actual y luego cambios.
  Stream<GroupMessage?> watchLastMessage(String groupId) async* {
    yield getLastMessage(groupId);
    yield* lastMessageChanges
        .where((id) => id == groupId)
        .map((_) => getLastMessage(groupId));
  }

  void _maybeUpdateLastMessage(String groupId, GroupMessage msg, {bool notify = true}) {
    final current = _lastMessageByGroup[groupId];

    // 🗑️ Un mensaje eliminado no debe quedar como "último mensaje".
    if (msg.isDeleted) {
      if (current != null && current.id == msg.id) {
        _recomputeLastMessageExcludingDeleted(groupId, notify: notify);
      }
      return;
    }

    if (current == null ||
        msg.timestamp.isAfter(current.timestamp) ||
        msg.id == current.id) {
      _lastMessageByGroup[groupId] = msg;
      if (notify && !_lastMessageChangeController.isClosed) {
        _lastMessageChangeController.add(groupId);
      }
    }
  }

  /// Recalcular (sync) el último mensaje NO eliminado del grupo.
  void _recomputeLastMessageExcludingDeleted(String groupId, {bool notify = true}) {
    if (_messagesBox == null) {
      _lastMessageByGroup.remove(groupId);
      return;
    }
    GroupMessage? best;
    final prefix = '${groupId}_';
    for (final raw in _messagesBox!.keys) {
      final key = raw.toString();
      if (key.startsWith('_') || !key.startsWith(prefix)) continue;
      final data = _messagesBox!.get(raw) as Map<dynamic, dynamic>?;
      if (data == null) continue;
      if (data['isDeleted'] == true) continue;
      final msgId = data['id'] as String?;
      if (msgId == null || !key.endsWith('_$msgId')) continue;
      try {
        final m = _messageFromMap(data);
        if (best == null || m.timestamp.isAfter(best.timestamp)) best = m;
      } catch (_) {}
    }
    if (best != null) {
      _lastMessageByGroup[groupId] = best;
    } else {
      _lastMessageByGroup.remove(groupId);
    }
    if (notify && !_lastMessageChangeController.isClosed) {
      _lastMessageChangeController.add(groupId);
    }
  }

  /// Inicializar Hive y abrir la box
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _messagesBox = await Hive.openBox(_boxName);
      _isInitialized = true;

      _rebuildLastMessageIndex();

      // Ejecutar limpieza de mensajes viejos (máximo una vez al día)
      await _checkAndCleanupOldMessages();
    } catch (e) {
      // Silently fail - cache is optional
    }
  }

  void _rebuildLastMessageIndex() {
    if (_messagesBox == null) return;
    _lastMessageByGroup.clear();
    try {
      for (final raw in _messagesBox!.keys) {
        final key = raw.toString();
        if (key.startsWith('_')) continue; // metadata
        final data = _messagesBox!.get(raw) as Map<dynamic, dynamic>?;
        if (data == null) continue;
        // Derivar groupId quitando el sufijo '_<id>' (mismo criterio que
        // MessageCacheService: no cortar en el primer '_').
        final msgId = data['id'] as String?;
        if (msgId == null || msgId.isEmpty || !key.endsWith('_$msgId')) continue;
        final groupId = key.substring(0, key.length - msgId.length - 1);
        if (groupId.isEmpty) continue;
        try {
          final msg = _messageFromMap(data);
          _maybeUpdateLastMessage(groupId, msg, notify: false);
        } catch (_) {
          // mensaje corrupto en cache — saltar.
        }
      }
    } catch (_) {}
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
        await _messagesBox!.put(lastCleanupKey, now);
      }
    } catch (e) {
      // Silently fail
    }
  }

  /// Guardar un mensaje en el cache
  Future<void> saveMessage(String groupId, GroupMessage message) async {
    await initialize();
    if (_messagesBox == null) return;

    try {
      final key = '${groupId}_${message.id}';
      final data = _messageToMap(message);
      await _messagesBox!.put(key, data);
      _maybeUpdateLastMessage(groupId, message);
    } catch (e) {
      // Silently fail
    }
  }

  /// Guardar múltiples mensajes (más eficiente)
  Future<void> saveMessages(String groupId, List<GroupMessage> messages) async {
    await initialize();
    if (_messagesBox == null) return;

    try {
      final entries = <String, Map<String, dynamic>>{};

      for (final message in messages) {
        final key = '${groupId}_${message.id}';
        entries[key] = _messageToMap(message);
      }

      await _messagesBox!.putAll(entries);
      for (final m in messages) {
        _maybeUpdateLastMessage(groupId, m);
      }
    } catch (e) {
      // Silently fail
    }
  }

  /// Recuperar TODOS los mensajes del cache para un grupo
  Future<List<GroupMessage>> getMessages(String groupId) async {
    await initialize();
    if (_messagesBox == null) return [];

    try {
      final messages = <GroupMessage>[];
      final prefix = '${groupId}_';

      for (final key in _messagesBox!.keys) {
        final keyStr = key.toString();
        if (keyStr.startsWith('_')) continue; // Saltar metadata
        if (!keyStr.startsWith(prefix)) continue;

        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data != null) {
          try {
            messages.add(_messageFromMap(data));
          } catch (e) {
            // Skip malformed message
          }
        }
      }

      // Ordenar por timestamp (más reciente primero)
      messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return messages;
    } catch (e) {
      return [];
    }
  }

  /// Actualizar un mensaje en el cache
  Future<void> updateMessage(String groupId, GroupMessage message) async {
    await saveMessage(groupId, message);
  }

  /// Eliminar mensaje del cache
  Future<void> deleteMessage(String groupId, String messageId) async {
    await initialize();
    if (_messagesBox == null) return;

    try {
      final key = '${groupId}_$messageId';
      await _messagesBox!.delete(key);
    } catch (e) {
      // Silently fail
    }
  }

  /// Limpiar todos los mensajes de un grupo
  Future<void> clearGroup(String groupId) async {
    await initialize();
    if (_messagesBox == null) return;

    try {
      final prefix = '${groupId}_';
      final keysToDelete = _messagesBox!.keys
          .where((key) => key.toString().startsWith(prefix))
          .toList();

      for (final key in keysToDelete) {
        await _messagesBox!.delete(key);
      }
    } catch (e) {
      // Silently fail
    }
  }

  /// Limpiar mensajes más viejos de 7 días
  Future<void> cleanupOldMessages({int daysToKeep = 7}) async {
    if (_messagesBox == null) return;

    try {
      final cutoffDate = DateTime.now().subtract(Duration(days: daysToKeep));
      final cutoffMillis = cutoffDate.millisecondsSinceEpoch;

      final keysToDelete = <String>[];

      for (final key in _messagesBox!.keys) {
        final keyStr = key.toString();
        if (keyStr.startsWith('_')) continue; // Saltar metadata

        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data != null) {
          final timestamp = data['timestamp'] as int?;
          if (timestamp != null && timestamp < cutoffMillis) {
            keysToDelete.add(keyStr);
          }
        }
      }

      for (final key in keysToDelete) {
        await _messagesBox!.delete(key);
      }
    } catch (e) {
      // Silently fail
    }
  }

  /// Convertir mensaje a Map para almacenar
  Map<String, dynamic> _messageToMap(GroupMessage message) {
    return {
      'id': message.id,
      'senderId': message.senderId,
      'senderName': message.senderName,
      'senderPhotoURL': message.senderPhotoURL,
      'text': message.text,
      'imageUrl': message.imageUrl,
      'videoUrl': message.videoUrl,
      'audioUrl': message.audioUrl,
      'thumbnailUrl': message.thumbnailUrl,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'editedAt': message.editedAt?.millisecondsSinceEpoch,
      'isDeleted': message.isDeleted,
      'reactions': message.reactions.map((k, v) => MapEntry(k, v)),
      'readBy': message.readBy,
      // ReplyTo
      'replyTo': message.replyTo != null
          ? {
              'messageId': message.replyTo!.messageId,
              'senderId': message.replyTo!.senderId,
              'senderName': message.replyTo!.senderName,
              'text': message.replyTo!.text,
              'hasMedia': message.replyTo!.hasMedia,
            }
          : null,
      // ✅ FIX #8: Campos de reenvío
      'isForwarded': message.isForwarded,
      'originalSenderId': message.originalSenderId,
      'originalChatId': message.originalChatId,
      'originalContactName': message.originalContactName,
      // ✅ FIX: Campos de moderación
      'moderationStatus': message.moderationStatus,
      'moderationReason': message.moderationReason,
      'localId': message.localId,
      // ✅ Visibilidad por destinatario
      'visibleTo': message.visibleTo,
      // ✅ Ubicación
      'latitude': message.latitude,
      'longitude': message.longitude,
      'isLiveLocation': message.isLiveLocation,
      'liveLocationExpiresAt':
          message.liveLocationExpiresAt?.millisecondsSinceEpoch,
    };
  }

  /// Convertir Map a GroupMessage
  GroupMessage _messageFromMap(Map<dynamic, dynamic> data) {
    // Parse reactions
    final reactionsMap = <String, List<String>>{};
    final rawReactions = data['reactions'] as Map<dynamic, dynamic>? ?? {};
    for (final entry in rawReactions.entries) {
      final emoji = entry.key.toString();
      final users = (entry.value as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      reactionsMap[emoji] = users;
    }

    // Parse replyTo
    ReplyPreview? replyTo;
    final replyData = data['replyTo'] as Map<dynamic, dynamic>?;
    if (replyData != null) {
      replyTo = ReplyPreview(
        messageId: replyData['messageId'] as String? ?? '',
        senderId: replyData['senderId'] as String? ?? '',
        senderName: replyData['senderName'] as String? ?? '',
        text: replyData['text'] as String?,
        hasMedia: replyData['hasMedia'] as bool? ?? false,
      );
    }

    return GroupMessage(
      id: data['id'] as String,
      senderId: data['senderId'] as String,
      senderName: data['senderName'] as String? ?? 'Usuario',
      senderPhotoURL: data['senderPhotoURL'] as String?,
      text: data['text'] as String?,
      imageUrl: data['imageUrl'] as String?,
      videoUrl: data['videoUrl'] as String?,
      audioUrl: data['audioUrl'] as String?,
      thumbnailUrl: data['thumbnailUrl'] as String?,
      replyTo: replyTo,
      timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
      editedAt: data['editedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['editedAt'] as int)
          : null,
      isDeleted: data['isDeleted'] as bool? ?? false,
      reactions: reactionsMap,
      readBy: (data['readBy'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      // ✅ FIX #8: Campos de reenvío
      isForwarded: data['isForwarded'] as bool? ?? false,
      originalSenderId: data['originalSenderId'] as String?,
      originalChatId: data['originalChatId'] as String?,
      originalContactName: data['originalContactName'] as String?,
      // ✅ FIX: Campos de moderación
      moderationStatus: data['moderationStatus'] as String?,
      moderationReason: data['moderationReason'] as String?,
      localId: data['localId'] as String?,
      // ✅ Visibilidad por destinatario
      visibleTo: data['visibleTo'] != null
          ? List<String>.from(data['visibleTo'] as List)
          : null,
      // ✅ Ubicación
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      isLiveLocation: data['isLiveLocation'] as bool? ?? false,
      liveLocationExpiresAt: data['liveLocationExpiresAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              data['liveLocationExpiresAt'] as int)
          : null,
    );
  }

  /// Cerrar la box
  Future<void> dispose() async {
    await _messagesBox?.close();
    _isInitialized = false;
  }
}
