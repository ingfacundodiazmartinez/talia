import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/story.dart';
import '../services/story_service.dart';
import 'story_viewer/widgets/story_progress_indicators.dart';
import 'story_viewer/widgets/story_user_header.dart';
import 'story_viewer/widgets/story_caption_widget.dart';
import 'story_viewer/widgets/story_reply_input.dart';

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
  bool _isCurrentStoryLoaded = false;

  final StoryService _storyService = StoryService();
  final Duration _storyDuration = Duration(seconds: 5);

  // Controlador para respuestas
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  bool _isSendingReply = false;

  // Obtener las historias apropiadas para cada usuario
  List<Story> _getStoriesForUser(UserStories userStories) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isCurrentUser = currentUser?.uid == userStories.userId;

    // Para el usuario actual, mostrar todas las historias (incluyendo pendientes/rechazadas)
    // Para otros usuarios, mostrar solo historias aprobadas
    final stories = isCurrentUser
        ? userStories.allUserStories
        : userStories.sortedStories;

    // Ordenar: primero las no vistas, luego las vistas
    // Dentro de cada grupo, mantener orden cronológico
    if (currentUser == null) return stories;

    final unviewedStories = stories.where((story) => !story.isViewedBy(currentUser.uid)).toList();
    final viewedStories = stories.where((story) => story.isViewedBy(currentUser.uid)).toList();

    // Mantener orden cronológico dentro de cada grupo
    unviewedStories.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    viewedStories.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return [...unviewedStories, ...viewedStories];
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

    // Listener para pausar/reanudar historia cuando se escribe una respuesta
    _replyFocusNode.addListener(() {
      if (_replyFocusNode.hasFocus) {
        _pauseStoryTimer();
      } else {
        _resumeStoryTimer();
      }
    });

    _startStoryTimer();
    _markCurrentStoryAsViewed();
  }

  void _startStoryTimer() {
    // Solo iniciar si la historia actual está cargada
    if (!_isCurrentStoryLoaded) {
      print('⏸️ Historia no cargada, esperando...');
      return;
    }

    _progressController.reset();
    _progressController.forward();

    _storyTimer?.cancel();
    _storyTimer = Timer(_storyDuration, () {
      _nextStory();
    });
  }

  void _onStoryLoaded() {
    if (_isCurrentStoryLoaded) return; // Ya estaba cargada

    setState(() {
      _isCurrentStoryLoaded = true;
    });
    print('✅ Historia cargada, iniciando timer');
    _startStoryTimer();

    // Precargar las siguientes historias
    _preloadNextStories();
  }

  void _preloadNextStories() {
    try {
      final currentUserStories = widget.allUserStories[_currentUserIndex];
      final stories = _getStoriesForUser(currentUserStories);

      // Precargar la siguiente historia del mismo usuario
      if (_currentStoryIndex < stories.length - 1) {
        final nextStory = stories[_currentStoryIndex + 1];
        if (nextStory.mediaType == 'image') {
          precacheImage(NetworkImage(nextStory.mediaUrl), context);
          print('🔄 Precargando siguiente historia del mismo usuario');
        }
      }

      // Precargar la primera historia del siguiente usuario
      if (_currentUserIndex < widget.allUserStories.length - 1) {
        final nextUserStories = widget.allUserStories[_currentUserIndex + 1];
        final nextUserStoriesList = _getStoriesForUser(nextUserStories);
        if (nextUserStoriesList.isNotEmpty) {
          final firstStoryOfNextUser = nextUserStoriesList[0];
          if (firstStoryOfNextUser.mediaType == 'image') {
            precacheImage(NetworkImage(firstStoryOfNextUser.mediaUrl), context);
            print('🔄 Precargando primera historia del siguiente usuario');
          }
        }
      }
    } catch (e) {
      print('⚠️ Error precargando historias: $e');
    }
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
        _isCurrentStoryLoaded = false; // Reset para la nueva historia
      });
      _storyPageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      // No iniciar timer aquí - esperará a que _onStoryLoaded() lo inicie
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
        _isCurrentStoryLoaded = false; // Reset para la nueva historia
      });
      _storyPageController.previousPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startStoryTimer(); // Se ejecutará cuando la historia cargue
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
        _isCurrentStoryLoaded = false; // Reset para la nueva historia
      });
      _userPageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _startStoryTimer(); // Se ejecutará cuando la historia cargue
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
        _isCurrentStoryLoaded = false; // Reset para la nueva historia
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

  Future<void> _deleteCurrentStory() async {
    // Pausar el timer mientras se muestra el diálogo
    _pauseStoryTimer();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar historia'),
        content: Text('¿Estás seguro de que deseas eliminar esta historia?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      _resumeStoryTimer();
      return;
    }

    try {
      final currentUserStories = widget.allUserStories[_currentUserIndex];
      final stories = _getStoriesForUser(currentUserStories);
      final currentStory = stories[_currentStoryIndex];

      // Eliminar la historia
      await _storyService.deleteStory(currentStory.id);

      // Si era la única historia, cerrar el visor
      if (mounted) {
        if (stories.length == 1) {
          Navigator.pop(context);
        } else {
          // Si hay más historias, ir a la siguiente
          _nextStory();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar la historia: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
        _resumeStoryTimer();
      }
    }
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _isSendingReply) return;

    setState(() {
      _isSendingReply = true;
    });

    try {
      final currentUserStories = widget.allUserStories[_currentUserIndex];
      final stories = _getStoriesForUser(currentUserStories);
      final currentStory = stories[_currentStoryIndex];

      // Limpiar input y cerrar teclado INMEDIATAMENTE (optimista)
      _replyController.clear();
      _replyFocusNode.unfocus();

      // Mostrar feedback inmediato
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Enviando respuesta...'),
            backgroundColor: Colors.blue,
            duration: Duration(milliseconds: 800),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(
              bottom: MediaQuery.of(context).size.height - 150,
              left: 20,
              right: 20,
            ),
          ),
        );
      }

      // Enviar en background (sin await bloqueante para el usuario)
      _storyService.replyToStory(
        storyId: currentStory.id,
        text: text,
      ).catchError((e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al enviar respuesta'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.only(
                bottom: MediaQuery.of(context).size.height - 150,
                left: 20,
                right: 20,
              ),
            ),
          );
        }
      }).whenComplete(() {
        if (mounted) {
          setState(() {
            _isSendingReply = false;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSendingReply = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar respuesta'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(
              bottom: MediaQuery.of(context).size.height - 150,
              left: 20,
              right: 20,
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _storyTimer?.cancel();
    _progressController.dispose();
    _userPageController.dispose();
    _storyPageController.dispose();
    _replyController.dispose();
    _replyFocusNode.dispose();
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
          // Si el teclado está abierto, cerrarlo
          if (_replyFocusNode.hasFocus) {
            _replyFocusNode.unfocus();
            return;
          }

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
                  _isCurrentStoryLoaded = false; // Reset para la nueva historia
                });
                // No iniciar timer aquí - esperará a que _onStoryLoaded() lo inicie
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
                        _isCurrentStoryLoaded = false; // Reset para la nueva historia
                      });
                      // No iniciar timer aquí - esperará a que _onStoryLoaded() lo inicie
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
                                    if (loadingProgress == null) {
                                      // Imagen cargada, notificar y devolver la imagen
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        _onStoryLoaded();
                                      });
                                      return child;
                                    }
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
                  StoryProgressIndicators(
                    storyCount: _getStoriesForUser(
                      widget.allUserStories[_currentUserIndex],
                    ).length,
                    currentStoryIndex: _currentStoryIndex,
                    progressAnimation: _progressController,
                  ),

                  // Header con información del usuario
                  StoryUserHeader(
                    userName: widget.allUserStories[_currentUserIndex].userName,
                    userPhotoURL: widget.allUserStories[_currentUserIndex].userPhotoURL,
                    timeAgo: _formatStoryTime(
                      _getStoriesForUser(
                        widget.allUserStories[_currentUserIndex],
                      )[_currentStoryIndex].createdAt,
                    ),
                    isCurrentUser: widget.allUserStories[_currentUserIndex].userId ==
                        FirebaseAuth.instance.currentUser?.uid,
                    onDelete: _deleteCurrentStory,
                    onClose: () => Navigator.pop(context),
                  ),

                  Spacer(),

                  // Caption si existe
                  if (_getStoriesForUser(
                        widget.allUserStories[_currentUserIndex],
                      )[_currentStoryIndex].caption !=
                      null)
                    StoryCaptionWidget(
                      caption: _getStoriesForUser(
                        widget.allUserStories[_currentUserIndex],
                      )[_currentStoryIndex].caption!,
                      isCurrentUser: widget.allUserStories[_currentUserIndex].userId ==
                          FirebaseAuth.instance.currentUser?.uid,
                    ),

                  // Mostrar respuestas si es la historia del usuario actual y tiene respuestas
                  Builder(
                    builder: (context) {
                      final currentUser = FirebaseAuth.instance.currentUser;
                      final isCurrentUser =
                          currentUser?.uid ==
                          widget.allUserStories[_currentUserIndex].userId;
                      final currentStory = _getStoriesForUser(
                        widget.allUserStories[_currentUserIndex],
                      )[_currentStoryIndex];

                      if (isCurrentUser && currentStory.replies.isNotEmpty) {
                        return Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: GestureDetector(
                            onTap: () async {
                              _pauseStoryTimer();
                              await showModalBottomSheet(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (context) => Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.9),
                                    borderRadius: BorderRadius.only(
                                      topLeft: Radius.circular(20),
                                      topRight: Radius.circular(20),
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Respuestas (${currentStory.replies.length})',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: () {
                                                Navigator.pop(context);
                                              },
                                              icon: Icon(
                                                Icons.close,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Divider(
                                        color: Colors.white.withOpacity(0.2),
                                        height: 1,
                                      ),
                                      Flexible(
                                        child: ListView.builder(
                                          shrinkWrap: true,
                                          itemCount: currentStory.replies.length,
                                          itemBuilder: (context, index) {
                                            final reply = currentStory
                                                .replies[currentStory.replies.length - 1 - index];
                                            return Container(
                                              padding: EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 12,
                                              ),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  CircleAvatar(
                                                    radius: 16,
                                                    backgroundColor:
                                                        Colors.white.withOpacity(0.2),
                                                    backgroundImage:
                                                        reply.userPhotoURL != null
                                                            ? NetworkImage(
                                                                reply.userPhotoURL!)
                                                            : null,
                                                    child: reply.userPhotoURL == null
                                                        ? Text(
                                                            reply.userName[0]
                                                                .toUpperCase(),
                                                            style: TextStyle(
                                                              color: Colors.white,
                                                              fontSize: 14,
                                                            ),
                                                          )
                                                        : null,
                                                  ),
                                                  SizedBox(width: 12),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment.start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Text(
                                                              reply.userName,
                                                              style: TextStyle(
                                                                color: Colors.white,
                                                                fontWeight:
                                                                    FontWeight.w600,
                                                                fontSize: 14,
                                                              ),
                                                            ),
                                                            SizedBox(width: 8),
                                                            Text(
                                                              _formatStoryTime(
                                                                  reply.timestamp),
                                                              style: TextStyle(
                                                                color: Colors.white
                                                                    .withOpacity(0.6),
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        SizedBox(height: 4),
                                                        Text(
                                                          reply.text,
                                                          style: TextStyle(
                                                            color: Colors.white
                                                                .withOpacity(0.9),
                                                            fontSize: 14,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      SizedBox(height: 16),
                                    ],
                                  ),
                                ),
                              );
                              // Reanudar timer solo después de cerrar el bottom sheet
                              _resumeStoryTimer();
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.chat_bubble_outline,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    '${currentStory.replies.length} ${currentStory.replies.length == 1 ? "respuesta" : "respuestas"}',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      return SizedBox.shrink();
                    },
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

            // Campo de respuesta (solo si NO es la historia del usuario actual)
            if (widget.allUserStories[_currentUserIndex].userId !=
                FirebaseAuth.instance.currentUser?.uid)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: StoryReplyInput(
                  controller: _replyController,
                  focusNode: _replyFocusNode,
                  onSend: _sendReply,
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
