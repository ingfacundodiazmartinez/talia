import 'dart:async';
import '../../../models/story.dart';
import '../services/story_media_preload_service.dart';

/// Manager para gestión inteligente de cache de historias
///
/// Responsabilidades:
/// - Cache en memoria de historias
/// - Cache optimista para UX inmediata
/// - Gestión de TTL y limpieza automática
/// - Deduplicación y ordenamiento
/// - NO accede a Firestore directamente
class StoryCacheManager {
  // Cache principal
  List<UserStories>? _cachedStories;
  DateTime? _lastCacheUpdate;
  static const Duration _cacheDuration = Duration(minutes: 5);

  // Cache optimista para historias temporales
  final Map<String, UserStories> _optimisticCache = {};

  // Métricas de cache
  int _cacheHits = 0;
  int _cacheMisses = 0;

  // Controllers para notificaciones de cambios
  final StreamController<List<UserStories>> _cacheChangesController =
      StreamController<List<UserStories>>.broadcast();

  // Media preload service
  final StoryMediaPreloadService _mediaPreloadService = StoryMediaPreloadService();

  // Constructor
  StoryCacheManager() {
    _mediaPreloadService.initialize();
  }

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API - CACHE OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias del cache (snapshot síncrono)
  List<UserStories> getCachedStories() {
    if (_isCacheValid()) {
      _cacheHits++;
      return _mergeOptimisticCache(_cachedStories!);
    }

    _cacheMisses++;
    return _mergeOptimisticCache([]);
  }

  /// Actualizar cache con nuevas historias
  void updateCache(List<UserStories> stories) {
    _cachedStories = List.from(stories); // Crear copia defensiva
    _lastCacheUpdate = DateTime.now();

    // Trigger media preloading for new stories
    _mediaPreloadService.preloadStoriesFromCache(stories);

    // Notificar cambios
    _notifyCacheChange();
  }

  /// Stream reactivo de cambios en el cache
  ///
  /// Emite el estado inicial inmediatamente al suscribirse para evitar
  /// que la UI permanezca en ConnectionState.waiting indefinidamente
  Stream<List<UserStories>> get cacheChangesStream {
    return Stream.multi((controller) {
      // Emitir estado inicial inmediatamente
      controller.add(getCachedStories());

      // Luego escuchar cambios futuros
      final subscription = _cacheChangesController.stream.listen(
        controller.add,
        onError: controller.addError,
      );

      // Cleanup cuando se cancela la suscripción
      controller.onCancel = () => subscription.cancel();
    });
  }

  /// Verificar si el cache es válido (no expirado)
  bool isCacheValid() => _isCacheValid();

  /// Invalidar cache (forzar recarga)
  void invalidateCache() {
    _cachedStories = null;
    _lastCacheUpdate = null;
    _notifyCacheChange();
  }

  // ═══════════════════════════════════════════════════════════════
  // OPTIMISTIC CACHE - Para UX inmediata
  // ═══════════════════════════════════════════════════════════════

  /// Agregar historia optimista (aparece inmediatamente en UI)
  void addOptimisticStory(String userId, Story story) {
    // Buscar UserStories existente o crear nuevo
    final existingUserStories = _findUserStoriesInCache(userId) ??
        _findUserStoriesInOptimistic(userId);

    if (existingUserStories != null) {
      // Agregar a historias existentes
      final updatedStories = List<Story>.from(existingUserStories.stories);
      updatedStories.insert(0, story); // Agregar al principio

      final updatedUserStories = UserStories(
        userId: existingUserStories.userId,
        userName: existingUserStories.userName,
        userPhotoURL: existingUserStories.userPhotoURL,
        stories: updatedStories,
        hasUnviewed: true, // Nueva historia = no vista
      );

      _optimisticCache[userId] = updatedUserStories;
    } else {
      // Crear nuevo UserStories
      _optimisticCache[userId] = UserStories(
        userId: userId,
        userName: story.userName,
        userPhotoURL: story.userPhotoURL,
        stories: [story],
        hasUnviewed: true,
      );
    }

    _notifyCacheChange();
  }

  /// Actualizar historia optimista (ej: cuando upload completa)
  void updateOptimisticStory(String userId, String storyId, Story updatedStory) {
    final userStories = _optimisticCache[userId];
    if (userStories == null) return;

    final storyIndex = userStories.stories.indexWhere((s) => s.id == storyId);
    if (storyIndex == -1) return;

    final updatedStories = List<Story>.from(userStories.stories);
    updatedStories[storyIndex] = updatedStory;

    _optimisticCache[userId] = UserStories(
      userId: userStories.userId,
      userName: userStories.userName,
      userPhotoURL: userStories.userPhotoURL,
      stories: updatedStories,
      hasUnviewed: userStories.hasUnviewed,
    );

    _notifyCacheChange();
  }

