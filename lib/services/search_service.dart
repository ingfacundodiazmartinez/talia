import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../groups/services/group_message_cache_service.dart';
import '../utils/release_logger.dart';
import 'message_cache_service.dart';
import 'user_cache_service.dart';
import 'user_profile_cache_service.dart';

/// Servicio para buscar en chats y mensajes con normalización de texto
class SearchService {
  final MessageCacheService _cacheService = MessageCacheService();
  final GroupMessageCacheService _groupCacheService = GroupMessageCacheService();
  final UserProfileCacheService _userProfileService = UserProfileCacheService();
  final UserCacheService _userCacheService = UserCacheService();

  /// Normaliza texto removiendo acentos y convirtiéndolo a minúsculas
  /// Ejemplo: "Fábrica" -> "fabrica"
  String normalizeText(String text) {
    const withAccents = 'áéíóúàèìòùâêîôûãõäëïöüçñÁÉÍÓÚÀÈÌÒÙÂÊÎÔÛÃÕÄËÏÖÜÇÑ';
    const withoutAccents = 'aeiouaeiouaeiouaoaeioucnAEIOUAEIOUAEIOUAOAEIOUCN';

    String normalized = text.toLowerCase();

    for (int i = 0; i < withAccents.length; i++) {
      normalized = normalized.replaceAll(
        withAccents[i],
        withoutAccents[i].toLowerCase(),
      );
    }

    return normalized;
  }

  /// Verifica si un texto contiene la query (ambos normalizados)
  bool matchesQuery(String text, String query) {
    if (query.isEmpty) return true;
    return normalizeText(text).contains(normalizeText(query));
  }

  /// Busca en los mensajes cacheados de un chat específico
  Future<List<MessageSearchResult>> searchInChatMessages({
    required String chatId,
    required String query,
    required String chatName,
    required String? chatPhotoUrl,
    required ChatType chatType,
  }) async {
    if (query.isEmpty) return [];

    try {
      final results = <MessageSearchResult>[];

      // Usar el cache correcto según el tipo de chat
      if (chatType == ChatType.group) {
        // Buscar en cache de grupos
        final groupMessages = await _groupCacheService.getMessages(chatId);

        for (final message in groupMessages) {
          // Solo buscar en mensajes de texto no eliminados
          if (message.text != null && message.text!.isNotEmpty && !message.isDeleted) {
            if (matchesQuery(message.text!, query)) {
              // Convertir GroupMessage a ChatMessage para el resultado
              final chatMessage = ChatMessage(
                id: message.id,
                senderId: message.senderId,
                text: message.text,
                imageUrl: message.imageUrl,
                videoUrl: message.videoUrl,
                audioUrl: message.audioUrl,
                timestamp: Timestamp.fromDate(message.timestamp),
                isRead: true,
                status: MessageStatus.sent,
              );

              results.add(MessageSearchResult(
                chatId: chatId,
                chatName: chatName,
                chatPhotoUrl: chatPhotoUrl,
                message: chatMessage,
                query: query,
                chatType: chatType,
              ));
            }
          }
        }
      } else {
        // Buscar en cache de chats directos
        final messages = await _cacheService.getMessages(chatId);

        for (final message in messages) {
          // Solo buscar en mensajes de texto
          if (message.text != null && message.text!.isNotEmpty) {
            if (matchesQuery(message.text!, query)) {
              results.add(MessageSearchResult(
                chatId: chatId,
                chatName: chatName,
                chatPhotoUrl: chatPhotoUrl,
                message: message,
                query: query,
                chatType: chatType,
              ));
            }
          }
        }
      }

      return results;
    } catch (e) {
      ReleaseLogger.error('Error buscando en mensajes de $chatId: $e', tag: 'SearchService');
      return [];
    }
  }

  /// Buscar en mensajes de todos los chats y grupos
  /// Retorna resultados por nombre de chat/grupo y por contenido de mensajes
  Future<SearchResults> performMessageSearch({
    required String query,
    required String currentUserId,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> groups,
  }) async {
    if (query.isEmpty) {
      return SearchResults(chatResults: [], messageResults: []);
    }

    final chatResults = <ChatSearchResult>[];
    final messageResults = <MessageSearchResult>[];

    // Buscar en chats directos
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final chatId = chatDoc.id;
      final participants = chatData['participants'] as List<dynamic>?;

      if (participants == null) continue;

      final otherUserId = participants.firstWhere(
        (id) => id != currentUserId,
        orElse: () => null,
      );

      if (otherUserId == null) continue;

      try {
        // Obtener datos del usuario
        final userData = await _userProfileService.getUserProfile(otherUserId);
        if (userData == null) continue;

        final userName = userData['name'] ?? 'Usuario';
        final photoURL = userData['photoURL'] as String?;

        // ✅ FIX: Obtener alias del usuario para búsqueda
        final displayName = _userCacheService.getDisplayName(otherUserId, fallback: userName);
        final cachedData = _userCacheService.getUserDataSync(otherUserId);
        final alias = cachedData?['alias'] as String?;

        // ✅ FIX: Verificar si coincide por nombre O por alias
        final matchesByName = matchesQuery(userName, query);
        final matchesByAlias = alias != null && alias.isNotEmpty && matchesQuery(alias, query);
        final matchesByDisplayName = matchesQuery(displayName, query);

        if (matchesByName || matchesByAlias || matchesByDisplayName) {
          chatResults.add(
            ChatSearchResult(
              chatId: chatId,
              chatName: displayName, // ✅ Usar displayName (prioriza alias)
              chatPhotoUrl: photoURL,
              chatType: ChatType.direct,
            ),
          );
        }

        // Buscar en mensajes del chat
        final chatMessageResults = await searchInChatMessages(
          chatId: chatId,
          query: query,
          chatName: displayName, // ✅ Usar displayName
          chatPhotoUrl: photoURL,
          chatType: ChatType.direct,
        );
        messageResults.addAll(chatMessageResults);
      } catch (e) {
        ReleaseLogger.error('Error buscando en chat $chatId: $e', tag: 'SearchService');
      }
    }

