import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/story.dart';
import '../services/story_service.dart';

class StoryViewerScreen extends StatefulWidget {
  final List<UserStories> allUserStories;
  final int initialUserIndex;

  const StoryViewerScreen({
    super.key,
    required this.allUserStories,
    required this.initialUserIndex,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with TickerProviderStateMixin {
  late PageController _userPageController;
  late PageController _storyPageController;
  late AnimationController _progressController;

  int _currentUserIndex = 0;
  int _currentStoryIndex = 0;
  Timer? _storyTimer;

  final StoryService _storyService = StoryService();
  final Duration _storyDuration = Duration(seconds: 5);

  // Obtener las historias apropiadas para cada usuario
  List<Story> _getStoriesForUser(UserStories userStories) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isCurrentUser = currentUser?.uid == userStories.userId;

    // Para el usuario actual, mostrar todas las historias (incluyendo pendientes/rechazadas)
    // Para otros usuarios, mostrar solo historias aprobadas
    return isCurrentUser
        ? userStories.allUserStories
        : userStories.sortedStories;
  }

  @override
  void initState() {
    super.initState();
    _currentUserIndex = widget.initialUserIndex;
    _userPageController = PageController(initialPage: _currentUserIndex);
    _storyPageController = PageController();
    _progressController = AnimationController(
      vsync: this,
      duration: _storyDuration,
    );

    _startStoryTimer();
    _markCurrentStoryAsViewed();
  }

  void _startStoryTimer() {
    _progressController.reset();
    _progressController.forward();

    _storyTimer?.cancel();
    _storyTimer = Timer(_storyDuration, () {
      _nextStory();
    });
  }

  void _pauseStoryTimer() {
    _storyTimer?.cancel();
    _progressController.stop();
  }

  void _resumeStoryTimer() {
    _progressController.forward();
    final remainingTime = Duration(
      milliseconds:
          ((_storyDuration.inMilliseconds) * (1 - _progressController.value))
              .round(),
    );
    _storyTimer = Timer(remainingTime, () {
      _nextStory();
    });
  }

  void _nextStory() {
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);

    if (_currentStoryIndex < stories.length - 1) {
      // Siguiente historia del mismo usuario
      setState(() {
        _currentStoryIndex++;
      });
      _storyPageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startStoryTimer();
      _markCurrentStoryAsViewed();
    } else {
      // Siguiente usuario
      _nextUser();
    }
  }

  void _previousStory() {
    if (_currentStoryIndex > 0) {
      // Historia anterior del mismo usuario
      setState(() {
        _currentStoryIndex--;
      });
      _storyPageController.previousPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startStoryTimer();
      _markCurrentStoryAsViewed();
    } else {
      // Usuario anterior
      _previousUser();
    }
  }

  void _nextUser() {
    if (_currentUserIndex < widget.allUserStories.length - 1) {
      setState(() {
        _currentUserIndex++;
        _currentStoryIndex = 0;
      });
      _userPageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startStoryTimer();
      _markCurrentStoryAsViewed();
    } else {
      Navigator.pop(context);
    }
  }

  void _previousUser() {
    if (_currentUserIndex > 0) {
      setState(() {
        _currentUserIndex--;
        final stories = _getStoriesForUser(
          widget.allUserStories[_currentUserIndex],
        );
        _currentStoryIndex = stories.length - 1;
      });
      _userPageController.previousPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startStoryTimer();
      _markCurrentStoryAsViewed();
    }
  }

  void _markCurrentStoryAsViewed() {
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);
    final currentStory = stories[_currentStoryIndex];
    _storyService.markStoryAsViewed(currentStory.id);
  }