  /// Remover historia optimista (ej: cuando upload falla)
  void removeOptimisticStory(String userId, String storyId) {
    final userStories = _optimisticCache[userId];
    if (userStories == null) return;

    final updatedStories = userStories.stories
        .where((story) => story.id != storyId)
        .toList();

    if (updatedStories.isEmpty) {
      _optimisticCache.remove(userId);
    } else {
      _optimisticCache[userId] = UserStories(
        userId: userStories.userId,
        userName: userStories.userName,
        userPhotoURL: userStories.userPhotoURL,
        stories: updatedStories,
        hasUnviewed: userStories.hasUnviewed,
      );
    }

    _notifyCacheChange();
  }

  /// Limpiar cache optimista
  void clearOptimisticCache() {
    _optimisticCache.clear();
    _notifyCacheChange();
  }

  // ═══════════════════════════════════════════════════════════════
  // CACHE MAINTENANCE
  // ═══════════════════════════════════════════════════════════════

  /// Remover historias expiradas (>24 horas)
  void removeExpiredStories() {
    if (_cachedStories == null) return;

    final now = DateTime.now();
    final twentyFourHoursAgo = now.subtract(Duration(hours: 24));

    final updatedUserStories = <UserStories>[];

    for (final userStories in _cachedStories!) {
      final validStories = userStories.stories
          .where((story) => story.createdAt.isAfter(twentyFourHoursAgo))
          .toList();

      if (validStories.isNotEmpty) {
        updatedUserStories.add(UserStories(
          userId: userStories.userId,
          userName: userStories.userName,
          userPhotoURL: userStories.userPhotoURL,
          stories: validStories,
          hasUnviewed: userStories.hasUnviewed,
        ));
      }
    }

    _cachedStories = updatedUserStories;
    _notifyCacheChange();
  }

  /// Remover todas las historias de un usuario específico
  void removeStoriesByUserId(String userId) {
    if (_cachedStories == null) return;

    // Filtrar historias excluyendo las del usuario especificado
    final updatedUserStories = _cachedStories!
        .where((userStories) => userStories.userId != userId)
        .toList();

    // También remover del cache optimista
    _optimisticCache.remove(userId);

    _cachedStories = updatedUserStories;
    _notifyCacheChange();
  }

  /// Actualizar estado de una historia específica (más eficiente que invalidar todo)
  void updateStoryStatus(String storyId, StoryStatus newStatus) {
    if (_cachedStories == null) return;

    bool updated = false;

    // Buscar y actualizar la historia en el cache principal
    for (final userStories in _cachedStories!) {
      for (int i = 0; i < userStories.stories.length; i++) {
        if (userStories.stories[i].id == storyId) {
          userStories.stories[i] = userStories.stories[i].copyWith(status: newStatus);
          updated = true;
          break;
        }
      }
      if (updated) break;
    }

    // También actualizar en cache optimista si existe
    _optimisticCache.forEach((userId, userStories) {
      for (int i = 0; i < userStories.stories.length; i++) {
        if (userStories.stories[i].id == storyId) {
          userStories.stories[i] = userStories.stories[i].copyWith(status: newStatus);
          updated = true;
          break;
        }
      }
    });

    if (updated) {
      _notifyCacheChange();
    }
  }

  /// Remover una historia específica sin invalidar todo el cache
  void removeStoryById(String storyId) {
    if (_cachedStories == null) return;

    bool updated = false;

    // Buscar y remover del cache principal
    for (final userStories in _cachedStories!) {
      final originalLength = userStories.stories.length;
      userStories.stories.removeWhere((story) => story.id == storyId);

      if (userStories.stories.length != originalLength) {
        updated = true;
      }
    }

    // Remover UserStories vacíos
    _cachedStories!.removeWhere((userStories) => userStories.stories.isEmpty);

    // También remover del cache optimista
    _optimisticCache.forEach((userId, userStories) {
      userStories.stories.removeWhere((story) => story.id == storyId);
    });

    // Remover UserStories vacíos del cache optimista
    _optimisticCache.removeWhere((userId, userStories) => userStories.stories.isEmpty);

    if (updated) {
      _notifyCacheChange();
    }
  }

  /// Agregar UserStories específico al cache (para recargas granulares)
  void addUserStories(UserStories userStories) {
    if (_cachedStories == null) {
      _cachedStories = [userStories];
    } else {
      // Remover UserStories existente para este usuario (si existe)
      _cachedStories!.removeWhere((us) => us.userId == userStories.userId);

      // Agregar el nuevo UserStories
      _cachedStories!.add(userStories);

      // Ordenar por prioridad
      _cachedStories = sortStoriesByPriority(_cachedStories!);
    }

    _lastCacheUpdate = DateTime.now();
    _notifyCacheChange();
  }