    // Buscar en grupos
    for (final groupDoc in groups) {
      final groupData = groupDoc.data() as Map<String, dynamic>;
      final groupId = groupDoc.id;
      final groupName = groupData['name'] ?? 'Grupo';
      final avatar = groupData['avatar'] as String?;

      // Verificar si coincide por nombre
      if (matchesQuery(groupName, query)) {
        chatResults.add(
          ChatSearchResult(
            chatId: groupId,
            chatName: groupName,
            chatPhotoUrl: avatar,
            chatType: ChatType.group,
          ),
        );
      }

      // Buscar en mensajes del grupo
      try {
        final groupMessageResults = await searchInChatMessages(
          chatId: groupId,
          query: query,
          chatName: groupName,
          chatPhotoUrl: avatar,
          chatType: ChatType.group,
        );
        messageResults.addAll(groupMessageResults);
      } catch (e) {
        ReleaseLogger.error('Error buscando en grupo $groupId: $e', tag: 'SearchService');
      }
    }

    return SearchResults(
      chatResults: chatResults,
      messageResults: messageResults,
    );
  }
}

/// Resultado de búsqueda en un chat (por nombre)
class ChatSearchResult {
  final String chatId;
  final String chatName;
  final String? chatPhotoUrl;
  final ChatType chatType;
  final bool isArchived;

  ChatSearchResult({
    required this.chatId,
    required this.chatName,
    this.chatPhotoUrl,
    required this.chatType,
    this.isArchived = false,
  });
}

/// Resultado de búsqueda en un mensaje
class MessageSearchResult {
  final String chatId;
  final String chatName;
  final String? chatPhotoUrl;
  final ChatMessage message;
  final String query;
  final ChatType chatType;

  MessageSearchResult({
    required this.chatId,
    required this.chatName,
    this.chatPhotoUrl,
    required this.message,
    required this.query,
    required this.chatType,
  });

  /// Obtiene el texto del mensaje con el término de búsqueda resaltado
  /// Retorna una lista de TextSpan para construir un RichText
  List<TextSpan> getHighlightedTextSpans(BuildContext context) {
    final text = message.text ?? '';
    final searchService = SearchService();
    final normalizedText = searchService.normalizeText(text);
    final normalizedQuery = searchService.normalizeText(query);

    if (!normalizedText.contains(normalizedQuery)) {
      return [TextSpan(text: text)];
    }

    final spans = <TextSpan>[];
    int currentIndex = 0;

    while (currentIndex < text.length) {
      // Buscar la siguiente ocurrencia
      final normalizedRemaining = searchService.normalizeText(
        text.substring(currentIndex),
      );
      final matchIndex = normalizedRemaining.indexOf(normalizedQuery);

      if (matchIndex == -1) {
        // No hay más coincidencias, agregar el resto del texto
        spans.add(TextSpan(
          text: text.substring(currentIndex),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
          ),
        ));
        break;
      }

      // Agregar texto antes de la coincidencia
      final actualMatchIndex = currentIndex + matchIndex;
      if (actualMatchIndex > currentIndex) {
        spans.add(TextSpan(
          text: text.substring(currentIndex, actualMatchIndex),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
          ),
        ));
      }

      // Agregar el término coincidente en negrita
      final matchEnd = actualMatchIndex + query.length;
      spans.add(TextSpan(
        text: text.substring(actualMatchIndex, matchEnd),
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ));

      currentIndex = matchEnd;
    }

    return spans;
  }

  /// Trunca el texto del mensaje si es muy largo
  /// Mantiene contexto alrededor del término buscado
  String getTruncatedText({int maxLength = 150}) {
    final text = message.text ?? '';
    if (text.length <= maxLength) return text;

    final searchService = SearchService();
    final normalizedText = searchService.normalizeText(text);
    final normalizedQuery = searchService.normalizeText(query);
    final matchIndex = normalizedText.indexOf(normalizedQuery);

    if (matchIndex == -1) {
      // Si no encuentra coincidencia, truncar desde el inicio
      return '${text.substring(0, maxLength)}...';
    }

    // Calcular contexto alrededor de la coincidencia
    final contextLength = (maxLength - query.length) ~/ 2;
    int start = (matchIndex - contextLength).clamp(0, text.length);
    int end = (matchIndex + query.length + contextLength).clamp(0, text.length);

    // Ajustar para no cortar palabras a la mitad
    if (start > 0) {
      // Buscar el inicio de la palabra
      while (start > 0 && text[start - 1] != ' ') {
        start--;
      }
    }

    if (end < text.length) {
      // Buscar el final de la palabra
      while (end < text.length && text[end] != ' ') {
        end++;
      }
    }

    String truncated = text.substring(start, end);
    if (start > 0) truncated = '...$truncated';
    if (end < text.length) truncated = '$truncated...';

    return truncated;
  }
}

/// Tipo de chat para diferenciar en resultados
enum ChatType {
  direct,  // Chat 1-1
  group,   // Chat grupal
  child,   // Chat con hijo
}

/// Resultado consolidado de búsqueda (chats + mensajes)
class SearchResults {
  final List<ChatSearchResult> chatResults;
  final List<MessageSearchResult> messageResults;

  SearchResults({
    required this.chatResults,
    required this.messageResults,
  });

  bool get isEmpty => chatResults.isEmpty && messageResults.isEmpty;

  int get totalCount => chatResults.length + messageResults.length;
}
