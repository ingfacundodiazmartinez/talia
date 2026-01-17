import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/release_logger.dart';

/// Servicio para cachear datos que la Share Extension necesita leer
///
/// La Share Extension de iOS no tiene acceso a Firebase, así que
/// necesitamos cachear los chats en el App Group para que pueda mostrarlos.
class ShareExtensionCacheService {
  static final ShareExtensionCacheService _instance =
      ShareExtensionCacheService._internal();
  factory ShareExtensionCacheService() => _instance;
  ShareExtensionCacheService._internal();

  static const _channel = MethodChannel('com.talia.chat/share_cache');

  /// Cachear lista de chats para la Share Extension
  ///
  /// Llamar esto cuando:
  /// - El usuario inicia sesión
  /// - Se actualiza la lista de chats
  /// - Periódicamente (cada vez que se abre la app)
  Future<void> cacheChats(List<CachedChatData> chats) async {
    if (!Platform.isIOS) return;

    try {
      final jsonList = chats.map((c) => c.toJson()).toList();
      final jsonString = jsonEncode(jsonList);

      final success = await _channel.invokeMethod<bool>('cacheChats', jsonString);

      if (success == true) {
        ReleaseLogger.log(
          '📤 [ShareCache] Cached ${chats.length} chats to App Group',
          tag: 'ShareCache',
        );
      } else {
        ReleaseLogger.error(
          '📤 [ShareCache] Failed to cache chats',
          tag: 'ShareCache',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareCache] Error caching chats: $e',
        tag: 'ShareCache',
      );
    }
  }

  /// Verificar si hay un share pendiente de la extensión
  Future<PendingShareData?> getPendingShare() async {
    if (!Platform.isIOS) return null;

    try {
      final jsonString = await _channel.invokeMethod<String>('getPendingShare');

      if (jsonString == null || jsonString.isEmpty) {
        return null;
      }

      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      ReleaseLogger.log(
        '📤 [ShareCache] Found pending share',
        tag: 'ShareCache',
      );
      return PendingShareData.fromJson(json);
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareCache] Error getting pending share: $e',
        tag: 'ShareCache',
      );
      return null;
    }
  }

  /// Limpiar share pendiente después de procesarlo
  Future<void> clearPendingShare() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('clearPendingShare');
      ReleaseLogger.log(
        '📤 [ShareCache] Cleared pending share',
        tag: 'ShareCache',
      );
    } catch (e) {
      ReleaseLogger.error(
        '📤 [ShareCache] Error clearing pending share: $e',
        tag: 'ShareCache',
      );
    }
  }
}

/// Datos de chat cacheados para la Share Extension
class CachedChatData {
  final String id;
  final String name;
  final String? photoURL;
  final bool isGroup;
  final String? lastMessage;
  final double? lastMessageTime;

  CachedChatData({
    required this.id,
    required this.name,
    this.photoURL,
    required this.isGroup,
    this.lastMessage,
    this.lastMessageTime,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'photoURL': photoURL,
        'isGroup': isGroup,
        'lastMessage': lastMessage,
        'lastMessageTime': lastMessageTime,
      };
}

/// Datos de share pendiente desde la extensión
class PendingShareData {
  final List<String> chatIds;
  final List<PendingShareItem> items;
  final double timestamp;

  PendingShareData({
    required this.chatIds,
    required this.items,
    required this.timestamp,
  });

  factory PendingShareData.fromJson(Map<String, dynamic> json) {
    return PendingShareData(
      chatIds: List<String>.from(json['chatIds'] ?? []),
      items: (json['items'] as List?)
              ?.map((item) =>
                  PendingShareItem.fromJson(item as Map<String, dynamic>))
              .toList() ??
          [],
      timestamp: (json['timestamp'] as num?)?.toDouble() ?? 0,
    );
  }
}

class PendingShareItem {
  final String type;
  final String? path;
  final String? text;

  PendingShareItem({
    required this.type,
    this.path,
    this.text,
  });

  factory PendingShareItem.fromJson(Map<String, dynamic> json) {
    return PendingShareItem(
      type: json['type'] ?? 'text',
      path: json['path'],
      text: json['text'],
    );
  }
}
