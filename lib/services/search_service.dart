import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import 'message_cache_service.dart';

/// Servicio para buscar en chats y mensajes con normalización de texto
class SearchService {
  final MessageCacheService _cacheService = MessageCacheService();

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
      // Obtener mensajes del caché
      final messages = await _cacheService.getMessages(chatId);
      final results = <MessageSearchResult>[];

      // Buscar en cada mensaje
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

      return results;
    } catch (e) {
      print('❌ Error buscando en mensajes del chat $chatId: $e');
      return [];
    }
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
