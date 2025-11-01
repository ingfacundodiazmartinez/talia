import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/chat_message.dart';

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

  /// Inicializar Hive y abrir la box
  Future<void> initialize() async {
    try {
      await Hive.initFlutter();
      _messagesBox = await Hive.openBox(_boxName);
      print('✅ [MessageCacheService] Inicializado correctamente');

      // Ejecutar limpieza de mensajes viejos (si es necesario)
      await _checkAndCleanupOldMessages();
    } catch (e) {
      print('❌ [MessageCacheService] Error inicializando: $e');
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
        print('🧹 [MessageCacheService] Ejecutando limpieza programada...');
        await cleanupOldMessages();

        // Guardar timestamp de esta limpieza
        await _messagesBox!.put(lastCleanupKey, now);
      } else {
        final nextCleanup = Duration(milliseconds: 24 * 60 * 60 * 1000 - (now - lastCleanup));
        print('⏭️ [MessageCacheService] Próxima limpieza en ${nextCleanup.inHours} horas');
      }
    } catch (e) {
      print('❌ [MessageCacheService] Error verificando limpieza: $e');
    }
  }

  /// Guardar un mensaje en el cache
  Future<void> saveMessage(String chatId, ChatMessage message) async {
    if (_messagesBox == null) return;

    try {
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
      };

      await _messagesBox!.put(key, data);

      // Limpiar mensajes viejos si excedemos el límite
      await _cleanOldMessages(chatId);
    } catch (e) {
      print('❌ [MessageCacheService] Error guardando mensaje: $e');
    }
  }

  /// Guardar múltiples mensajes
  Future<void> saveMessages(String chatId, List<ChatMessage> messages) async {
    if (_messagesBox == null) return;

    try {
      final entries = <String, Map<String, dynamic>>{};

      for (final message in messages) {
        final key = '${chatId}_${message.id}';
        entries[key] = {
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
        };
      }

      await _messagesBox!.putAll(entries);
      await _cleanOldMessages(chatId);

      print('✅ [MessageCacheService] Guardados ${messages.length} mensajes para chat $chatId');
    } catch (e) {
      print('❌ [MessageCacheService] Error guardando mensajes: $e');
    }
  }

  /// Recuperar mensajes del cache para un chat
  Future<List<ChatMessage>> getMessages(String chatId) async {
    if (_messagesBox == null) return [];

    try {
      final messages = <ChatMessage>[];
      final keys = _messagesBox!.keys.where((key) => key.toString().startsWith(chatId));

      for (final key in keys) {
        final data = _messagesBox!.get(key) as Map<dynamic, dynamic>?;
        if (data != null) {
          messages.add(_messageFromCacheData(data));
        }
      }

      // Ordenar por timestamp (más reciente primero)
      messages.sort((a, b) {
        final aTime = a.effectiveTimestamp;
        final bTime = b.effectiveTimestamp;
        return bTime.compareTo(aTime);
      });

      print('📥 [MessageCacheService] Recuperados ${messages.length} mensajes del cache para chat $chatId');
      return messages;
    } catch (e) {
      print('❌ [MessageCacheService] Error recuperando mensajes: $e');
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
      }
    } catch (e) {
      print('❌ [MessageCacheService] Error actualizando estado: $e');
    }
  }

  /// Eliminar mensaje del cache
  Future<void> deleteMessage(String chatId, String messageId) async {
    if (_messagesBox == null) return;

    try {
      final key = '${chatId}_$messageId';
      await _messagesBox!.delete(key);
    } catch (e) {
      print('❌ [MessageCacheService] Error eliminando mensaje: $e');
    }
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

        print('🗑️ [MessageCacheService] Eliminados ${toDelete.length} mensajes viejos');
      }
    } catch (e) {
      print('❌ [MessageCacheService] Error limpiando mensajes viejos: $e');
    }
  }

  /// Limpiar todos los mensajes de un chat
  Future<void> clearChat(String chatId) async {
    if (_messagesBox == null) return;

    try {
      final keys = _messagesBox!.keys
          .where((key) => key.toString().startsWith(chatId))
          .toList();

      for (final key in keys) {
        await _messagesBox!.delete(key);
      }

      print('🗑️ [MessageCacheService] Cache limpiado para chat $chatId');
    } catch (e) {
      print('❌ [MessageCacheService] Error limpiando cache: $e');
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
    );
  }

  /// Parsear estado del mensaje desde string
  MessageStatus _parseMessageStatus(String? status) {
    switch (status) {
      case 'sending':
        return MessageStatus.sending;
      case 'error':
        return MessageStatus.error;
      default:
        return MessageStatus.sent;
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
        print('🗑️ [MessageCacheService] Limpiados $deletedCount mensajes más viejos de $daysToKeep días');
      } else {
        print('✅ [MessageCacheService] No hay mensajes viejos que limpiar');
      }
    } catch (e) {
      print('❌ [MessageCacheService] Error limpiando mensajes viejos: $e');
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

      print('📸 [MessageCacheService] Recuperados ${limitedMessages.length} medios del usuario $userId desde cache');
      return limitedMessages;
    } catch (e) {
      print('❌ [MessageCacheService] Error recuperando medios del usuario: $e');
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

      print('📸 [MessageCacheService] Recuperados ${limitedMessages.length} medios del chat $chatId desde cache');
      return limitedMessages;
    } catch (e) {
      print('❌ [MessageCacheService] Error recuperando medios del chat: $e');
      return [];
    }
  }

  /// Cerrar la box al terminar
  Future<void> dispose() async {
    await _messagesBox?.close();
  }
}
