import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import '../models/mood_poll.dart';
import '../controllers/story_viewer_controller.dart';
import '../services/ad_service.dart';
import '../services/mood_polls/mood_poll_service.dart';
import '../services/story_service_refactored.dart';
import '../services/video_cache_service.dart';
import '../services/deep_link_service.dart';
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
  // Set para trackear videos que están siendo cargados desde cache
  final Set<String> _loadingVideos = {};

  // Controlador para respuestas
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  bool _isSendingReply = false;

  // Estado local de likes (para UI optimista)
  final Set<String> _localLikedStories = {};

  // Copia local mutable de las historias (se actualiza via cache stream)
  late List<UserStories> _allUserStories;

  // Subscription al cache stream para actualizaciones en tiempo real
  StreamSubscription<List<UserStories>>? _cacheSubscription;
  final StoryService _storyService = StoryService();

  // Swipe down para cerrar - offset vertical del drag
  double _dragOffset = 0.0;

  // Flag para deshabilitar gestos cuando un bottom sheet está abierto
  bool _isBottomSheetOpen = false;

  // Para trackear posición inicial del gesto
  Offset? _gestureStartPosition;

  // Obtener las historias apropiadas para cada usuario
  List<Story> _getStoriesForUser(UserStories userStories) {
    return _controller.getStoriesForUser(userStories);
  }

  // Calcular el índice de la primera historia NO vista de un grupo
  int _getInitialStoryIndex(List<Story> stories) {
    return _controller.getInitialStoryIndex(stories);
  }

  /// Suscribirse al cache stream para actualizaciones en tiempo real de likes/replies
  void _subscribeToCacheChanges() {
    _cacheSubscription = _storyService.storiesFromCache.listen((updatedStories) {
      if (!mounted) return;

      // Buscar y actualizar las historias que cambiaron
      bool hasChanges = false;

      for (int userIndex = 0; userIndex < _allUserStories.length; userIndex++) {
        final localUserStories = _allUserStories[userIndex];

        // Buscar este usuario en las historias actualizadas
        final updatedUserStories = updatedStories
            .where((us) => us.userId == localUserStories.userId)
            .firstOrNull;

        if (updatedUserStories == null) continue;

        // Comparar y actualizar cada historia
        for (int storyIndex = 0; storyIndex < localUserStories.stories.length; storyIndex++) {
          final localStory = localUserStories.stories[storyIndex];

          // Buscar esta historia en las actualizadas
          final updatedStory = updatedUserStories.stories
              .where((s) => s.id == localStory.id)
              .firstOrNull;

          if (updatedStory == null) continue;

          // Verificar si hay cambios en likes o replies
          final likesChanged = localStory.likedBy.length != updatedStory.likedBy.length ||
              !_listEquals(localStory.likedBy, updatedStory.likedBy);
          final repliesChanged = localStory.replies.length != updatedStory.replies.length;

          if (likesChanged || repliesChanged) {
            // Actualizar la historia local con los nuevos datos
            localUserStories.stories[storyIndex] = updatedStory;
            hasChanges = true;
          }
        }
      }

      // Solo reconstruir si hubo cambios reales
      if (hasChanges) {
        setState(() {});
      }
    });
  }

  /// Comparar dos listas de strings
  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();

    // Inicializar copia local mutable de las historias
    _allUserStories = List.from(widget.allUserStories);

    // Inicializar el controller
    _controller = StoryViewerController(
      allUserStories: _allUserStories,
      initialUserIndex: widget.initialUserIndex,
    );
    _controller.initialize();

    // Suscribirse al cache stream para actualizaciones en tiempo real
    _subscribeToCacheChanges();

    // Validate and clamp initial user index
    _currentUserIndex = widget.initialUserIndex.clamp(0, _allUserStories.length - 1);

    // Calcular el índice de la primera historia NO vista del grupo actual
    final currentUserStories = _allUserStories[_currentUserIndex];
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
  /// Primero intenta usar el ad pre-cargado, si no está disponible crea uno nuevo
  Future<void> _loadNativeAd() async {
    // Log debug info
    final debugInfo = _adService.getNativeAdDebugInfo();
    _controller.logDebug('📊 [StoryViewer] Estado Native Ad: $debugInfo');

    // 1. Primero intentar usar el ad pre-cargado (instantáneo)
    final cachedAd = _adService.consumeCachedNativeAd();
    if (cachedAd != null) {
      _controller.logDebug('✅ [StoryViewer] Usando ad pre-cargado');
      if (mounted) {
        setState(() {
          _nativeAd = cachedAd;
          _isNativeAdLoaded = true;
        });
        _controller.logNativeAdLoaded();
      }
      return;
    }

    _controller.logDebug('⚠️ [StoryViewer] No hay ad pre-cargado, creando nuevo...');

    // 2. Si no hay ad pre-cargado, crear uno nuevo (puede tardar)
    final ad = await _adService.createStoryNativeAd(
      onAdLoaded: (ad) {
        _controller.logDebug('✅ [StoryViewer] Ad nuevo cargado exitosamente');
        if (mounted) {
          setState(() {
            _nativeAd = ad;
            _isNativeAdLoaded = true;
          });
          _controller.logNativeAdLoaded();
        }
      },
      onAdFailedToLoad: (ad, error) {
        _controller.logDebug('❌ [StoryViewer] Error cargando ad nuevo: ${error.message}');
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
      _controller.logDebug('📝 [StoryViewer] Ad creado, esperando onAdLoaded callback');
      setState(() {
        _nativeAd = ad;
        _isNativeAdLoaded = false; // Se marcará true en onAdLoaded
      });
    } else {
      _controller.logDebug('⚠️ [StoryViewer] createStoryNativeAd retornó null');
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
      final currentUserStories = _allUserStories[_currentUserIndex];
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
             userIndex < _allUserStories.length && upcomingStories.length < 3;
             userIndex++) {

          final nextUserStories = _allUserStories[userIndex];
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

  /// Llamado cuando se abre un bottom sheet (likes, respuestas)
  void _onBottomSheetOpened() {
    setState(() {
      _isBottomSheetOpen = true;
    });
    _pauseStoryTimer();
  }

  /// Llamado cuando se cierra un bottom sheet
  void _onBottomSheetClosed() {
    setState(() {
      _isBottomSheetOpen = false;
    });
    _resumeStoryTimer();
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
    final currentUserStories = _allUserStories[_currentUserIndex];
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

    if (_currentUserIndex < _allUserStories.length - 1) {
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
        final stories = _getStoriesForUser(_allUserStories[_currentUserIndex]);
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
        final stories = _getStoriesForUser(_allUserStories[_currentUserIndex]);
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
    final currentUserStories = _allUserStories[_currentUserIndex];
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
      final currentUserStories = _allUserStories[_currentUserIndex];
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

  /// Descargar la historia actual a la galería del dispositivo
  Future<void> _downloadCurrentStory() async {
    _pauseStoryTimer();

    try {
      final currentUserStories = _allUserStories[_currentUserIndex];
      final stories = _getStoriesForUser(currentUserStories);
      final currentStory = stories[_currentStoryIndex];

      // Verificar que sea una historia con media descargable (no mood)
      if (currentStory.mediaType == 'mood' ||
          !currentStory.mediaUrl.startsWith('http')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Este tipo de historia no se puede descargar'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
        _resumeStoryTimer();
        return;
      }

      // Mostrar indicador de descarga
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12),
                Text('Descargando...'),
              ],
            ),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 10),
          ),
        );
      }

      // Descargar el archivo
      final response = await http.get(Uri.parse(currentStory.mediaUrl));
      if (response.statusCode != 200) {
        throw Exception('Error descargando archivo');
      }

      // Determinar extensión
      final isVideo = currentStory.mediaType == 'video';
      final extension = isVideo ? 'mp4' : 'jpg';
      final fileName = 'talia_story_${DateTime.now().millisecondsSinceEpoch}.$extension';

      // Guardar temporalmente
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(response.bodyBytes);

      // Guardar en galería usando gal
      if (isVideo) {
        await Gal.putVideo(tempFile.path, album: 'Talia');
      } else {
        await Gal.putImage(tempFile.path, album: 'Talia');
      }

      // Eliminar archivo temporal
      await tempFile.delete();

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al descargar: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      _resumeStoryTimer();
    }
  }

  /// Compartir la historia actual en redes sociales (Instagram, WhatsApp, etc.)
  Future<void> _shareCurrentStory() async {
    _pauseStoryTimer();

    try {
      final currentUserStories = _allUserStories[_currentUserIndex];
      final stories = _getStoriesForUser(currentUserStories);
      final currentStory = stories[_currentStoryIndex];

      // Verificar que sea una historia compartible (no mood)
      if (currentStory.mediaType == 'mood') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Este tipo de historia no se puede compartir'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
        _resumeStoryTimer();
        return;
      }

      // Generar URL de la historia usando DeepLinkService
      final storyUrl = DeepLinkService().generateStoryUrl(currentStory.id);

      // Construir mensaje para compartir
      final caption = currentStory.caption?.trim();
      final hasCaption = caption != null && caption.isNotEmpty;

      // Texto a compartir: caption (si existe) + link
      final shareText = hasCaption
          ? '$caption\n\n$storyUrl'
          : '¡Mira mi historia en Talia!\n$storyUrl';

      // Compartir el link
      await SharePlus.instance.share(
        ShareParams(
          text: shareText,
          subject: 'Historia de Talia',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al compartir: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      _resumeStoryTimer();
    }
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _isSendingReply) return;

    setState(() {
      _isSendingReply = true;
    });

    try {
      final currentUserStories = _allUserStories[_currentUserIndex];
      final stories = _getStoriesForUser(currentUserStories);
      final currentStory = stories[_currentStoryIndex];

      // Limpiar input y cerrar teclado INMEDIATAMENTE (optimista)
      _replyController.clear();
      _replyFocusNode.unfocus();

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
    final currentUserStories = _allUserStories[_currentUserIndex];
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
    if (!_videoControllers.containsKey(story.id) && !_loadingVideos.contains(story.id)) {
      _controller.logVideoControllerCreated(story.id);

      // Usar archivo local si existe (mientras se sube)
      if (story.localMediaPath != null && story.localMediaPath!.isNotEmpty) {
        final newController = VideoPlayerController.file(
          File(story.localMediaPath!),
        );
        _videoControllers[story.id] = newController;
        _initializeVideoController(newController, story.id);
      } else {
        // Para videos de red, usar cache service (async)
        _loadingVideos.add(story.id);
        _loadVideoFromCache(story);
      }
    }

    // Si está cargando o no existe el controller, mostrar loading
    if (!_videoControllers.containsKey(story.id)) {
      return Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
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

  /// Cargar video desde cache de forma async
  Future<void> _loadVideoFromCache(Story story) async {
    try {
      final controller = await VideoCacheService().getController(story.mediaUrl);
      if (!mounted) {
        controller.dispose();
        return;
      }
      _videoControllers[story.id] = controller;
      _loadingVideos.remove(story.id);
      _initializeVideoController(controller, story.id);
    } catch (e) {
      _loadingVideos.remove(story.id);
      _controller.logVideoError(e);
    }
  }

  /// Inicializar controller de video y configurar listeners
  void _initializeVideoController(VideoPlayerController controller, String storyId) {
    controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        controller.play();
        controller.setLooping(true);

        // CRÍTICO: Esperar a que el video REALMENTE esté reproduciendo
        void videoPlayingListener() {
          if (mounted &&
              controller.value.isPlaying &&
              !_isCurrentStoryLoaded &&
              controller.value.position.inMilliseconds > 0) {
            _controller.logVideoPlaying();
            _onStoryLoaded();
            controller.removeListener(videoPlayingListener);
          }
        }
        controller.addListener(videoPlayingListener);
      }
    }).catchError((error) {
      _controller.logVideoError(error);
    });
  }

  @override
  void dispose() {
    _storyTimer?.cancel();
    _progressController.dispose();
    _userPageController.dispose();
    _storyPageController.dispose();
    _replyController.dispose();
    _replyFocusNode.dispose();

    // Cancelar suscripción al cache stream
    _cacheSubscription?.cancel();

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
    if (_allUserStories.isEmpty) {
      // No stories to show, close viewer
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return const Scaffold(backgroundColor: Colors.black);
    }

    // Clamp _currentUserIndex to valid range
    if (_currentUserIndex >= _allUserStories.length) {
      _currentUserIndex = _allUserStories.length - 1;
    }
    if (_currentUserIndex < 0) {
      _currentUserIndex = 0;
    }

    // Validate _currentStoryIndex for current user
    final currentUserStories = _allUserStories[_currentUserIndex];
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
        // Taps para cambiar historia y mantener presionado para pausar
        onTapDown: _isBottomSheetOpen ? null : (details) {
          _gestureStartPosition = details.localPosition;
          _pauseStoryTimer();
        },
        onTapUp: _isBottomSheetOpen ? null : (details) {
          final gestureStart = _gestureStartPosition;
          _gestureStartPosition = null;

          // Si el teclado está abierto, cerrarlo
          if (_replyFocusNode.hasFocus) {
            _replyFocusNode.unfocus();
            return;
          }

          final screenWidth = MediaQuery.of(context).size.width;
          final tapX = gestureStart?.dx ?? details.localPosition.dx;

          if (tapX < screenWidth / 3) {
            _previousStory();
          } else if (tapX > screenWidth * 2 / 3) {
            _nextStory();
          } else {
            _resumeStoryTimer();
          }
        },
        onTapCancel: _isBottomSheetOpen ? null : () {
          _gestureStartPosition = null;
          _resumeStoryTimer();
        },
        // Solo swipe vertical para cerrar (el horizontal lo maneja el PageView)
        onVerticalDragStart: _isBottomSheetOpen ? null : (_) {
          _pauseStoryTimer();
        },
        onVerticalDragUpdate: _isBottomSheetOpen ? null : (details) {
          // Solo permitir arrastrar hacia abajo
          if (details.delta.dy > 0 || _dragOffset > 0) {
            setState(() {
              _dragOffset = (_dragOffset + details.delta.dy).clamp(0.0, double.infinity);
            });
          }
        },
        onVerticalDragEnd: _isBottomSheetOpen ? null : (details) {
          final screenHeight = MediaQuery.of(context).size.height;
          // Si se arrastró más del 20% de la pantalla o con velocidad alta, cerrar
          if (_dragOffset > screenHeight * 0.2 ||
              (details.primaryVelocity != null && details.primaryVelocity! > 500)) {
            Navigator.pop(context);
          } else {
            // Volver a la posición original con animación
            setState(() {
              _dragOffset = 0.0;
            });
            _resumeStoryTimer();
          }
        },
        child: Transform.translate(
          offset: Offset(0, _dragOffset),
          child: Opacity(
            // Reducir opacidad mientras se arrastra
            opacity: (1 - (_dragOffset / 500)).clamp(0.5, 1.0),
            child: Stack(
          children: [
            // Contenido principal de historias
            StoryContentWidget(
              userPageController: _userPageController,
              storyPageController: _storyPageController,
              allUserStories: _allUserStories,
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
              // Mostrar caption en overlay sobre el contenido
              showCaptionOverlay: true,
              // Si NO es historia propia, hay input de respuesta abajo
              hasReplyInput: _allUserStories[_currentUserIndex].userId != _controller.currentUserId,
            ),

            // Overlay con controles
            StoryOverlayWidget(
              allUserStories: _allUserStories,
              currentUserIndex: _currentUserIndex,
              currentStoryIndex: _currentStoryIndex,
              progressController: _progressController,
              controller: _controller,
              onClose: () => Navigator.pop(context),
              onDelete: _deleteCurrentStory,
              onDownload: _downloadCurrentStory,
              onShare: _shareCurrentStory,
              replyController: _replyController,
              replyFocusNode: _replyFocusNode,
              onSendReply: _sendReply,
              getStoriesForUser: _getStoriesForUser,
              formatStoryTime: _formatStoryTime,
              onPauseTimer: _onBottomSheetOpened,
              onResumeTimer: _onBottomSheetClosed,
            ),

            // Campo de respuesta (con botón de like)
            StoryReplySection(
              currentUserId: _controller.currentUserId ?? '',
              storyUserId: _allUserStories[_currentUserIndex].userId,
              replyController: _replyController,
              replyFocusNode: _replyFocusNode,
              onSendReply: _sendReply,
              isLiked: _isStoryLiked(_getStoriesForUser(_allUserStories[_currentUserIndex])[_currentStoryIndex]),
              onLikeToggle: _toggleLike,
            ),
          ],
        ),
          ),
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