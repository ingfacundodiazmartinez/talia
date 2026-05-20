import 'dart:async';
import '../repositories/story_repository.dart';
import '../repositories/contact_repository.dart';
import 'story_cache_manager.dart';
import '../../../models/story.dart';
import '../../block_status_cache_service.dart';
import '../../../utils/release_logger.dart';

/// Manager para coordinación de streams de historias
///
/// Responsabilidades:
/// - Coordinar streams de Firestore con cache
/// - Gestionar background updates
/// - Optimizar queries y reducir rebuilds
/// - NO mezcla responsabilidades de cache y streams
class StoryStreamManager {
  final StoryRepository _storyRepository;
  final ContactRepository _contactRepository;
  final StoryCacheManager _cacheManager;
  final dynamic _blockStatusService;

  // Background stream management
  bool _isBackgroundStreamActive = false;
  StreamSubscription? _backgroundStreamSubscription;
  StreamSubscription? _blockStatusSubscription;

  // Stream controllers
  final StreamController<List<UserStories>> _mainStreamController =
      StreamController<List<UserStories>>.broadcast();

  // Performance tracking
  int _activeStreamCount = 0;
  DateTime? _lastRefresh;

  // PERFORMANCE OPTIMIZATION: Cache de relaciones padre-hijo
  final Map<String, Set<String>> _parentChildCache = {}; // childId -> {parentIds}
  DateTime? _parentChildCacheExpiry;
  static const Duration _cacheExpiration = Duration(minutes: 10);

  StoryStreamManager({
    required StoryRepository storyRepository,
    required ContactRepository contactRepository,
    required StoryCacheManager cacheManager,
    dynamic blockStatusService,
  }) : _storyRepository = storyRepository,
       _contactRepository = contactRepository,
       _cacheManager = cacheManager,
       _blockStatusService = blockStatusService ?? BlockStatusCacheService() {
    // Configurar suscripción a cambios de estado de bloqueo
    _setupBlockStatusListener();
  }

