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

  /// Inicializar Hive y abrir la box
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _messagesBox = await Hive.openBox(_boxName);
      _isInitialized = true;

      // Ejecutar limpieza de mensajes viejos (máximo una vez al día)
      await _checkAndCleanupOldMessages();
    } catch (e) {
      // Silently fail - cache is optional
    }
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
    );
  }

  /// Cerrar la box
  Future<void> dispose() async {
    await _messagesBox?.close();
    _isInitialized = false;
  }
}