  /// Deduplicar historias (remover duplicados por ID)
  List<UserStories> deduplicateStories(List<UserStories> stories) {
    final seenUserIds = <String>{};
    final uniqueStories = <UserStories>[];

    for (final userStories in stories) {
      if (!seenUserIds.contains(userStories.userId)) {
        seenUserIds.add(userStories.userId);

        // También deduplicar historias dentro del UserStories
        final seenStoryIds = <String>{};
        final uniqueUserStories = userStories.stories
            .where((story) => seenStoryIds.add(story.id))
            .toList();

        uniqueStories.add(UserStories(
          userId: userStories.userId,
          userName: userStories.userName,
          userPhotoURL: userStories.userPhotoURL,
          stories: uniqueUserStories,
          hasUnviewed: userStories.hasUnviewed,
        ));
      }
    }

    return uniqueStories;
  }

  /// Ordenar historias por prioridad (no vistas primero, luego por fecha)
  List<UserStories> sortStoriesByPriority(List<UserStories> stories) {
    final sortedStories = List<UserStories>.from(stories);

    sortedStories.sort((a, b) {
      // 1. Historias no vistas tienen prioridad
      if (a.hasUnviewed && !b.hasUnviewed) return -1;
      if (!a.hasUnviewed && b.hasUnviewed) return 1;

      // 2. Ordenar por historia más reciente
      final aLatest = a.latestStory?.createdAt;
      final bLatest = b.latestStory?.createdAt;

      if (aLatest == null && bLatest == null) return 0;
      if (aLatest == null) return 1;
      if (bLatest == null) return -1;

      return bLatest.compareTo(aLatest);
    });

    return sortedStories;
  }

  // ═══════════════════════════════════════════════════════════════
  // METRICS & DEBUGGING
  // ═══════════════════════════════════════════════════════════════

  /// Obtener métricas del cache
  Map<String, dynamic> getMetrics() {
    return {
      'cacheHits': _cacheHits,
      'cacheMisses': _cacheMisses,
      'cacheHitRate': _cacheHits + _cacheMisses > 0
          ? _cacheHits / (_cacheHits + _cacheMisses)
          : 0.0,
      'cachedStoriesCount': _cachedStories?.length ?? 0,
      'optimisticStoriesCount': _optimisticCache.length,
      'isCacheValid': _isCacheValid(),
      'lastUpdate': _lastCacheUpdate?.toIso8601String(),
      'cacheAge': _lastCacheUpdate != null
          ? DateTime.now().difference(_lastCacheUpdate!).inMinutes
          : null,
    };
  }

  /// Obtener cache hit rate
  double getCacheHitRate() {
    final total = _cacheHits + _cacheMisses;
    return total > 0 ? _cacheHits / total : 0.0;
  }

  /// Reset métricas
  void resetMetrics() {
    _cacheHits = 0;
    _cacheMisses = 0;
  }

  // ═══════════════════════════════════════════════════════════════
  // PRIVATE HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si cache es válido (no expirado)
  bool _isCacheValid() {
    return _cachedStories != null &&
           _lastCacheUpdate != null &&
           DateTime.now().difference(_lastCacheUpdate!) < _cacheDuration;
  }

  /// Combinar cache principal con cache optimista
  List<UserStories> _mergeOptimisticCache(List<UserStories> mainCache) {
    final merged = List<UserStories>.from(mainCache);

    // Agregar historias optimistas
    for (final optimisticUserStories in _optimisticCache.values) {
      final existingIndex = merged.indexWhere(
        (userStories) => userStories.userId == optimisticUserStories.userId
      );

      if (existingIndex != -1) {
        // Combinar con existente
        final existing = merged[existingIndex];
        final combinedStories = <Story>[];

        // Agregar historias optimistas primero
        combinedStories.addAll(optimisticUserStories.stories);

        // Agregar historias del cache (evitando duplicados)
        for (final story in existing.stories) {
          if (!combinedStories.any((s) => s.id == story.id)) {
            combinedStories.add(story);
          }
        }

        merged[existingIndex] = UserStories(
          userId: existing.userId,
          userName: existing.userName,
          userPhotoURL: existing.userPhotoURL,
          stories: combinedStories,
          hasUnviewed: optimisticUserStories.hasUnviewed || existing.hasUnviewed,
        );
      } else {
        // Agregar nuevo UserStories optimista
        merged.add(optimisticUserStories);
      }
    }

    return sortStoriesByPriority(deduplicateStories(merged));
  }

  /// Buscar UserStories en cache principal
  UserStories? _findUserStoriesInCache(String userId) {
    if (_cachedStories == null) return null;

    try {
      return _cachedStories!.firstWhere(
        (userStories) => userStories.userId == userId
      );
    } catch (e) {
      return null;
    }
  }

  /// Buscar UserStories en cache optimista
  UserStories? _findUserStoriesInOptimistic(String userId) {
    return _optimisticCache[userId];
  }

  /// Notificar cambios en el cache
  void _notifyCacheChange() {
    if (!_cacheChangesController.isClosed) {
      _cacheChangesController.add(getCachedStories());
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar recursos
  void dispose() {
    _cacheChangesController.close();
    _cachedStories = null;
    _optimisticCache.clear();
    _mediaPreloadService.dispose();
    resetMetrics();
  }
}