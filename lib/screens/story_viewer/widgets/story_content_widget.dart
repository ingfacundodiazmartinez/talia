import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/story.dart';
import '../../../controllers/story_viewer_controller.dart';
import 'package:video_player/video_player.dart';

/// Widget que maneja el contenido principal de las historias
///
/// Responsabilidades:
/// - Mostrar PageView de usuarios y sus historias
/// - Manejar videos e imágenes
/// - Gestionar carga y precarga de contenido
class StoryContentWidget extends StatelessWidget {
  final PageController userPageController;
  final PageController? storyPageController;
  final List<UserStories> allUserStories;
  final int currentUserIndex;
  final int currentStoryIndex;
  final bool isCurrentStoryLoaded;
  final Map<String, VideoPlayerController> videoControllers;
  final VoidCallback onStoryLoaded;
  final Function(int) onUserChanged;
  final Function(int) onStoryChanged;
  final StoryViewerController controller;
  final Widget Function(Story) buildVideoPlayer;

  const StoryContentWidget({
    super.key,
    required this.userPageController,
    required this.storyPageController,
    required this.allUserStories,
    required this.currentUserIndex,
    required this.currentStoryIndex,
    required this.isCurrentStoryLoaded,
    required this.videoControllers,
    required this.onStoryLoaded,
    required this.onUserChanged,
    required this.onStoryChanged,
    required this.controller,
    required this.buildVideoPlayer,
  });

  List<Story> _getStoriesForUser(UserStories userStories) {
    return controller.getStoriesForUser(userStories);
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Fondo negro para que no se vean márgenes blancos con BoxFit.contain
    return Container(
      color: Colors.black,
      child: PageView.builder(
        controller: userPageController,
        itemCount: allUserStories.length,
        onPageChanged: onUserChanged,
        itemBuilder: (context, userIndex) {
          final userStories = allUserStories[userIndex];
          final stories = _getStoriesForUser(userStories);

          // ✅ Deshabilitar scroll del PageView interno para que el swipe horizontal
          // se propague al PageView externo (cambio de usuario/grupo)
          // Las historias individuales se cambian con taps izquierda/derecha
          // ✅ FIX: Key único por usuario para evitar reutilización incorrecta de widgets
          return PageView.builder(
            key: ValueKey('user_stories_${userStories.userId}'),
            controller: userIndex == currentUserIndex ? storyPageController : null,
            physics: const NeverScrollableScrollPhysics(), // ← Deshabilitar swipe
            itemCount: stories.length,
            onPageChanged: (storyIndex) {
              if (userIndex == currentUserIndex) {
                onStoryChanged(storyIndex);
              }
            },
            itemBuilder: (context, storyIndex) {
              final story = stories[storyIndex];

              // ✅ FIX: Key único por historia para evitar que Flutter muestre el contenido incorrecto
              // Contenedor negro para cada historia individual
              return Container(
                key: ValueKey('story_content_${story.id}'),
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: _buildStoryContent(context, story, userIndex, storyIndex),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildStoryContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    switch (story.mediaType) {
      case 'image':
        return _buildImageContent(context, story, userIndex, storyIndex);
      case 'mood':
        return _buildMoodContent(context, story, userIndex, storyIndex);
      case 'video':
      default:
        return buildVideoPlayer(story);
    }
  }

  Widget _buildMoodContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    // Extraer emoji del mediaUrl (formato: mood://😊)
    final emoji = story.mediaUrl.replaceFirst('mood://', '');

    // Extraer datos del filter
    final questionText = story.filter?['questionText'] as String? ?? '';
    final responseText = story.filter?['text'] as String? ??
        story.caption?.replaceFirst(RegExp(r'^[\p{Emoji}]+\s*', unicode: true), '') ?? '';

    // Notificar que la historia está cargada
    if (!isCurrentStoryLoaded &&
        userIndex == currentUserIndex &&
        storyIndex == currentStoryIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onStoryLoaded();
      });
    }

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF667eea),
            Color(0xFF764ba2),
          ],
        ),
      ),
      child: Stack(
        children: [
          // Círculos decorativos
          Positioned(
            top: -80,
            right: -80,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
          ),
          Positioned(
            bottom: -60,
            left: -60,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).size.height * 0.3,
            left: -40,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          ),
          // Contenido centrado
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pregunta
                    if (questionText.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          questionText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Colors.white70,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                    // Emoji grande
                    Text(
                      emoji,
                      style: const TextStyle(fontSize: 90),
                    ),
                    const SizedBox(height: 20),
                    // Respuesta
                    if (responseText.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          responseText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            height: 1.4,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    // Si tiene archivo local (mientras se sube)
    if (story.localMediaPath != null && story.localMediaPath!.isNotEmpty) {
      return Image.file(
        File(story.localMediaPath!),
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
      );
    }

    // Imagen de red (ya subida)
    // ✅ FIX: Key único para evitar que Flutter reutilice el widget con imagen incorrecta
    return CachedNetworkImage(
      key: ValueKey('cached_image_${story.id}'),
      imageUrl: story.mediaUrl,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      // Optimización: cachear en tamaño máximo de pantalla
      memCacheWidth: (MediaQuery.of(context).size.width * MediaQuery.of(context).devicePixelRatio).round(),
      memCacheHeight: (MediaQuery.of(context).size.height * MediaQuery.of(context).devicePixelRatio).round(),
      maxWidthDiskCache: 1080, // Máximo en disco
      maxHeightDiskCache: 1920,
      placeholder: (context, url) => Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      ),
      errorWidget: (context, url, error) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error,
              color: Colors.white,
              size: 48,
            ),
            SizedBox(height: 16),
            Text(
              'Error cargando imagen',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
      imageBuilder: (context, imageProvider) {
        // Imagen cargada, notificar solo si aún no está cargada
        if (!isCurrentStoryLoaded &&
            userIndex == currentUserIndex &&
            storyIndex == currentStoryIndex) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.logImageLoaded();
            onStoryLoaded();
          });
        }
        return Image(
          image: imageProvider,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
        );
      },
    );
  }
}
