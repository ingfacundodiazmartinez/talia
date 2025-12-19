import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
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

  // ✅ FIX: Flag para saber si el cache ha sido poblado al menos una vez
  // Esto evita emitir estado inicial vacío antes de que Firestore responda
  bool _hasBeenPopulated = false;

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
  /// ✅ FIX #7: Preserva viewedBy locales para que el gradiente no "salte" después de ver
  void updateCache(List<UserStories> stories) {
    // Preservar viewedBy locales antes de sobrescribir
    final localViewedByMap = _extractLocalViewedBy();

    _cachedStories = List.from(stories); // Crear copia defensiva

    // ✅ FIX #7: Re-aplicar viewedBy locales para preservar cambios optimistas
    _reapplyLocalViewedBy(localViewedByMap);

    _lastCacheUpdate = DateTime.now();

    // ✅ FIX: Marcar que el cache ha sido poblado al menos una vez
    _hasBeenPopulated = true;

    // Trigger media preloading for new stories
    _mediaPreloadService.preloadStoriesFromCache(stories);

    // Notificar cambios
    _notifyCacheChange();
  }

  /// Extraer viewedBy actuales del cache local (antes de sobrescribir)
  Map<String, List<String>> _extractLocalViewedBy() {
    final result = <String, List<String>>{};
    if (_cachedStories == null) return result;

    for (final userStories in _cachedStories!) {
      for (final story in userStories.stories) {
        result[story.id] = List.from(story.viewedBy);
      }
    }
    return result;
  }

  /// Re-aplicar viewedBy locales al cache actualizado
  /// Fusiona los viewedBy de Firestore con los locales (unión de sets)
  void _reapplyLocalViewedBy(Map<String, List<String>> localViewedByMap) {
    if (_cachedStories == null || localViewedByMap.isEmpty) return;

    for (int userIndex = 0; userIndex < _cachedStories!.length; userIndex++) {
      final userStories = _cachedStories![userIndex];
      bool userStoriesUpdated = false;

      for (int storyIndex = 0; storyIndex < userStories.stories.length; storyIndex++) {
        final story = userStories.stories[storyIndex];
        final localViewedBy = localViewedByMap[story.id];

        if (localViewedBy != null) {
          // Fusionar viewedBy: unir Firestore con local
          final mergedViewedBy = {...story.viewedBy, ...localViewedBy}.toList();

          if (mergedViewedBy.length > story.viewedBy.length) {
            // Hay viewers locales que Firestore no tiene aún
            userStories.stories[storyIndex] = story.copyWith(viewedBy: mergedViewedBy);
            userStoriesUpdated = true;
          }
        }
      }

      // Recalcular hasUnviewed si hubo cambios
      if (userStoriesUpdated) {
        final currentUserId = _getCurrentUserId();
        if (currentUserId != null) {
          final hasUnviewed = userStories.stories.any(
            (s) => !s.viewedBy.contains(currentUserId),
          );

          _cachedStories![userIndex] = UserStories(
            userId: userStories.userId,
            userName: userStories.userName,
            userPhotoURL: userStories.userPhotoURL,
            stories: userStories.stories,
            hasUnviewed: hasUnviewed,
          );
        }
      }
    }
  }

  /// Obtener userId actual (helper)
  String? _getCurrentUserId() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (e) {
      return null;
    }
  }

  /// Stream reactivo de cambios en el cache
  ///
  /// ✅ FIX: Solo emite estado inicial si el cache ha sido poblado al menos una vez.
  /// Esto evita emitir lista vacía antes de que Firestore responda en el primer login,
  /// lo que causaba que las historias no se mostraran hasta reiniciar la app.
  Stream<List<UserStories>> get cacheChangesStream {
    return Stream.multi((controller) {
      // ✅ FIX: Solo emitir estado inicial si ya tenemos datos
      // Si nunca se ha poblado, esperar a que Firestore responda
      if (_hasBeenPopulated) {
        controller.add(getCachedStories());
      }

      // Luego escuchar cambios futuros
      final subscription = _cacheChangesController.stream.listen(
        controller.add,
        onError: controller.addError,
      );

      // Cleanup cuando se cancela la suscripción
      controller.onCancel = () => subscription.cancel();
    });
  }

  /// Verificar si el cache ha sido poblado al menos una vez
  bool get hasBeenPopulated => _hasBeenPopulated;

  /// Verificar si el cache es válido (no expirado)
  bool isCacheValid() => _isCacheValid();

  /// Invalidar cache (forzar recarga)
  /// Nota: NO reseteamos _hasBeenPopulated porque queremos seguir emitiendo
  /// estado vacío (no esperar indefinidamente) cuando el usuario ya vio historias antes
  void invalidateCache() {
    _cachedStories = null;
    _lastCacheUpdate = null;
    _notifyCacheChange();
  }

  /// Limpiar cache completamente al cerrar sesión
  /// Resetea todo incluyendo _hasBeenPopulated para que el próximo usuario
  /// empiece con un estado limpio
  void resetForLogout() {
    _cachedStories = null;
    _lastCacheUpdate = null;
    _optimisticCache.clear();
    _hasBeenPopulated = false;
    resetMetrics();
    // No llamamos _notifyCacheChange() porque el usuario está cerrando sesión
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

  /// ✅ FIX #7: Marcar historia como vista localmente para actualización inmediata del gradient
  /// Actualiza viewedBy y recalcula hasUnviewed para UI instantánea
  void markStoryAsViewedLocally(String storyId, String userId) {
    if (_cachedStories == null) return;

    bool updated = false;

    // Buscar y actualizar la historia en el cache principal
    for (int userIndex = 0; userIndex < _cachedStories!.length; userIndex++) {
      final userStories = _cachedStories![userIndex];
      for (int storyIndex = 0; storyIndex < userStories.stories.length; storyIndex++) {
        if (userStories.stories[storyIndex].id == storyId) {
          final story = userStories.stories[storyIndex];

          // Si ya está marcado como visto, no hacer nada
          if (story.viewedBy.contains(userId)) return;

          // Agregar userId a viewedBy
          final newViewedBy = [...story.viewedBy, userId];
          userStories.stories[storyIndex] = story.copyWith(viewedBy: newViewedBy);

          // Recalcular hasUnviewed para este UserStories
          final hasUnviewed = userStories.stories.any(
            (s) => !s.viewedBy.contains(userId),
          );

          // Actualizar UserStories con nuevo hasUnviewed
          _cachedStories![userIndex] = UserStories(
            userId: userStories.userId,
            userName: userStories.userName,
            userPhotoURL: userStories.userPhotoURL,
            stories: userStories.stories,
            hasUnviewed: hasUnviewed,
          );

          updated = true;
          break;
        }
      }
      if (updated) break;
    }

    // También actualizar en cache optimista si existe
    _optimisticCache.forEach((ownerUserId, userStories) {
      for (int i = 0; i < userStories.stories.length; i++) {
        if (userStories.stories[i].id == storyId) {
          final story = userStories.stories[i];
          if (!story.viewedBy.contains(userId)) {
            final newViewedBy = [...story.viewedBy, userId];
            userStories.stories[i] = story.copyWith(viewedBy: newViewedBy);

            // Recalcular hasUnviewed
            final hasUnviewed = userStories.stories.any(
              (s) => !s.viewedBy.contains(userId),
            );

            _optimisticCache[ownerUserId] = UserStories(
              userId: userStories.userId,
              userName: userStories.userName,
              userPhotoURL: userStories.userPhotoURL,
              stories: userStories.stories,
              hasUnviewed: hasUnviewed,
            );
            updated = true;
          }
          break;
        }
      }
    });

    if (updated) {
      _notifyCacheChange();
    }
  }

  /// Actualizar like de una historia localmente para UI instantánea
  /// Si [isLike] es true, agrega el userId a likedBy; si es false, lo remueve
  void updateStoryLikeLocally(String storyId, String userId, bool isLike) {
    if (_cachedStories == null) return;

    bool updated = false;

    // Buscar y actualizar la historia en el cache principal
    for (int userIndex = 0; userIndex < _cachedStories!.length; userIndex++) {
      final userStories = _cachedStories![userIndex];
      for (int storyIndex = 0; storyIndex < userStories.stories.length; storyIndex++) {
        if (userStories.stories[storyIndex].id == storyId) {
          final story = userStories.stories[storyIndex];

          // Verificar si ya está en el estado deseado
          final alreadyLiked = story.likedBy.contains(userId);
          if (isLike && alreadyLiked) return;
          if (!isLike && !alreadyLiked) return;

          // Actualizar likedBy
          List<String> newLikedBy;
          if (isLike) {
            newLikedBy = [...story.likedBy, userId];
          } else {
            newLikedBy = story.likedBy.where((id) => id != userId).toList();
          }

          userStories.stories[storyIndex] = story.copyWith(likedBy: newLikedBy);
          updated = true;
          break;
        }
      }
      if (updated) break;
    }

    // También actualizar en cache optimista si existe
    _optimisticCache.forEach((ownerUserId, userStories) {
      for (int i = 0; i < userStories.stories.length; i++) {
        if (userStories.stories[i].id == storyId) {
          final story = userStories.stories[i];
          final alreadyLiked = story.likedBy.contains(userId);

          if ((isLike && !alreadyLiked) || (!isLike && alreadyLiked)) {
            List<String> newLikedBy;
            if (isLike) {
              newLikedBy = [...story.likedBy, userId];
            } else {
              newLikedBy = story.likedBy.where((id) => id != userId).toList();
            }
            userStories.stories[i] = story.copyWith(likedBy: newLikedBy);

            _optimisticCache[ownerUserId] = UserStories(
              userId: userStories.userId,
              userName: userStories.userName,
              userPhotoURL: userStories.userPhotoURL,
              stories: userStories.stories,
              hasUnviewed: userStories.hasUnviewed,
            );
            updated = true;
          }
          break;
        }
      }
    });

    if (updated) {
      _notifyCacheChange();
    }
  }

  /// Actualizar respuestas de una historia localmente para UI instantánea
  void addStoryReplyLocally(String storyId, StoryReply reply) {
    if (_cachedStories == null) return;

    bool updated = false;

    // Buscar y actualizar la historia en el cache principal
    for (int userIndex = 0; userIndex < _cachedStories!.length; userIndex++) {
      final userStories = _cachedStories![userIndex];
      for (int storyIndex = 0; storyIndex < userStories.stories.length; storyIndex++) {
        if (userStories.stories[storyIndex].id == storyId) {
          final story = userStories.stories[storyIndex];

          // Agregar reply a la lista
          final newReplies = [...story.replies, reply];
          userStories.stories[storyIndex] = story.copyWith(replies: newReplies);
          updated = true;
          break;
        }
      }
      if (updated) break;
    }

    // También actualizar en cache optimista si existe
    _optimisticCache.forEach((ownerUserId, userStories) {
      for (int i = 0; i < userStories.stories.length; i++) {
        if (userStories.stories[i].id == storyId) {
          final story = userStories.stories[i];
          final newReplies = [...story.replies, reply];
          userStories.stories[i] = story.copyWith(replies: newReplies);

          _optimisticCache[ownerUserId] = UserStories(
            userId: userStories.userId,
            userName: userStories.userName,
            userPhotoURL: userStories.userPhotoURL,
            stories: userStories.stories,
            hasUnviewed: userStories.hasUnviewed,
          );
          updated = true;
          break;
        }
      }
    });

    if (updated) {
      _notifyCacheChange();
    }
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
    _hasBeenPopulated = false; // ✅ FIX: Resetear flag al disponer
    _mediaPreloadService.dispose();
    resetMetrics();
  }
}