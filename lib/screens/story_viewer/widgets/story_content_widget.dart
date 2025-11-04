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
    return PageView.builder(
      controller: userPageController,
      itemCount: allUserStories.length,
      onPageChanged: onUserChanged,
      itemBuilder: (context, userIndex) {
        final userStories = allUserStories[userIndex];
        final stories = _getStoriesForUser(userStories);

        return PageView.builder(
          controller: userIndex == currentUserIndex ? storyPageController : null,
          itemCount: stories.length,
          onPageChanged: (storyIndex) {
            if (userIndex == currentUserIndex) {
              onStoryChanged(storyIndex);
            }
          },
          itemBuilder: (context, storyIndex) {
            final story = stories[storyIndex];

            return SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: story.mediaType == 'image'
                  ? _buildImageContent(context, story, userIndex, storyIndex)
                  : buildVideoPlayer(story),
            );
          },
        );
      },
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
    return CachedNetworkImage(
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