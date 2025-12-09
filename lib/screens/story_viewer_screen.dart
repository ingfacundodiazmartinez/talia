import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../models/story.dart';
import '../models/mood_poll.dart';
import '../controllers/story_viewer_controller.dart';
import '../services/ad_service.dart';
import '../services/mood_polls/mood_poll_service.dart';
import '../widgets/story_native_ad_widget.dart';
import '../widgets/mood_poll_story_widget.dart';
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
  final MoodPollService _moodPollService = MoodPollService();
  final Duration _storyDuration = Duration(seconds: 5);

  // Native Ad pre-cargado para mostrar entre historias
  NativeAd? _nativeAd;
  bool _isNativeAdLoaded = false;

  // Mood Poll pre-cargado para mostrar entre historias
  MoodPollQuestion? _pendingPollQuestion;
  bool _hasPollBeenShown = false; // Para no mostrar más de una vez por sesión

  // VideoPlayerController map para manejar múltiples videos
  final Map<String, VideoPlayerController> _videoControllers = {};

  // Controlador para respuestas
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  bool _isSendingReply = false;

  // Estado local de likes (para UI optimista)
  final Set<String> _localLikedStories = {};

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

    // Validate and clamp initial user index
    _currentUserIndex = widget.initialUserIndex.clamp(0, widget.allUserStories.length - 1);

    // Calcular el índice de la primera historia NO vista del grupo actual
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);
    final initialStoryIndex = stories.isNotEmpty ? _getInitialStoryIndex(stories) : 0;

    _currentStoryIndex = initialStoryIndex;
    _userPageController = PageController(initialPage: _currentUserIndex);
    _storyPageController = PageController(initialPage: initialStoryIndex);
    _progressController = AnimationController(
      vsync: this,
      duration: _storyDuration,
    );

    // Inicializar y pre-cargar ads para monetización
    _initializeAds();

    // Pre-cargar mood poll (solo para hijos)
    _loadMoodPoll();

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

  /// Pre-cargar mood poll para mostrar al final de las historias
  Future<void> _loadMoodPoll() async {
    try {
      // Verificar si el usuario actual es un hijo (no un padre)
      // Solo los hijos responden encuestas de mood
      if (!_controller.isChildUser()) return;

      // Obtener una pregunta aleatoria (siempre, sin probabilidad)
      // El servicio ya filtra las que ya fueron respondidas esta semana
      final question = await _moodPollService.getRandomQuestion();
      if (mounted) {
        setState(() {
          _pendingPollQuestion = question;
        });
      }
    } catch (e) {
      // Silently fail - polls are not critical
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

    // Cancelar timer anterior si existe
    _storyTimer?.cancel();

    // ✅ FIX: Resetear el progress controller ANTES de iniciar
    // Esto asegura que siempre empiece desde 0
    _progressController.reset();

    // Esperar un frame para asegurar que el reset visual se complete
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isCurrentStoryLoaded) {
        // Iniciar animación desde 0
        _progressController.forward(from: 0.0);

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
      final upcomingStories = <Story>[];

      // ✅ MEJORADO: Precargar las próximas 3 historias del mismo usuario
      final remainingStoriesInCurrentUser = stories.sublist(_currentStoryIndex + 1);
      final nextStoriesFromCurrentUser = remainingStoriesInCurrentUser.take(3).toList();

      for (final story in nextStoriesFromCurrentUser) {
        upcomingStories.add(story);
        // ✅ MANTENER COMPATIBILIDAD: Seguir usando precacheImage para imágenes inmediatas
        if (story.mediaType == 'image') {
          precacheImage(CachedNetworkImageProvider(story.mediaUrl), context);
          _controller.logStoryPreloading('siguiente historia del mismo usuario');
        }
      }

      // ✅ MEJORADO: Si no hay suficientes historias del usuario actual, precargar historias de próximos usuarios
      if (upcomingStories.length < 3) {
        final remainingSlots = 3 - upcomingStories.length;

        for (int userIndex = _currentUserIndex + 1;
             userIndex < widget.allUserStories.length && upcomingStories.length < 3;
             userIndex++) {

          final nextUserStories = widget.allUserStories[userIndex];
          final nextUserStoriesList = _getStoriesForUser(nextUserStories);

          final storiesFromThisUser = nextUserStoriesList.take(remainingSlots - (upcomingStories.length - nextStoriesFromCurrentUser.length)).toList();

          for (final story in storiesFromThisUser) {
            upcomingStories.add(story);
            // ✅ MANTENER COMPATIBILIDAD: Seguir usando precacheImage para imágenes de próximos usuarios
            if (story.mediaType == 'image') {
              precacheImage(CachedNetworkImageProvider(story.mediaUrl), context);
              _controller.logStoryPreloading('primera historia de próximo usuario');
            }
          }
        }
      }

      // Media preloading is now handled automatically by StoryOrchestrator via background streams
      if (upcomingStories.isNotEmpty) {
        _controller.logStoryPreloading('${upcomingStories.length} próximas historias detectadas para preload automático');
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

    // ✅ FIX: Cancelar timer y resetear progreso inmediatamente
    _storyTimer?.cancel();
    _progressController.reset();

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
    // ✅ FIX: Cancelar timer y resetear progreso inmediatamente
    _storyTimer?.cancel();
    _progressController.reset();

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
    // ✅ FIX: Cancelar timer y resetear progreso inmediatamente
    _storyTimer?.cancel();
    _progressController.reset();

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

      // Ya no mostramos el mood poll aquí - se muestra al final de todas las historias

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
      // El usuario terminó de ver TODAS las historias
      // Mostrar mood poll antes de cerrar si hay una disponible
      await _showMoodPollBeforeClose();
    }
  }

  /// Mostrar mood poll al terminar de ver todas las historias
  Future<void> _showMoodPollBeforeClose() async {
    // Verificar si hay una encuesta pendiente y no se ha mostrado
    if (_pendingPollQuestion != null && !_hasPollBeenShown && _controller.isChildUser()) {
      _hasPollBeenShown = true;
      _pauseStoryTimer();

      await MoodPollDialog.show(
        context: context,
        question: _pendingPollQuestion!,
        onComplete: (response, shareAsStory) async {
          if (response != null && shareAsStory) {
            // Navegar a crear story con la respuesta
            await _shareResponseAsStory(response);
          }
          // Limpiar poll pendiente
          if (mounted) {
            setState(() {
              _pendingPollQuestion = null;
            });
          }
        },
      );

      // Verificar que el widget aún está montado
      if (!mounted) return;
    }

    // Cerrar el visor de historias
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _previousUser() {
    // ✅ FIX: Cancelar timer y resetear progreso inmediatamente
    _storyTimer?.cancel();
    _progressController.reset();

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

  /// Verificar si una historia está liked (combina estado local y del modelo)
  bool _isStoryLiked(Story story) {
    // Primero verificar estado local (para UI optimista)
    if (_localLikedStories.contains(story.id)) {
      return true;
    }
    // Luego verificar del modelo (estado persistido)
    return _controller.hasLikedStory(story);
  }

  /// Toggle like de una historia
  Future<void> _toggleLike() async {
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);
    final currentStory = stories[_currentStoryIndex];

    final isCurrentlyLiked = _isStoryLiked(currentStory);

    // UI optimista - actualizar inmediatamente
    setState(() {
      if (isCurrentlyLiked) {
        _localLikedStories.remove(currentStory.id);
      } else {
        _localLikedStories.add(currentStory.id);
      }
    });

    try {
      if (isCurrentlyLiked) {
        await _controller.unlikeStory(currentStory.id);
      } else {
        await _controller.likeStory(currentStory.id);
        // Mostrar feedback solo cuando se da like (no al quitar)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.favorite, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text('Le diste like a la historia'),
                ],
              ),
              backgroundColor: Colors.red.shade400,
              duration: Duration(milliseconds: 1200),
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
    } catch (e) {
      // Revertir cambio optimista en caso de error
      if (mounted) {
        setState(() {
          if (isCurrentlyLiked) {
            _localLikedStories.add(currentStory.id);
          } else {
            _localLikedStories.remove(currentStory.id);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al dar like'),
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

  /// Compartir respuesta de mood poll como historia
  Future<void> _shareResponseAsStory(MoodPollResponse response) async {
    try {
      // Crear una historia con el mood del usuario
      // El formato es un fondo de color con el emoji y texto
      await _controller.createMoodStory(
        emoji: response.selectedEmoji,
        text: response.selectedOptionText,
        questionText: response.questionText,
        responseId: response.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Text(response.selectedEmoji, style: TextStyle(fontSize: 20)),
                SizedBox(width: 8),
                Text('Historia compartida'),
              ],
            ),
            backgroundColor: Colors.green,
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al compartir'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
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

    // Usar FittedBox con BoxFit.contain para preservar aspect ratio correctamente
    // Esto maneja automáticamente videos de iOS que tienen rotación en metadatos
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
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
    // Bounds check: ensure indices are valid
    if (widget.allUserStories.isEmpty) {
      // No stories to show, close viewer
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return const Scaffold(backgroundColor: Colors.black);
    }

    // Clamp _currentUserIndex to valid range
    if (_currentUserIndex >= widget.allUserStories.length) {
      _currentUserIndex = widget.allUserStories.length - 1;
    }
    if (_currentUserIndex < 0) {
      _currentUserIndex = 0;
    }

    // Validate _currentStoryIndex for current user
    final currentUserStories = widget.allUserStories[_currentUserIndex];
    final stories = _getStoriesForUser(currentUserStories);
    if (stories.isEmpty) {
      // User has no viewable stories, close viewer
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return const Scaffold(backgroundColor: Colors.black);
    }
    if (_currentStoryIndex >= stories.length) {
      _currentStoryIndex = stories.length - 1;
    }
    if (_currentStoryIndex < 0) {
      _currentStoryIndex = 0;
    }

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

            // Campo de respuesta (con botón de like)
            StoryReplySection(
              currentUserId: _controller.currentUserId ?? '',
              storyUserId: widget.allUserStories[_currentUserIndex].userId,
              replyController: _replyController,
              replyFocusNode: _replyFocusNode,
              onSendReply: _sendReply,
              isLiked: _isStoryLiked(_getStoriesForUser(widget.allUserStories[_currentUserIndex])[_currentStoryIndex]),
              onLikeToggle: _toggleLike,
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