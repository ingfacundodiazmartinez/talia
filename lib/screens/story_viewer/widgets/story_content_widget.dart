import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/story.dart';
import '../../../models/trivia.dart';
import '../../../models/trivia_response.dart';
import '../../../models/viewer_item.dart';
import '../../../controllers/story_viewer_controller.dart';
import '../../../services/optimistic_story_media_cache.dart';
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
      case 'trivia_results':
        return _buildTriviaResultsContent(context, story, userIndex, storyIndex);
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

    // Si tiene archivo local en el modelo, o si está cacheado (cuando el doc
    // re-llega de Firestore sin el campo localMediaPath), usar Image.file.
    // Esto permite ver la historia mientras se está subiendo.
    final cachedPath = OptimisticStoryMediaCache().get(story.id);
    final localPath = (story.localMediaPath != null && story.localMediaPath!.isNotEmpty)
        ? story.localMediaPath!
        : cachedPath;

    if (localPath != null && localPath.isNotEmpty) {
      imageWidget = Image.file(
        File(localPath),
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
    // Extract response text, removing leading emoji if present
    final captionText = story.caption ?? '';
    final responseText = story.filter?['text'] as String? ??
        (captionText.isNotEmpty ? captionText.replaceFirst(RegExp(r'^[^\x00-\x7F]+\s*'), '') : '');

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

  Widget _buildTriviaResultsContent(BuildContext context, Story story, int userIndex, int storyIndex) {
    // Extraer datos del filter
    final filter = story.filter ?? {};
    final triviaTitle = filter['triviaTitle'] as String? ?? '¿Cuánto me conoces?';
    final participantCount = filter['participantCount'] as int? ?? 0;
    final questionCount = filter['questionCount'] as int? ?? 0;
    final podiumData = filter['podium'] as List<dynamic>? ?? [];

    // Notificar que el contenido está cargado
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
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1a1a2e), Color(0xFF16213e)],
        ),
      ),
      child: Stack(
        children: [
          // Decoración de fondo
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFFFFD700).withValues(alpha: 0.15),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -80,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFFC0C0C0).withValues(alpha: 0.1),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Contenido principal
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const SizedBox(height: 60),

                  // Título
                  const Text(
                    '🏆 Resultados',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    triviaTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      color: Colors.white70,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$participantCount participantes · $questionCount preguntas',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white54,
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Podio
                  if (podiumData.isNotEmpty)
                    Expanded(
                      child: _buildPodiumWidget(context, podiumData),
                    ),

                  const SizedBox(height: 100), // Espacio para reply input
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Construir el widget del podio
  Widget _buildPodiumWidget(BuildContext context, List<dynamic> podiumData) {
    // Reorganizar para mostrar 2do, 1ro, 3ro
    final first = podiumData.isNotEmpty ? podiumData[0] as Map<String, dynamic> : null;
    final second = podiumData.length > 1 ? podiumData[1] as Map<String, dynamic> : null;
    final third = podiumData.length > 2 ? podiumData[2] as Map<String, dynamic> : null;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 2do lugar (izquierda)
        if (second != null)
          _buildPodiumPosition(
            context,
            rank: 2,
            name: second['oderName'] as String? ?? 'Usuario',
            photoURL: second['oderPhotoURL'] as String?,
            score: second['totalScore'] as int? ?? 0,
            correct: second['correctCount'] as int? ?? 0,
            total: second['totalQuestions'] as int? ?? 0,
            height: 100,
            medalColor: const Color(0xFFC0C0C0), // Plata
          ),
        if (second != null) const SizedBox(width: 8),

        // 1er lugar (centro)
        if (first != null)
          _buildPodiumPosition(
            context,
            rank: 1,
            name: first['oderName'] as String? ?? 'Usuario',
            photoURL: first['oderPhotoURL'] as String?,
            score: first['totalScore'] as int? ?? 0,
            correct: first['correctCount'] as int? ?? 0,
            total: first['totalQuestions'] as int? ?? 0,
            height: 140,
            medalColor: const Color(0xFFFFD700), // Oro
          ),

        if (third != null) const SizedBox(width: 8),
        // 3er lugar (derecha)
        if (third != null)
          _buildPodiumPosition(
            context,
            rank: 3,
            name: third['oderName'] as String? ?? 'Usuario',
            photoURL: third['oderPhotoURL'] as String?,
            score: third['totalScore'] as int? ?? 0,
            correct: third['correctCount'] as int? ?? 0,
            total: third['totalQuestions'] as int? ?? 0,
            height: 80,
            medalColor: const Color(0xFFCD7F32), // Bronce
          ),
      ],
    );
  }

  /// Construir una posición individual del podio
  Widget _buildPodiumPosition(
    BuildContext context, {
    required int rank,
    required String name,
    String? photoURL,
    required int score,
    required int correct,
    required int total,
    required double height,
    required Color medalColor,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;
    final positionWidth = (screenWidth - 80) / 3;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Avatar con medalla
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: rank == 1 ? 80 : 64,
              height: rank == 1 ? 80 : 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: medalColor,
                  width: rank == 1 ? 4 : 3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: medalColor.withValues(alpha: 0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipOval(
                child: photoURL != null && photoURL.isNotEmpty
                    ? Image.network(
                        photoURL,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => _buildDefaultAvatar(name),
                      )
                    : _buildDefaultAvatar(name),
              ),
            ),
            // Medalla
            Positioned(
              bottom: -8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: medalColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      '$rank',
                      style: TextStyle(
                        color: rank == 1 ? Colors.black : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Nombre
        SizedBox(
          width: positionWidth,
          child: Text(
            name,
            style: TextStyle(
              color: Colors.white,
              fontSize: rank == 1 ? 16 : 14,
              fontWeight: rank == 1 ? FontWeight.bold : FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 4),

        // Puntuación
        Text(
          '$score pts',
          style: TextStyle(
            color: medalColor,
            fontSize: rank == 1 ? 18 : 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),

        // Aciertos
        Text(
          '$correct/$total',
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 12),

        // Pedestal
        Container(
          width: positionWidth,
          height: height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                medalColor.withValues(alpha: 0.6),
                medalColor.withValues(alpha: 0.3),
              ],
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          ),
        ),
      ],
    );
  }

  /// Construir avatar por defecto
  Widget _buildDefaultAvatar(String name) {
    return Container(
      color: const Color(0xFF667eea),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
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