  @override
  void dispose() {
    _storyTimer?.cancel();
    _progressController.dispose();
    _userPageController.dispose();
    _storyPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: (details) {
          _pauseStoryTimer();
        },
        onTapUp: (details) {
          final screenWidth = MediaQuery.of(context).size.width;
          if (details.localPosition.dx < screenWidth / 3) {
            _previousStory();
          } else if (details.localPosition.dx > screenWidth * 2 / 3) {
            _nextStory();
          } else {
            _resumeStoryTimer();
          }
        },
        onTapCancel: () {
          _resumeStoryTimer();
        },
        child: Stack(
          children: [
            // Visor de historias por usuario
            PageView.builder(
              controller: _userPageController,
              itemCount: widget.allUserStories.length,
              onPageChanged: (index) {
                setState(() {
                  _currentUserIndex = index;
                  _currentStoryIndex = 0;
                });
                _startStoryTimer();
                _markCurrentStoryAsViewed();
              },
              itemBuilder: (context, userIndex) {
                final userStories = widget.allUserStories[userIndex];
                final stories = _getStoriesForUser(userStories);

                return PageView.builder(
                  controller: userIndex == _currentUserIndex
                      ? _storyPageController
                      : null,
                  itemCount: stories.length,
                  onPageChanged: (storyIndex) {
                    if (userIndex == _currentUserIndex) {
                      setState(() {
                        _currentStoryIndex = storyIndex;
                      });
                      _startStoryTimer();
                      _markCurrentStoryAsViewed();
                    }
                  },
                  itemBuilder: (context, storyIndex) {
                    final story = stories[storyIndex];

                    return SizedBox(
                      width: double.infinity,
                      height: double.infinity,
                      child: story.mediaType == 'image'
                          ? Image.network(
                              story.mediaUrl,
                              fit: BoxFit.cover,
                              loadingBuilder:
                                  (context, child, loadingProgress) {
                                    if (loadingProgress == null) return child;
                                    return Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        value:
                                            loadingProgress
                                                    .expectedTotalBytes !=
                                                null
                                            ? loadingProgress
                                                      .cumulativeBytesLoaded /
                                                  loadingProgress
                                                      .expectedTotalBytes!
                                            : null,
                                      ),
                                    );
                                  },
                              errorBuilder: (context, error, stackTrace) {
                                return Center(
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
                                );
                              },
                            )
                          : Center(
                              child: Text(
                                'Video no soportado aún',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                    );
                  },
                );
              },
            ),

            // Overlay con información y controles
            SafeArea(
              child: Column(
                children: [
                  // Indicadores de progreso
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: List.generate(
                        _getStoriesForUser(
                          widget.allUserStories[_currentUserIndex],
                        ).length,
                        (index) {
                          return Expanded(
                            child: Container(
                              height: 3,
                              margin: EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(1.5),
                                child: LinearProgressIndicator(
                                  backgroundColor: Colors.transparent,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                  value: index < _currentStoryIndex
                                      ? 1.0
                                      : index == _currentStoryIndex
                                      ? _progressController.value
                                      : 0.0,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // Header con información del usuario
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: Colors.white.withOpacity(0.3),
                          backgroundImage:
                              widget
                                      .allUserStories[_currentUserIndex]
                                      .userPhotoURL !=
                                  null
                              ? NetworkImage(
                                  widget
                                      .allUserStories[_currentUserIndex]
                                      .userPhotoURL!,
                                )
                              : null,
                          child:
                              widget
                                      .allUserStories[_currentUserIndex]
                                      .userPhotoURL ==
                                  null
                              ? Text(
                                  widget
                                      .allUserStories[_currentUserIndex]
                                      .userName[0]
                                      .toUpperCase(),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget
                                    .allUserStories[_currentUserIndex]
                                    .userName,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _formatStoryTime(
                                  _getStoriesForUser(
                                    widget.allUserStories[_currentUserIndex],
                                  )[_currentStoryIndex].createdAt,
                                ),
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.8),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close, color: Colors.white),
                        ),
                      ],
                    ),
                  ),

                  Spacer(),

                  // Caption si existe
                  if (_getStoriesForUser(
                        widget.allUserStories[_currentUserIndex],
                      )[_currentStoryIndex].caption !=
                      null)
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(16),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _getStoriesForUser(
                            widget.allUserStories[_currentUserIndex],
                          )[_currentStoryIndex].caption!,
                          style: TextStyle(color: Colors.white, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),

                  // Indicador de estado para historias del usuario actual
                  Builder(
                    builder: (context) {
                      final currentUser = FirebaseAuth.instance.currentUser;
                      final isCurrentUser =
                          currentUser?.uid ==
                          widget.allUserStories[_currentUserIndex].userId;

                      if (isCurrentUser) {
                        final currentStory = _getStoriesForUser(
                          widget.allUserStories[_currentUserIndex],
                        )[_currentStoryIndex];

                        if (currentStory.status == StoryStatus.pending) {
                          return Container(
                            margin: EdgeInsets.symmetric(horizontal: 16),
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.access_time,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Esperando aprobación de tus padres',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          );
                        } else if (currentStory.status ==
                            StoryStatus.rejected) {
                          return Container(
                            margin: EdgeInsets.symmetric(horizontal: 16),
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.close,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Historia rechazada',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                if (currentStory.rejectionReason != null &&
                                    currentStory
                                        .rejectionReason!
                                        .isNotEmpty) ...[
                                  SizedBox(height: 4),
                                  Text(
                                    currentStory.rejectionReason!,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.9),
                                      fontSize: 11,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ],
                            ),
                          );
                        }
                      }

                      return SizedBox.shrink();
                    },
                  ),

                  SizedBox(height: 20),
                ],
              ),
            ),

            // Indicadores de zona táctil (solo en debug)
            if (false) // Cambiar a true para mostrar zonas táctiles
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        color: Colors.red.withOpacity(0.2),
                        child: Center(
                          child: Text(
                            'ANTERIOR',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        color: Colors.blue.withOpacity(0.2),
                        child: Center(
                          child: Text(
                            'PAUSA',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        color: Colors.green.withOpacity(0.2),
                        child: Center(
                          child: Text(
                            'SIGUIENTE',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatStoryTime(DateTime createdAt) {
    final now = DateTime.now();
    final difference = now.difference(createdAt);

    if (difference.inMinutes < 1) {
      return 'Ahora';
    } else if (difference.inHours < 1) {
      return 'hace ${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return 'hace ${difference.inHours}h';
    } else {
      return 'hace ${difference.inDays}d';
    }
  }
}