  /// Configurar listener para cambios de estado de bloqueo
  void _setupBlockStatusListener() {
    // Solo configurar si el servicio de bloqueo tiene el stream
    try {
      final blockStatusChanges = _blockStatusService?.blockStatusChanges;
      if (blockStatusChanges != null) {
        _blockStatusSubscription = blockStatusChanges.listen(
          (blockStatusChange) {
            if (blockStatusChange.isBlocked) {
              // Usuario bloqueado: remover solo sus historias (granular)
              _removeStoriesFromBlockedUser(blockStatusChange.contactId);
              _invalidateParentChildCacheForUser(blockStatusChange.contactId);
            } else {
              // Usuario desbloqueado: recargar solo sus historias (granular)
              _reloadStoriesForUser(blockStatusChange.contactId);
              _invalidateParentChildCacheForUser(blockStatusChange.contactId);
            }
          },
          onError: (error) {
            ReleaseLogger.error(
              'Error en listener de bloqueo: $error',
              tag: 'StoryStreamManager',
            );
          },
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        'No se pudo configurar listener de bloqueo: $e',
        tag: 'StoryStreamManager',
      );
    }
  }

  /// Remover historias de un usuario específico del cache
  void _removeStoriesFromBlockedUser(String userId) {
    // Remover del cache manager las historias de este usuario
    _cacheManager.removeStoriesByUserId(userId);
  }

  /// Recargar historias de un usuario específico desde Firestore
  Future<void> _reloadStoriesForUser(String userId) async {
    try {
      // Cargar historias del usuario desde Firestore
      final userStories = await _storyRepository.getByUserId(userId);

      if (userStories.isNotEmpty) {
        // Crear UserStories para este usuario
        final story = userStories.first;
        // ✅ FIX: calcular hasUnviewed real basado en viewedBy del current user.
        // Hardcodear true rompe el gradient después de que el viewer ya marcó las
        // historias como vistas (caso típico: padre responde historia del menor).
        final viewerId = _storyRepository.currentUserId;
        final hasUnviewed = _hasUnviewedStories(userStories, viewerId);
        final newUserStories = UserStories(
          userId: userId,
          userName: story.userName,
          userPhotoURL: story.userPhotoURL,
          stories: userStories,
          hasUnviewed: hasUnviewed,
        );

        // Agregar al cache usando el método específico del cache manager
        _cacheManager.addUserStories(newUserStories);
      }
    } catch (e) {
      ReleaseLogger.error(
        'Error recargando historias para usuario $userId: $e',
        tag: 'StoryStreamManager',
      );
    }
  }

  /// Invalidar cache de relaciones padre-hijo solo para un usuario específico
  void _invalidateParentChildCacheForUser(String userId) {
    // Remover entradas del cache que involucren a este usuario
    final keysToRemove = _parentChildCache.keys
        .where((key) => key == userId)
        .toList();

    for (final key in keysToRemove) {
      _parentChildCache.remove(key);
    }

    // También invalidar cualquier entrada donde este usuario sea padre
    final parentKeysToRemove = <String>[];
    _parentChildCache.forEach((childId, parentIds) {
      if (parentIds.contains(userId)) {
        parentKeysToRemove.add(childId);
      }
    });

    for (final key in parentKeysToRemove) {
      _parentChildCache.remove(key);
    }
  }

  /// Forzar refresh del stream principal

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API - MAIN STREAMS
  // ═══════════════════════════════════════════════════════════════

  /// Stream principal de historias desde whitelist
  ///
  /// ✅ OPTIMIZADO: Usa availableFor para query simple sin límite de contactos
  /// - NO escucha cache optimista aquí (eso es responsabilidad del cache)
  /// - NO hace yield inmediato de cache (evita flicker)
  /// - Stream limpio que solo reacciona a cambios reales de Firestore
  /// - Sin chunking ni límite de 10 contactos
  Stream<List<UserStories>> getStoriesFromWhitelist() async* {
    _activeStreamCount++;
    ReleaseLogger.log(
      '📡 [StoryStreamManager] getStoriesFromWhitelist called, active streams: $_activeStreamCount',
      tag: 'StoryStreamManager',
    );

    try {
      final currentUserId = _storyRepository.currentUserId;
      if (currentUserId == null) {
        ReleaseLogger.log(
          '⚠️ [StoryStreamManager] No current user ID in getStoriesFromWhitelist, yielding empty',
          tag: 'StoryStreamManager',
        );
        yield [];
        return;
      }

      ReleaseLogger.log(
        '✅ [StoryStreamManager] Current user ID: $currentUserId',
        tag: 'StoryStreamManager',
      );

      // ✅ Query optimizada: usa availableFor en lugar de whereIn con chunks
      yield* _createOptimizedFirestoreStream(currentUserId);
    } catch (e) {
      ReleaseLogger.error(
        '❌ [StoryStreamManager] Error en getStoriesFromWhitelist: $e',
        tag: 'StoryStreamManager',
      );
      throw Exception('Error en stream de historias: $e');
    } finally {
      _activeStreamCount--;
      ReleaseLogger.log(
        '📡 [StoryStreamManager] getStoriesFromWhitelist finished, active streams: $_activeStreamCount',
        tag: 'StoryStreamManager',
      );
    }
  }

  /// Stream reactivo desde cache (para UI que necesita updates inmediatos)
  Stream<List<UserStories>> get storiesFromCache {
    return _cacheManager.cacheChangesStream;
  }

  // ═══════════════════════════════════════════════════════════════
  // BACKGROUND STREAMS - Para mantener cache actualizado
  // ═══════════════════════════════════════════════════════════════

  /// Iniciar background streams para actualizar cache automáticamente
  Future<void> startBackgroundStreams() async {
    if (_isBackgroundStreamActive) {
      ReleaseLogger.log(
        '⚠️ [StoryStreamManager] Background stream already active, skipping',
        tag: 'StoryStreamManager',
      );
      return;
    }

    ReleaseLogger.log(
      '🚀 [StoryStreamManager] Starting background streams...',
      tag: 'StoryStreamManager',
    );

    try {
      // Stream que mantiene cache actualizado
      final backgroundStream = getStoriesFromWhitelist();

      _backgroundStreamSubscription = backgroundStream.listen(
        (stories) {
          // ✅ FIX: Siempre actualizar cache en la primera emisión para marcar _hasBeenPopulated
          // Esto evita el spinner infinito cuando no hay historias
          final shouldUpdate = !_cacheManager.hasBeenPopulated || _hasStoriesChanged(stories);
          if (shouldUpdate) {
            _cacheManager.updateCache(stories);
            _lastRefresh = DateTime.now();
          }
        },
        onError: (error, stackTrace) {
          // Log para identificar la fuente del error
          ReleaseLogger.error(
            '❌ [StoryStreamManager] Background stream error: $error',
          );
          // Auto-retry en errores
          Future.delayed(Duration(seconds: 30), () {
            if (!_isBackgroundStreamActive) return;
            startBackgroundStreams();
          });
        },
        cancelOnError: false, // No cancelar el stream en errores
      );

      _isBackgroundStreamActive = true;
    } catch (e) {
      throw Exception('Error iniciando background streams: $e');
    }
  }

  /// Detener background streams
  void stopBackgroundStreams() {
    _backgroundStreamSubscription?.cancel();
    _backgroundStreamSubscription = null;

    // ✅ CRÍTICO: También cancelar la suscripción de block status para evitar spinner infinito
    _blockStatusSubscription?.cancel();
    _blockStatusSubscription = null;

    _isBackgroundStreamActive = false;
  }

  /// Forzar refresh inmediato
  /// ✅ FIX: Siempre reinicia el stream, no solo si estaba activo
  Future<void> forceRefresh() async {
    ReleaseLogger.log(
      '🔄 [StoryStreamManager] forceRefresh called, wasActive: $_isBackgroundStreamActive',
      tag: 'StoryStreamManager',
    );

    _contactRepository.invalidateContactsCache();
    _cacheManager.invalidateCache();
    invalidateParentChildCache();

    // Siempre detener y reiniciar el stream
    stopBackgroundStreams();
    await startBackgroundStreams();

    ReleaseLogger.log(
      '✅ [StoryStreamManager] forceRefresh completed, isActive: $_isBackgroundStreamActive',
      tag: 'StoryStreamManager',
    );
  }

  /// Soft refresh: reinicia streams SIN invalidar cache de historias
  /// ✅ FIX: Usado cuando la app vuelve de background para evitar parpadeo
  /// Los nuevos datos reemplazarán los viejos cuando lleguen del stream
  Future<void> softRefresh() async {
    ReleaseLogger.log(
      '🔄 [StoryStreamManager] softRefresh called, wasActive: $_isBackgroundStreamActive',
      tag: 'StoryStreamManager',
    );

    // Solo invalidar cache de contactos (no de historias)
    _contactRepository.invalidateContactsCache();
    invalidateParentChildCache();

    // Reiniciar streams sin invalidar cache de historias
    // Esto mantiene las historias visibles mientras se cargan las nuevas
    stopBackgroundStreams();
    await startBackgroundStreams();

    ReleaseLogger.log(
      '✅ [StoryStreamManager] softRefresh completed, isActive: $_isBackgroundStreamActive',
      tag: 'StoryStreamManager',
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // OPTIMIZED FIRESTORE STREAM - Usa availableFor
  // ═══════════════════════════════════════════════════════════════

  /// ✅ Stream optimizado usando availableFor
  ///
  /// VENTAJAS sobre implementación anterior:
  /// - Sin límite de 10 contactos (soporta cualquier cantidad)
  /// - Una sola query en lugar de múltiples chunks
  /// - Mejor performance y menos lecturas de Firestore
  Stream<List<UserStories>> _createOptimizedFirestoreStream(
    String currentUserId,
  ) async* {
    ReleaseLogger.log(
      '🔍 [StoryStreamManager] Creating optimized stream for userId: $currentUserId',
      tag: 'StoryStreamManager',
    );

    // Query simple: historias donde currentUserId está en availableFor
    await for (final stories in _storyRepository.getStoriesAvailableForUser(currentUserId)) {
      ReleaseLogger.log(
        '📥 [StoryStreamManager] Received ${stories.length} stories from repository',
        tag: 'StoryStreamManager',
      );

      // Procesar y agrupar historias
      final userStoriesList = await _processAndGroupStories(
        stories,
        [], // Ya no necesitamos contactIds para filtrar
      );

      ReleaseLogger.log(
        '📤 [StoryStreamManager] Processed into ${userStoriesList.length} UserStories groups',
        tag: 'StoryStreamManager',
      );

      yield userStoriesList;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // STORY PROCESSING & GROUPING
  // ═══════════════════════════════════════════════════════════════

  /// Procesar y agrupar historias por usuario
  Future<List<UserStories>> _processAndGroupStories(
    List<Story> allStories,
    List<String> contactIds,
  ) async {
    // Filtrar historias según reglas de visibilidad
    final filteredStories = await _filterStoriesByVisibilityRules(allStories);

    // Agrupar historias por userId
    final storiesByUser = <String, List<Story>>{};

    for (final story in filteredStories) {
      storiesByUser.putIfAbsent(story.userId, () => []).add(story);
    }

    // Obtener información de usuarios
    final usersInfo = await _contactRepository.getUsersInfo(
      storiesByUser.keys.toList()
    );

    // Crear UserStories
    final userStoriesList = <UserStories>[];

    for (final entry in storiesByUser.entries) {
      final userId = entry.key;
      final stories = entry.value;
      final userInfo = usersInfo[userId];

      if (userInfo != null) {
        // Ordenar historias por fecha
        stories.sort((a, b) => b.createdAt.compareTo(a.createdAt));

        // Calcular si tiene historias no vistas
        final hasUnviewed = _hasUnviewedStories(
          stories,
          _storyRepository.currentUserId,
        );

        userStoriesList.add(UserStories(
          userId: userId,
          userName: userInfo['name'] ?? 'Usuario',
          userPhotoURL: userInfo['photoURL'],
          stories: stories,
          hasUnviewed: hasUnviewed,
        ));
      }
    }

    // Aplicar deduplicación y ordenamiento final
    final result = _cacheManager.sortStoriesByPriority(
      _cacheManager.deduplicateStories(userStoriesList)
    );

    return result;
  }

  /// Verificar si hay historias no vistas
  bool _hasUnviewedStories(List<Story> stories, String? currentUserId) {
    if (currentUserId == null) return false;

    return stories.any((story) =>
      !story.viewedBy.contains(currentUserId)
    );
  }

  /// Filtrar historias según reglas de visibilidad (OPTIMIZADO)
  ///
  /// OPTIMIZACIÓN: Una sola llamada para obtener TODAS las relaciones padre-hijo
  /// en lugar de una llamada por historia
  ///
  /// REGLAS:
  /// - Historias APPROVED: Todos pueden ver
  /// - Historias PENDING: Solo padres vinculados pueden ver
  /// - Historias REJECTED: Solo el padre vinculado y el propio hijo pueden ver
  /// - Historias UPLOADING: Solo el creador puede ver
  Future<List<Story>> filterStoriesByVisibilityRules(List<Story> stories) async {
    return _filterStoriesByVisibilityRules(stories);
  }

  /// Filtrar historias según reglas de visibilidad (OPTIMIZADO - implementación interna)
  Future<List<Story>> _filterStoriesByVisibilityRules(List<Story> stories) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      ReleaseLogger.log(
        '⚠️ [StoryStreamManager] No current user ID, returning empty list',
        tag: 'StoryStreamManager',
      );
      return [];
    }

    ReleaseLogger.log(
      '🔍 [StoryStreamManager] Filtering ${stories.length} stories by visibility rules for user: $currentUserId',
      tag: 'StoryStreamManager',
    );

    // OPTIMIZACIÓN: Obtener TODAS las relaciones padre-hijo de una vez
    final parentChildRelations = await _getBatchParentChildRelations(stories);

    // OPTIMIZACIÓN: Obtener estados de bloqueo de todos los usuarios de una vez
    final blockStatuses = await _getBatchBlockStatuses(stories, currentUserId);

    final filteredStories = <Story>[];
    int blockedCount = 0;
    int parentOnlyCount = 0;
    int otherCount = 0;

    for (final story in stories) {
      final canSeeStory = _canUserSeeStoryOptimized(
        story,
        currentUserId,
        parentChildRelations,
        blockStatuses
      );
      if (canSeeStory) {
        filteredStories.add(story);
      } else {
        // Log why story was filtered out
        final isBlocked = blockStatuses[story.userId] ?? false;
        if (isBlocked) {
          blockedCount++;
        } else if (story.status == StoryStatus.pending || story.status == StoryStatus.rejected) {
          parentOnlyCount++;
        } else {
          otherCount++;
        }
      }
    }

    ReleaseLogger.log(
      '📊 [StoryStreamManager] Visibility filter result: ${filteredStories.length} passed, $blockedCount blocked, $parentOnlyCount parent-only, $otherCount other',
      tag: 'StoryStreamManager',
    );

    return filteredStories;
  }

  /// Obtener relaciones padre-hijo para todos los usuarios de las historias (BATCH)
  Future<Map<String, Set<String>>> _getBatchParentChildRelations(List<Story> stories) async {
    // Verificar cache primero
    if (_isParentChildCacheValid()) {
      return _parentChildCache;
    }

    // Obtener todos los userIds únicos de las historias
    final userIds = stories.map((story) => story.userId).toSet().toList();

    try {
      // OPTIMIZACIÓN: Usar el método batch que ejecuta queries en paralelo
      final relations = await _contactRepository.getBatchLinkedParents(userIds);

      // Actualizar cache
      _parentChildCache.clear();
      _parentChildCache.addAll(relations);
      _parentChildCacheExpiry = DateTime.now().add(_cacheExpiration);

      return relations;
    } catch (e) {
      // En caso de error, retornar cache vacío (comportamiento conservativo)
      return {};
    }
  }

  /// Obtener estados de bloqueo para todos los usuarios de las historias (BATCH)
  Future<Map<String, bool>> _getBatchBlockStatuses(List<Story> stories, String currentUserId) async {
    final userIds = stories.map((story) => story.userId).toSet().toList();
    final blockStatuses = <String, bool>{};

    try {
      // Verificar bloqueos en paralelo para mejor performance
      final futures = userIds.map((userId) async {
        if (userId == currentUserId) {
          return MapEntry(userId, false); // Usuario no puede estar bloqueado consigo mismo
        }

        // Verificar bloqueo bidireccional: si A bloquea a B O si B bloquea a A
        // Usar métodos públicos del servicio de bloqueo
        final isBlockedByOther = await _blockStatusService.isBlockedBy(userId);
        final isBlockingOther = await _blockStatusService.isBlocked(userId);

        return MapEntry(userId, isBlockedByOther || isBlockingOther);
      });

      final results = await Future.wait(futures);

      for (final result in results) {
        blockStatuses[result.key] = result.value;
      }
    } catch (e) {
      // En caso de error, asumir que no hay bloqueos (comportamiento conservativo)
      for (final userId in userIds) {
        blockStatuses[userId] = false;
      }
    }

    return blockStatuses;
  }

  /// Determinar si un usuario puede ver una historia (OPTIMIZADO - sin async)
  bool _canUserSeeStoryOptimized(
    Story story,
    String currentUserId,
    Map<String, Set<String>> parentChildRelations,
    Map<String, bool> blockStatuses
  ) {
    // El creador siempre puede ver sus propias historias
    if (story.userId == currentUserId) {
      return true;
    }

    // VERIFICACIÓN DE BLOQUEO: Si hay bloqueo entre usuarios, no pueden ver historias
    // Esta verificación debe ser lo primero después de verificar si es el creador
    final isBlocked = blockStatuses[story.userId] ?? false;

    if (isBlocked) {
      return false; // Si hay cualquier tipo de bloqueo, no se pueden ver las historias
    }

    switch (story.status) {
      case StoryStatus.approved:
        // Historias aprobadas: todos los contactos pueden ver (si no están bloqueados)
        return true;

      case StoryStatus.pending:
      case StoryStatus.rejected:
        // Historias pendientes/rechazadas: solo padres vinculados pueden ver (si no están bloqueados)
        final linkedParents = parentChildRelations[story.userId] ?? <String>{};
        return linkedParents.contains(currentUserId);

      case StoryStatus.uploading:
        // Historias subiendo: solo el creador puede ver
        return false;

      default:
        // Por defecto, no mostrar
        return false;
    }
  }

  /// Verificar si el cache de relaciones padre-hijo es válido
  bool _isParentChildCacheValid() {
    return _parentChildCacheExpiry != null &&
           DateTime.now().isBefore(_parentChildCacheExpiry!);
  }

  /// Invalidar cache de relaciones padre-hijo
  void invalidateParentChildCache() {
    _parentChildCache.clear();
    _parentChildCacheExpiry = null;
  }

  /// Actualizar cache con datos específicos (para testing o updates manuales)
  void updateParentChildCache(Map<String, Set<String>> relations) {
    _parentChildCache.clear();
    _parentChildCache.addAll(relations);
    _parentChildCacheExpiry = DateTime.now().add(_cacheExpiration);
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAM UTILITIES
  // ═══════════════════════════════════════════════════════════════

  /// Combinar múltiples chunk streams en uno solo

  /// Verificar si las historias realmente cambiaron
  bool _hasStoriesChanged(List<UserStories> newStories) {
    final currentStories = _cacheManager.getCachedStories();

    // Comparación básica por longitud
    if (currentStories.length != newStories.length) return true;

    // Comparación más detallada
    for (int i = 0; i < currentStories.length; i++) {
      final current = currentStories[i];
      final newUserStories = newStories[i];

      if (current.userId != newUserStories.userId ||
          current.stories.length != newUserStories.stories.length ||
          current.hasUnviewed != newUserStories.hasUnviewed) {
        return true;
      }

      // Verificar cambios en historias individuales
      for (int j = 0; j < current.stories.length; j++) {
        final currentStory = current.stories[j];
        final newStory = newUserStories.stories[j];

        if (currentStory.id != newStory.id ||
            currentStory.status != newStory.status ||
            currentStory.viewedBy.length != newStory.viewedBy.length) {
          return true;
        }
      }
    }

    return false;
  }

  // ═══════════════════════════════════════════════════════════════
  // METRICS & DEBUGGING
  // ═══════════════════════════════════════════════════════════════

  /// Obtener número de streams activos
  int getActiveStreamCount() => _activeStreamCount;

  /// Verificar si background streams están activos
  bool get isBackgroundStreamActive => _isBackgroundStreamActive;

  /// Obtener tiempo de último refresh
  DateTime? get lastRefresh => _lastRefresh;

  /// Obtener métricas del stream manager
  Map<String, dynamic> getMetrics() {
    return {
      'activeStreams': _activeStreamCount,
      'backgroundStreamActive': _isBackgroundStreamActive,
      'lastRefresh': _lastRefresh?.toIso8601String(),
      'timeSinceLastRefresh': _lastRefresh != null
          ? DateTime.now().difference(_lastRefresh!).inMinutes
          : null,
      // PERFORMANCE CACHE METRICS
      'parentChildCacheSize': _parentChildCache.length,
      'parentChildCacheValid': _isParentChildCacheValid(),
      'parentChildCacheExpiry': _parentChildCacheExpiry?.toIso8601String(),
      'cacheAgeMinutes': _parentChildCacheExpiry != null
          ? DateTime.now().difference(_parentChildCacheExpiry!.subtract(_cacheExpiration)).inMinutes
          : null,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar recursos
  void dispose() {
    stopBackgroundStreams();
    _mainStreamController.close();
    _blockStatusSubscription?.cancel();
    _activeStreamCount = 0;

    // Limpiar cache de performance
    invalidateParentChildCache();
  }
}