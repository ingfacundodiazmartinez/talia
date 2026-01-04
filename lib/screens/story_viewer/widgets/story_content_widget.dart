import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/story.dart';
import '../../../models/trivia.dart';
import '../../../models/trivia_response.dart';
import '../../../models/viewer_item.dart';
import '../../../controllers/story_viewer_controller.dart';
import 'package:video_player/video_player.dart';
import 'trivia_preview_widget.dart';

/// Widget que maneja el contenido principal de las historias y trivias
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

  // ✅ Parámetros opcionales para soporte de trivias
  final List<UserContent>? userContentList;
  final Map<String, TriviaViewerState>? triviaStates;
  final Map<String, TriviaResponse?>? triviaResponses;
  final void Function(Trivia)? onTriviaPlay;
  final void Function(Trivia)? onTriviaViewResults;
  final String? currentUserId;

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
    // Trivia support
    this.userContentList,
    this.triviaStates,
    this.triviaResponses,
    this.onTriviaPlay,
    this.onTriviaViewResults,
    this.currentUserId,
  });

  List<Story> _getStoriesForUser(UserStories userStories) {
    return controller.getStoriesForUser(userStories);
  }

  /// Si userContentList está disponible, usarlo para contar items
  int _getItemCount(int userIndex) {
    if (userContentList != null && userIndex < userContentList!.length) {
      return userContentList![userIndex].items.length;
    }
    if (userIndex < allUserStories.length) {
      return _getStoriesForUser(allUserStories[userIndex]).length;
    }
    return 0;
  }

  /// Obtener el ViewerItem en una posición
  ViewerItem? _getItem(int userIndex, int itemIndex) {
    if (userContentList != null && userIndex < userContentList!.length) {
      final content = userContentList![userIndex];
      if (itemIndex < content.items.length) {
        return content.items[itemIndex];
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Si hay userContentList, usar modo unificado (stories + trivias)
    final useUnifiedMode = userContentList != null && userContentList!.isNotEmpty;
    final itemCount = useUnifiedMode ? userContentList!.length : allUserStories.length;

    return Container(
      color: Colors.black,
      child: PageView.builder(
        controller: userPageController,
        itemCount: itemCount,
        onPageChanged: onUserChanged,
        itemBuilder: (context, userIndex) {
          // Determinar el ID del usuario para el key
          String userId;
          if (useUnifiedMode) {
            userId = userContentList![userIndex].oderId;
          } else {
            userId = allUserStories[userIndex].userId;
          }

          final innerItemCount = _getItemCount(userIndex);

          return PageView.builder(
            key: ValueKey('user_content_$userId'),
            controller: userIndex == currentUserIndex ? storyPageController : null,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: innerItemCount,
            onPageChanged: (itemIndex) {
              if (userIndex == currentUserIndex) {
                onStoryChanged(itemIndex);
              }
            },
            itemBuilder: (context, itemIndex) {
              // ✅ Si hay userContentList, usar ViewerItem
              if (useUnifiedMode) {
                final item = _getItem(userIndex, itemIndex);
                if (item == null) {
                  return Container(color: Colors.black);
                }

                return Container(
                  key: ValueKey('item_${item.id}'),
                  color: Colors.black,
                  width: double.infinity,
                  height: double.infinity,
                  child: _buildItemContent(context, item, userIndex, itemIndex),
                );
              }

              // Modo legacy: solo stories
              final userStories = allUserStories[userIndex];
              final stories = _getStoriesForUser(userStories);
              if (itemIndex >= stories.length) {
                return Container(color: Colors.black);
              }
              final story = stories[itemIndex];

              return Container(
                key: ValueKey('story_content_${story.id}'),
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: _buildStoryContent(context, story, userIndex, itemIndex),
              );
            },
          );
        },
      ),
    );
  }

  /// Construir contenido para un ViewerItem (story, trivia, o ad)
  Widget _buildItemContent(BuildContext context, ViewerItem item, int userIndex, int itemIndex) {
    if (item.isStory && item.story != null) {
      return _buildStoryContent(context, item.story!, userIndex, itemIndex);
    }

    if (item.isTrivia && item.trivia != null) {
      return _buildTriviaContent(context, item.trivia!, userIndex, itemIndex);
    }

    // TODO: Handle ads
    return Container(color: Colors.black);
  }

  /// Construir contenido de trivia
  Widget _buildTriviaContent(BuildContext context, Trivia trivia, int userIndex, int itemIndex) {
    final state = triviaStates?[trivia.id] ?? TriviaViewerState.preview;
    final isCreator = currentUserId == trivia.creatorId;
    // Obtener la respuesta del usuario actual para esta trivia
    final userResponse = triviaResponses?[trivia.id];

    // En modo preview o results, mostrar TriviaPreviewWidget
    // En modo playing, se maneja por separado (fullscreen trivia play)
    if (state == TriviaViewerState.playing) {
      // Este estado se maneja en el widget padre (StoryViewerScreen)
      // Aquí solo mostramos un placeholder mientras transiciona
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return TriviaPreviewWidget(
      trivia: trivia,
      userResponse: userResponse,
      isCreator: isCreator,
      onPlay: () => onTriviaPlay?.call(trivia),
      onViewResults: () => onTriviaViewResults?.call(trivia),
      onLoaded: () {
        if (!isCurrentStoryLoaded &&
            userIndex == currentUserIndex &&
            itemIndex == currentStoryIndex) {
          onStoryLoaded();
        }
      },
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
