import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/story.dart';
import '../../../controllers/story_viewer_controller.dart';
import 'package:video_player/video_player.dart';

/// Widget que maneja el contenido principal de las historias
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
  final bool showCaptionOverlay;
  final bool hasReplyInput;

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
    this.showCaptionOverlay = true,
    this.hasReplyInput = false,
  });

  List<Story> _getStoriesForUser(UserStories userStories) {
    return controller.getStoriesForUser(userStories);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: PageView.builder(
        controller: userPageController,
        itemCount: allUserStories.length,
        onPageChanged: onUserChanged,
        itemBuilder: (context, userIndex) {
          final userStories = allUserStories[userIndex];
          final stories = _getStoriesForUser(userStories);

          return PageView.builder(
            key: ValueKey('user_stories_${userStories.userId}'),
            controller: userIndex == currentUserIndex ? storyPageController : null,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: stories.length,
            onPageChanged: (storyIndex) {
              if (userIndex == currentUserIndex) {
                onStoryChanged(storyIndex);
              }
            },
            itemBuilder: (context, storyIndex) {
              final story = stories[storyIndex];

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
        return _buildVideoContent(context, story, userIndex, storyIndex);
    }
  }

  Widget _buildImageContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    final hasCaption = showCaptionOverlay &&
        story.caption != null &&
        story.caption!.trim().isNotEmpty;

    Widget imageWidget;

    // Si tiene archivo local (mientras se sube)
    if (story.localMediaPath != null && story.localMediaPath!.isNotEmpty) {
      imageWidget = Image.file(
        File(story.localMediaPath!),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      );

      // Notificar carga
      if (!isCurrentStoryLoaded &&
          userIndex == currentUserIndex &&
          storyIndex == currentStoryIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onStoryLoaded();
        });
      }
    } else {
      // Imagen de red
      imageWidget = CachedNetworkImage(
        key: ValueKey('cached_image_${story.id}'),
        imageUrl: story.mediaUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: (MediaQuery.of(context).size.width * MediaQuery.of(context).devicePixelRatio).round(),
        memCacheHeight: (MediaQuery.of(context).size.height * MediaQuery.of(context).devicePixelRatio).round(),
        maxWidthDiskCache: 1080,
        maxHeightDiskCache: 1920,
        placeholder: (context, url) => const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
        errorWidget: (context, url, error) => const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, color: Colors.white, size: 48),
              SizedBox(height: 16),
              Text('Error cargando imagen', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
        imageBuilder: (context, imageProvider) {
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
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );
        },
      );
    }

    // Si no hay caption, devolver solo la imagen
    if (!hasCaption) {
      return imageWidget;
    }

    // Con caption: Stack con imagen + caption overlay
    return Stack(
      fit: StackFit.expand,
      children: [
        imageWidget,
        Positioned(
          left: 0,
          right: 0,
          bottom: hasReplyInput ? 100 : 30,
          child: _buildCaptionWidget(story.caption!),
        ),
      ],
    );
  }

  Widget _buildVideoContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    final hasCaption = showCaptionOverlay &&
        story.caption != null &&
        story.caption!.trim().isNotEmpty;

    final videoWidget = buildVideoPlayer(story);

    if (!hasCaption) {
      return videoWidget;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        videoWidget,
        Positioned(
          left: 0,
          right: 0,
          bottom: hasReplyInput ? 100 : 30,
          child: _buildCaptionWidget(story.caption!),
        ),
      ],
    );
  }

  Widget _buildMoodContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    final emoji = story.mediaUrl.replaceFirst('mood://', '');
    final questionText = story.filter?['questionText'] as String? ?? '';
    final responseText = story.filter?['text'] as String? ??
        story.caption?.replaceFirst(RegExp(r'^[\p{Emoji}]+\s*', unicode: true), '') ?? '';

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
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
        ),
      ),
      child: Stack(
        children: [
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
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    Text(emoji, style: const TextStyle(fontSize: 90)),
                    const SizedBox(height: 20),
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

  Widget _buildCaptionWidget(String caption) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        caption,
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          shadows: [
            Shadow(
              offset: const Offset(0, 1),
              blurRadius: 3,
              color: Colors.black.withValues(alpha: 0.8),
            ),
            Shadow(
              offset: const Offset(0, 2),
              blurRadius: 6,
              color: Colors.black.withValues(alpha: 0.5),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
