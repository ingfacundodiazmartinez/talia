import '../../../../models/chat_message.dart';
import '../media_viewer_screen.dart';

/// Servicio que gestiona la construcción de galerías de medios del chat
class MediaGalleryService {
  /// Construye la galería de medios completa del chat y encuentra el índice actual
  static ({List<MediaItem> mediaItems, int initialIndex}) buildMediaGallery({
    required String? currentMediaUrl,
    required String currentMediaType,
    String? caption,
    List<ChatMessage>? allMessages,
  }) {
    final List<MediaItem> allMedia = [];

    // Si no hay URL actual (imagen optimista local), retornar lista vacía
    // Esto previene el crash con null check operator
    if (currentMediaUrl == null) {
      return (mediaItems: <MediaItem>[], initialIndex: 0);
    }

    // Si no hay mensajes, retornar solo el medio actual
    if (allMessages == null || allMessages.isEmpty) {
      return (
        mediaItems: [
          MediaItem(
            url: currentMediaUrl,
            type: currentMediaType,
            caption: caption,
          ),
        ],
        initialIndex: 0,
      );
    }

    // Extraer todos los medios de todos los mensajes
    for (var msg in allMessages) {
      if (msg.imageUrl != null) {
        allMedia.add(MediaItem(
          url: msg.imageUrl!,
          type: 'image',
          caption: msg.text,
        ));
      }
      if (msg.videoUrl != null) {
        allMedia.add(MediaItem(
          url: msg.videoUrl!,
          type: 'video',
          caption: msg.text,
        ));
      }
    }

    // Encontrar el índice del medio actual
    int initialIndex = 0;
    if (currentMediaUrl != null) {
      initialIndex = allMedia.indexWhere((item) => item.url == currentMediaUrl);
      if (initialIndex == -1) {
        // Si no se encontró, agregar el actual al inicio
        allMedia.insert(0, MediaItem(
          url: currentMediaUrl,
          type: currentMediaType,
          caption: caption,
        ));
        initialIndex = 0;
      }
    }

    return (mediaItems: allMedia, initialIndex: initialIndex);
  }
}
