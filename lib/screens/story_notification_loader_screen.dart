import 'dart:async';

import 'package:flutter/material.dart';

import '../models/trivia.dart';
import '../services/story_service_refactored.dart';
import '../theme_service.dart';
import '../utils/release_logger.dart';
import 'story_viewer_screen.dart';

/// Pantalla puente que se abre al tocar una notificación de historia
/// ("X tiene una nueva historia"). Muestra un loading mientras se asegura de
/// que la historia esté disponible en el cache (la recién creada puede no haber
/// sincronizado todavía); recién ahí abre el StoryViewerScreen.
///
/// Evita el bug de "abrir y que falle porque no la detecta": en vez de navegar
/// a ciegas, esperamos (con timeout) a que la historia aparezca.
class StoryNotificationLoaderScreen extends StatefulWidget {
  final String storyId;
  final String ownerId;
  final List<Trivia>? trivias;

  const StoryNotificationLoaderScreen({
    super.key,
    required this.storyId,
    required this.ownerId,
    this.trivias,
  });

  @override
  State<StoryNotificationLoaderScreen> createState() =>
      _StoryNotificationLoaderScreenState();
}

class _StoryNotificationLoaderScreenState
    extends State<StoryNotificationLoaderScreen> {
  final StoryService _storyService = StoryService();
  static const Duration _timeout = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Busca, en una lista de UserStories, la del dueño que contenga la historia.
  UserStories? _findOwnerWithStory(List<UserStories> all) {
    for (final us in all) {
      if (us.userId == widget.ownerId &&
          us.stories.any((s) => s.id == widget.storyId)) {
        return us;
      }
    }
    return null;
  }

  Future<void> _load() async {
    try {
      // 1. Intento inmediato con lo que ya está en cache.
      UserStories? owner = _findOwnerWithStory(_storyService.getCachedStories());

      // 2. Si no está, forzar refresh y esperar a que aparezca (con timeout).
      if (owner == null) {
        _storyService.forceRefreshCache().catchError((e) {
          ReleaseLogger.warning('forceRefreshCache falló: $e', tag: 'StoryLoader');
        });
        owner = await _waitForStory();
      }

      if (!mounted) return;

      if (owner != null) {
        final idx = owner.stories.indexWhere((s) => s.id == widget.storyId);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => StoryViewerScreen(
              allUserStories: [owner!],
              initialUserIndex: 0,
              initialStoryIndex: idx >= 0 ? idx : null,
              trivias: widget.trivias,
            ),
          ),
        );
      } else {
        _failAndExit('No pudimos abrir la historia. Puede que ya no esté disponible.');
      }
    } catch (e) {
      ReleaseLogger.error('Error abriendo historia desde notificación: $e',
          tag: 'StoryLoader');
      _failAndExit('No pudimos abrir la historia.');
    }
  }

  /// Escucha el stream del cache hasta que la historia aparezca, o se agote el
  /// timeout. Devuelve la UserStories del dueño o null.
  Future<UserStories?> _waitForStory() {
    final completer = Completer<UserStories?>();
    StreamSubscription<List<UserStories>>? sub;
    Timer? timer;

    void finish(UserStories? result) {
      if (completer.isCompleted) return;
      timer?.cancel();
      sub?.cancel();
      completer.complete(result);
    }

    timer = Timer(_timeout, () => finish(null));
    sub = _storyService.storiesFromCache.listen(
      (all) {
        final owner = _findOwnerWithStory(all);
        if (owner != null) finish(owner);
      },
      onError: (_) {},
    );

    return completer.future;
  }

  void _failAndExit(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: ThemeService.primaryColor),
            const SizedBox(height: 16),
            const Text(
              'Abriendo historia...',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
