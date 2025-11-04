import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../models/story.dart';
import '../controllers/story_viewer_controller.dart';
import '../services/ad_service.dart';
import '../widgets/story_native_ad_widget.dart';
import 'story_viewer/widgets/story_content_widget.dart';
import 'story_viewer/widgets/story_overlay_widget.dart';

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
  late StoryViewerController _controller;

  int _currentUserIndex = 0;
  int _currentStoryIndex = 0;
  Timer? _storyTimer;
  bool _isCurrentStoryLoaded = false;

  final AdService _adService = AdService();
  final Duration _storyDuration = Duration(seconds: 5);

  // Native Ad pre-cargado para mostrar entre historias
  NativeAd? _nativeAd;
  bool _isNativeAdLoaded = false;

  // VideoPlayerController map para manejar múltiples videos
  final Map<String, VideoPlayerController> _videoControllers = {};

  // Controlador para respuestas
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  bool _isSendingReply = false;

  // Obtener las historias apropiadas para cada usuario
  List<Story> _getStoriesForUser(UserStories userStories) {
    return _controller.getStoriesForUser(userStories);
  }

  // Calcular el índice de la primera historia NO vista de un grupo
  int _getInitialStoryIndex(List<Story> stories) {
    return _controller.getInitialStoryIndex(stories);
  }

  @override
  void initState() {
    super.initState();

    // Inicializar el controller
    _controller = StoryViewerController(
      allUserStories: widget.allUserStories,
      initialUserIndex: widget.initialUserIndex,
    );
    _controller.initialize();

    _currentUserIndex = widget.initialUserIndex;

    // Calcular el índice de la primera historia NO vista del grupo actual
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);
    final initialStoryIndex = _getInitialStoryIndex(stories);

    _currentStoryIndex = initialStoryIndex;
    _userPageController = PageController(initialPage: _currentUserIndex);
    _storyPageController = PageController(initialPage: initialStoryIndex);
    _progressController = AnimationController(
      vsync: this,
      duration: _storyDuration,
    );

    // Inicializar y pre-cargar ads para monetización
    _initializeAds();

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

  /// Inicializar AdMob y pre-cargar el primer anuncio
  Future<void> _initializeAds() async {
    try {
      await _controller.initializeAds();
      // Pre-cargar Native Ad para mostrar como historia
      await _loadNativeAd();
    } catch (e) {
      // El controller ya maneja el logging de errores
    }
  }

  /// Cargar un Native Ad para mostrar como historia
  Future<void> _loadNativeAd() async {
    final ad = await _adService.createStoryNativeAd(
      onAdLoaded: (ad) {
        if (mounted) {
          setState(() {
            _nativeAd = ad;
            _isNativeAdLoaded = true;
          });
          _controller.logNativeAdLoaded();
        }
      },
      onAdFailedToLoad: (ad, error) {
        _controller.logNativeAdError(error.message);
        if (mounted) {
          setState(() {
            _nativeAd = null;
            _isNativeAdLoaded = false;
          });
        }
      },
    );

    if (ad != null && mounted) {
      setState(() {
        _nativeAd = ad;
        _isNativeAdLoaded = false; // Se marcará true en onAdLoaded
      });
    }
  }

  void _startStoryTimer() {
    // Solo iniciar si la historia actual está cargada
    if (!_isCurrentStoryLoaded) {
      _controller.logStoryNotLoaded();
      return;
    }

    // Esperar un frame para asegurar que el reset visual se complete
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isCurrentStoryLoaded) {
        _progressController.forward();

        _storyTimer?.cancel();
        _storyTimer = Timer(_storyDuration, () {
          _nextStory();
        });
      }
    });
  }

  void _onStoryLoaded() {
    if (_isCurrentStoryLoaded) return; // Ya estaba cargada

    setState(() {
      _isCurrentStoryLoaded = true;
    });
    _controller.logStoryLoaded();
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
          precacheImage(CachedNetworkImageProvider(nextStory.mediaUrl), context);
          _controller.logStoryPreloading('siguiente historia del mismo usuario');
        }
      }

      // Precargar la primera historia del siguiente usuario
      if (_currentUserIndex < widget.allUserStories.length - 1) {
        final nextUserStories = widget.allUserStories[_currentUserIndex + 1];
        final nextUserStoriesList = _getStoriesForUser(nextUserStories);
        if (nextUserStoriesList.isNotEmpty) {
          final firstStoryOfNextUser = nextUserStoriesList[0];
          if (firstStoryOfNextUser.mediaType == 'image') {
            precacheImage(CachedNetworkImageProvider(firstStoryOfNextUser.mediaUrl), context);
            _controller.logStoryPreloading('primera historia del siguiente usuario');
          }
        }
      }
    } catch (e) {
      _controller.logPreloadError(e);
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

    // CRÍTICO: Pausar el video actual antes de cambiar de historia
    final currentStory = stories[_currentStoryIndex];
    if (currentStory.mediaType == 'video' && _videoControllers.containsKey(currentStory.id)) {
      _videoControllers[currentStory.id]?.pause();
      _controller.logVideoPaused(currentStory.id);
    }

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
      // No iniciar timer aquí - esperará a que _onStoryLoaded() lo inicie
      _markCurrentStoryAsViewed();
    } else {
      // Usuario anterior
      _previousUser();
    }
  }

  void _nextUser() async {
    if (_currentUserIndex < widget.allUserStories.length - 1) {
      // Incrementar contador de grupos de historias visualizados
      _controller.nextUser();

      // Verificar si debemos mostrar un ad
      final shouldShowAd = _controller.shouldShowAd();

      if (shouldShowAd && _isNativeAdLoaded && _nativeAd != null) {
        _controller.logAdShowing();
        // Pausar el timer de historias mientras se muestra el ad
        _pauseStoryTimer();

        // Mostrar Native Ad como overlay fullscreen (como una historia más)
        final adCompleted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.black,
          builder: (context) => StoryNativeAdWidget(
            nativeAd: _nativeAd!,
            onAdCompleted: () {
              Navigator.of(context).pop(true);
            },
          ),
        );

        if (adCompleted == true) {
          _controller.logAdCompleted();
          // Cargar el siguiente ad para la próxima vez
          _loadNativeAd();
        }
      } else if (shouldShowAd) {
        _controller.logAdNotAvailable();
      }

      // Verificar que el widget aún está montado antes de continuar
      if (!mounted) {
        _controller.logWidgetUnmounted();
        return;
      }

      setState(() {
        _currentUserIndex++;
        // Calcular índice inicial de la primera historia no vista del nuevo grupo
        final stories = _getStoriesForUser(widget.allUserStories[_currentUserIndex]);
        _currentStoryIndex = _getInitialStoryIndex(stories);
        _isCurrentStoryLoaded = false; // Reset para la nueva historia
      });
      _userPageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      // No iniciar timer aquí - esperará a que _onStoryLoaded() lo inicie
      _markCurrentStoryAsViewed();
    } else {
      Navigator.pop(context);
    }
  }

  void _previousUser() {
    if (_currentUserIndex > 0) {
      setState(() {
        _currentUserIndex--;
        // Calcular índice inicial de la primera historia no vista del nuevo grupo
        final stories = _getStoriesForUser(widget.allUserStories[_currentUserIndex]);
        _currentStoryIndex = _getInitialStoryIndex(stories);
        _isCurrentStoryLoaded = false; // Reset para la nueva historia
      });
      _userPageController.previousPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      // No iniciar timer aquí - esperará a que _onStoryLoaded() lo inicie
      _markCurrentStoryAsViewed();
    }
  }

  void _markCurrentStoryAsViewed() {
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);
    final currentStory = stories[_currentStoryIndex];
    _controller.markStoryAsViewed(currentStory.id);
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
      await _controller.deleteStory(currentStory.id);

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
      _controller.replyToStory(
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
        return false; // Return value for catchError
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

  Widget _buildVideoPlayer(Story story) {
    // Si el video controller no existe para esta historia, crear uno nuevo
    if (!_videoControllers.containsKey(story.id)) {
      _controller.logVideoControllerCreated(story.id);
      final newController = VideoPlayerController.networkUrl(
        Uri.parse(story.mediaUrl),
      );
      _videoControllers[story.id] = newController;

      newController.initialize().then((_) {
        if (mounted) {
          setState(() {});
          newController.play();
          newController.setLooping(true);

          // CRÍTICO: Esperar a que el video REALMENTE esté reproduciendo
          void videoPlayingListener() {
            if (mounted &&
                newController.value.isPlaying &&
                !_isCurrentStoryLoaded &&
                newController.value.position.inMilliseconds > 0) {
              _controller.logVideoPlaying();
              _onStoryLoaded();
              newController.removeListener(videoPlayingListener);
            }
          }
          newController.addListener(videoPlayingListener);
        }
      }).catchError((error) {
        _controller.logVideoError(error);
      });
    }

    final controller = _videoControllers[story.id]!;
    if (!controller.value.isInitialized) {
      return Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    // Preservar aspect ratio con cover fit
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;
        final screenAspectRatio = screenWidth / screenHeight;
        final videoAspectRatio = controller.value.aspectRatio;

        double videoWidth;
        double videoHeight;

        if (screenAspectRatio > videoAspectRatio) {
          // Pantalla más ancha que video - ajustar por ancho
          videoWidth = screenWidth;
          videoHeight = screenWidth / videoAspectRatio;
        } else {
          // Pantalla más alta que video - ajustar por alto
          videoHeight = screenHeight;
          videoWidth = screenHeight * videoAspectRatio;
        }

        return Center(
          child: SizedBox(
            width: videoWidth,
            height: videoHeight,
            child: VideoPlayer(controller),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _storyTimer?.cancel();
    _progressController.dispose();
    _userPageController.dispose();
    _storyPageController.dispose();
    _replyController.dispose();
    _replyFocusNode.dispose();

    // Limpiar Native Ad
    _nativeAd?.dispose();

    // Limpiar todos los video controllers
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();

    // Limpiar controller
    _controller.dispose();

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
            // Contenido principal de historias
            StoryContentWidget(
              userPageController: _userPageController,
              storyPageController: _storyPageController,
              allUserStories: widget.allUserStories,
              currentUserIndex: _currentUserIndex,
              currentStoryIndex: _currentStoryIndex,
              isCurrentStoryLoaded: _isCurrentStoryLoaded,
              videoControllers: _videoControllers,
              onStoryLoaded: _onStoryLoaded,
              onUserChanged: (index) {
                setState(() {
                  _currentUserIndex = index;
                  _currentStoryIndex = 0;
                  _isCurrentStoryLoaded = false;
                });
                _markCurrentStoryAsViewed();
              },
              onStoryChanged: (storyIndex) {
                setState(() {
                  _currentStoryIndex = storyIndex;
                  _isCurrentStoryLoaded = false;
                });
                _markCurrentStoryAsViewed();
              },
              controller: _controller,
              buildVideoPlayer: _buildVideoPlayer,
            ),

            // Overlay con controles
            StoryOverlayWidget(
              allUserStories: widget.allUserStories,
              currentUserIndex: _currentUserIndex,
              currentStoryIndex: _currentStoryIndex,
              progressController: _progressController,
              controller: _controller,
              onClose: () => Navigator.pop(context),
              onDelete: _deleteCurrentStory,
              replyController: _replyController,
              replyFocusNode: _replyFocusNode,
              onSendReply: _sendReply,
              getStoriesForUser: _getStoriesForUser,
              formatStoryTime: _formatStoryTime,
            ),

            // Campo de respuesta
            StoryReplySection(
              currentUserId: _controller.currentUserId ?? '',
              storyUserId: widget.allUserStories[_currentUserIndex].userId,
              replyController: _replyController,
              replyFocusNode: _replyFocusNode,
              onSendReply: _sendReply,
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