import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../models/chat_message.dart';
import '../../../../services/message_cache_service.dart';
import '../../../chat/widgets/media_viewer_screen.dart' as viewer;

/// Widget que muestra la galería de medios compartidos (imágenes y videos)
/// desde el cache local (Hive)
/// Excluye audios grabados desde la app
///
/// Si se proporciona chatId, muestra solo los medios de ese chat.
/// Si no, muestra todos los medios del usuario.
class MediaGalleryWidget extends StatelessWidget {
  final String? userId; // Opcional si se usa chatId
  final String? chatId; // Opcional - para filtrar por chat específico
  final bool isOwnProfile;

  const MediaGalleryWidget({
    super.key,
    this.userId,
    this.chatId,
    this.isOwnProfile = false,
  }) : assert(userId != null || chatId != null, 'Debe proporcionar userId o chatId');

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return FutureBuilder<List<ChatMessage>>(
      future: _getMediaFromCache(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          // Error loading media gallery - handled by UI
          return const SizedBox.shrink();
        }

        final mediaMessages = snapshot.data ?? [];

        if (mediaMessages.isEmpty) {
          return _buildEmptyState(context, colorScheme);
        }

        // ✅ GridView con scroll independiente
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: mediaMessages.length,
          itemBuilder: (context, index) {
            return _buildMediaThumbnail(context, mediaMessages[index]);
          },
        );
      },
    );
  }

  /// Obtener medios desde el cache local
  Future<List<ChatMessage>> _getMediaFromCache() async {
    try {
      final cacheService = MessageCacheService();

      // Si hay chatId, obtener solo medios de ese chat
      if (chatId != null) {
        final mediaMessages = await cacheService.getChatMedia(chatId!, limit: 100);
        return mediaMessages;
      }

      // Si no, obtener todos los medios del usuario
      if (userId != null) {
        final mediaMessages = await cacheService.getAllUserMedia(userId!, limit: 100);
        return mediaMessages;
      }

      return [];
    } catch (e) {
      // Error getting media from cache - return empty list
      return [];
    }
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            'Sin fotos o videos',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isOwnProfile
                ? 'Las fotos y videos que compartas aparecerán aquí'
                : 'No hay archivos multimedia compartidos',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaThumbnail(BuildContext context, ChatMessage message) {
    final hasImage = message.imageUrl != null && message.imageUrl!.isNotEmpty;
    final hasVideo = message.videoUrl != null && message.videoUrl!.isNotEmpty;

    if (!hasImage && !hasVideo) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () {
        _openMediaViewer(context, message);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: hasVideo
                ? _buildVideoThumbnail(message)
                : _buildImageThumbnail(message),
          ),

          // Overlay de video
          if (hasVideo)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 16,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImageThumbnail(ChatMessage message) {
    return CachedNetworkImage(
      imageUrl: message.imageUrl!,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(
        color: Colors.grey.shade200,
        child: const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      errorWidget: (context, url, error) => Container(
        color: Colors.grey.shade300,
        child: const Icon(Icons.error),
      ),
    );
  }

  Widget _buildVideoThumbnail(ChatMessage message) {
    // Usar el videoUrl para el thumbnail
    final thumbnailUrl = message.videoUrl;

    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: thumbnailUrl,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          color: Colors.grey.shade200,
          child: const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        errorWidget: (context, url, error) => Container(
          color: Colors.black,
          child: const Center(
            child: Icon(
              Icons.play_circle_outline,
              color: Colors.white,
              size: 40,
            ),
          ),
        ),
      );
    }

    return Container(
      color: Colors.black,
      child: const Center(
        child: Icon(
          Icons.play_circle_outline,
          color: Colors.white,
          size: 40,
        ),
      ),
    );
  }

  void _openMediaViewer(BuildContext context, ChatMessage message) {
    final hasVideo = message.videoUrl != null && message.videoUrl!.isNotEmpty;

    // Convertir ChatMessage al formato de MediaViewerScreen
    final mediaItem = viewer.MediaItem(
      url: hasVideo ? message.videoUrl! : message.imageUrl!,
      type: hasVideo ? 'video' : 'image',
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => viewer.MediaViewerScreen(
          mediaItems: [mediaItem],
          initialIndex: 0,
        ),
      ),
    );
  }
}
