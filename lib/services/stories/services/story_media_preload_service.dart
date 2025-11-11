import 'dart:async';
import 'package:http/http.dart' as http;
import '../../../models/story.dart';
import '../../../utils/release_logger.dart';

/// Servicio para preload de medios de historias integrado con el sistema principal
///
/// Responsabilidades:
/// - Preload de imágenes y videos de historias
/// - Gestión inteligente de tracking de preload
/// - Integración con StoryOrchestrator
/// - Limpieza automática de tracking expirado
class StoryMediaPreloadService {

  // Cache usando CachedNetworkImageProvider

  // Control de preload
  final Set<String> _preloadedUrls = {};
  final Set<String> _preloadingUrls = {};
  final Map<String, DateTime> _preloadTimes = {};

  // Configuración
  static const int _maxConcurrentPreloads = 3;
  static const Duration _preloadTimeout = Duration(minutes: 2);
  static const Duration _cacheCleanupInterval = Duration(hours: 1);

  // Timer para limpieza
  Timer? _cleanupTimer;

  // Métricas
  int _totalPreloads = 0;
  int _successfulPreloads = 0;
  int _failedPreloads = 0;
  int _cacheHits = 0;

  /// Inicializar el servicio
  void initialize() {
    // Iniciar timer de limpieza periódica
    _cleanupTimer = Timer.periodic(_cacheCleanupInterval, (_) => _cleanupExpiredCache());

    ReleaseLogger.log('✅ StoryMediaPreloadService inicializado', tag: 'MediaPreload');
  }

  /// Precargar historias cuando se actualizan en el cache
  Future<void> preloadStoriesFromCache(List<UserStories> userStoriesList) async {
    final allStories = <Story>[];

    // Extraer todas las historias
    for (final userStories in userStoriesList) {
      allStories.addAll(userStories.stories);
    }

    // Filtrar historias que deberían ser precargadas
    final filteredStories = allStories.where(_shouldPreloadStory).toList();

    if (filteredStories.isNotEmpty) {
      ReleaseLogger.log('📱 Precargando ${filteredStories.length} historias detectadas en cache', tag: 'MediaPreload');
      await _preloadStories(filteredStories);
    }
  }

  /// Precargar una lista de historias
  Future<void> _preloadStories(List<Story> stories) async {
    if (stories.isEmpty) return;

    final List<Future<void>> preloadTasks = [];
    int concurrentCount = 0;

    for (final story in stories) {
      if (concurrentCount >= _maxConcurrentPreloads) {
        // Esperar a que terminen las tareas actuales antes de continuar
        await Future.wait(preloadTasks);
        preloadTasks.clear();
        concurrentCount = 0;
      }

      if (!_preloadedUrls.contains(story.mediaUrl) &&
          !_preloadingUrls.contains(story.mediaUrl)) {
        final task = _preloadSingleStory(story);
        preloadTasks.add(task);
        concurrentCount++;
      }
    }

    if (preloadTasks.isNotEmpty) {
      await Future.wait(preloadTasks);
    }
  }

  /// Precargar una historia individual
  Future<void> _preloadSingleStory(Story story) async {
    if (_preloadingUrls.contains(story.mediaUrl)) return;

    _preloadingUrls.add(story.mediaUrl);
    _totalPreloads++;

    try {
      ReleaseLogger.log('⬇️ Precargando ${story.mediaType}: ${story.mediaUrl.substring(0, 50)}...', tag: 'MediaPreload');

      final stopwatch = Stopwatch()..start();

      // Descargar archivo completo para realmente precargarlo
      final response = await http.get(Uri.parse(story.mediaUrl))
          .timeout(_preloadTimeout);

      stopwatch.stop();

      if (response.statusCode == 200) {
        _preloadedUrls.add(story.mediaUrl);
        _preloadTimes[story.mediaUrl] = DateTime.now();
        _successfulPreloads++;

        final sizeKb = response.contentLength != null
            ? response.contentLength! ~/ 1024
            : response.bodyBytes.length ~/ 1024;

        ReleaseLogger.log(
          '✅ Precarga exitosa ${story.mediaType} (${sizeKb}KB en ${stopwatch.elapsedMilliseconds}ms): ${story.id}',
          tag: 'MediaPreload'
        );
      } else {
        _failedPreloads++;
        ReleaseLogger.error('❌ Error precargando historia ${story.id}: HTTP ${response.statusCode}', tag: 'MediaPreload');
      }

    } catch (e) {
      _failedPreloads++;
      ReleaseLogger.error('❌ Error precargando historia ${story.id}: $e', tag: 'MediaPreload');
    } finally {
      _preloadingUrls.remove(story.mediaUrl);
    }
  }

  /// Verificar si una historia debe ser precargada
  bool _shouldPreloadStory(Story story) {
    // No precargar si ya está en cache
    if (_preloadedUrls.contains(story.mediaUrl)) {
      return false;
    }

    // No precargar si ya está en proceso
    if (_preloadingUrls.contains(story.mediaUrl)) {
      return false;
    }

    // No precargar historias expiradas
    if (story.isExpired) {
      return false;
    }

    // Solo precargar historias aprobadas
    if (story.status != StoryStatus.approved) {
      return false;
    }

    // Solo precargar historias temporales (visibles en feed)
    if (story.visibility != StoryVisibility.temporary) {
      return false;
    }

    // Verificar que la URL sea válida
    if (story.mediaUrl.isEmpty) {
      return false;
    }

    return true;
  }

  /// Verificar si una historia ya está precargada
  bool isStoryPreloaded(String mediaUrl) {
    if (_preloadedUrls.contains(mediaUrl)) {
      _cacheHits++;
      return true;
    }
    return false;
  }

  /// Limpiar cache de historias expiradas
  Future<void> _cleanupExpiredCache() async {
    try {
      ReleaseLogger.log('🧹 Iniciando limpieza de cache de historias expiradas...', tag: 'MediaPreload');

      final now = DateTime.now();
      final expiredUrls = <String>[];

      // Encontrar URLs de historias que han estado en cache por más de 24 horas
      _preloadTimes.forEach((url, preloadTime) {
        if (now.difference(preloadTime).inHours > 24) {
          expiredUrls.add(url);
        }
      });

      // Remover de tracking
      for (final url in expiredUrls) {
        _preloadedUrls.remove(url);
        _preloadTimes.remove(url);
      }

      // Cache limpiado - URLs expiradas removidas del tracking

      if (expiredUrls.isNotEmpty) {
        ReleaseLogger.log('🗑️ Limpiadas ${expiredUrls.length} historias expiradas del cache', tag: 'MediaPreload');
      }

    } catch (e) {
      ReleaseLogger.error('❌ Error en limpieza de cache: $e', tag: 'MediaPreload');
    }
  }

  /// Obtener métricas del servicio
  Map<String, dynamic> getMetrics() {
    final successRate = _totalPreloads > 0 ? _successfulPreloads / _totalPreloads : 0.0;

    return {
      'totalPreloads': _totalPreloads,
      'successfulPreloads': _successfulPreloads,
      'failedPreloads': _failedPreloads,
      'successRate': successRate,
      'cacheHits': _cacheHits,
      'currentlyCached': _preloadedUrls.length,
      'currentlyPreloading': _preloadingUrls.length,
    };
  }

  /// Limpiar recursos
  void dispose() {
    _cleanupTimer?.cancel();
    _preloadedUrls.clear();
    _preloadingUrls.clear();
    _preloadTimes.clear();
    ReleaseLogger.log('🧹 StoryMediaPreloadService disposed', tag: 'MediaPreload');
  }
}