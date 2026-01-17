import 'dart:async';

import '../managers/story_stream_manager.dart';
import '../managers/story_cache_manager.dart';
import '../repositories/contact_repository.dart';
import '../../../models/story.dart';

/// Servicio especializado para recuperación y visualización de historias
///
/// Responsabilidades:
/// - Coordinar streams de historias
/// - Gestionar cache para performance
/// - Filtrar historias según whitelist
/// - Proporcionar diferentes vistas de datos
class StoryRetrievalService {
  final StoryStreamManager _streamManager;
  final StoryCacheManager _cacheManager;
  final ContactRepository _contactRepository;

  StoryRetrievalService({
    required StoryStreamManager streamManager,
    required StoryCacheManager cacheManager,
    required ContactRepository contactRepository,
  }) : _streamManager = streamManager,
       _cacheManager = cacheManager,
       _contactRepository = contactRepository;

  // ═══════════════════════════════════════════════════════════════
  // MAIN STREAMS - PUBLIC API
  // ═══════════════════════════════════════════════════════════════

  /// Stream principal de historias desde whitelist
  ///
  /// MEJORAS vs implementación anterior:
  /// - Stream limpio sin cache optimista mezclado
  /// - Cache se emite por separado para UX inmediata
  /// - Deduplicación y filtrado inteligente
  Stream<List<UserStories>> getStoriesFromWhitelist() async* {
    try {
      // Verificar usuario autenticado
      final currentUserId = _contactRepository.currentUserId;
      if (currentUserId == null) {
        yield [];
        return;
      }

      // Stream de datos frescos de Firestore
      yield* _streamManager.getStoriesFromWhitelist();
    } catch (e) {
      throw Exception('Error obteniendo historias: $e');
    }
  }

  /// Stream reactivo desde cache (para UI que necesita updates inmediatos)
  ///
  /// Incluye historias optimistas para UX fluida
  Stream<List<UserStories>> get storiesFromCache {
    return _cacheManager.cacheChangesStream;
  }

  /// Obtener snapshot síncrono del cache
  List<UserStories> getCachedStories() {
    return _cacheManager.getCachedStories();
  }

  // ═══════════════════════════════════════════════════════════════
  // SPECIALIZED VIEWS
  // ═══════════════════════════════════════════════════════════════

  /// Stream de historias de un usuario específico
  Stream<UserStories?> getStoriesFromUser(String userId) async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      try {
        final userStories = allStories.firstWhere(
          (stories) => stories.userId == userId
        );
        yield userStories;
      } catch (e) {
        yield null;
      }
    }
  }

  /// Stream de historias no vistas
  Stream<List<UserStories>> getUnviewedStories() async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      final unviewedStories = allStories
          .where((userStories) => userStories.hasUnviewed)
          .toList();

      yield unviewedStories;
    }
  }

  /// Stream de historias recientes (últimas 6 horas)
  Stream<List<UserStories>> getRecentStories() async* {
    final sixHoursAgo = DateTime.now().subtract(Duration(hours: 6));

    await for (final allStories in getStoriesFromWhitelist()) {
      final recentStories = <UserStories>[];

      for (final userStories in allStories) {
        final recentUserStories = userStories.stories
            .where((story) => story.createdAt.isAfter(sixHoursAgo))
            .toList();

        if (recentUserStories.isNotEmpty) {
          recentStories.add(UserStories(
            userId: userStories.userId,
            userName: userStories.userName,
            userPhotoURL: userStories.userPhotoURL,
            stories: recentUserStories,
            hasUnviewed: userStories.hasUnviewed,
          ));
        }
      }

      yield recentStories;
    }
  }

  /// Obtener historias de contactos específicos
  Stream<List<UserStories>> getStoriesFromContacts(List<String> contactIds) async* {
    if (contactIds.isEmpty) {
      yield [];
      return;
    }

    await for (final allStories in getStoriesFromWhitelist()) {
      final filteredStories = allStories
          .where((userStories) => contactIds.contains(userStories.userId))
          .toList();

      yield filteredStories;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SEARCH & FILTERING
  // ═══════════════════════════════════════════════════════════════

  /// Buscar historias por texto
  Stream<List<UserStories>> searchStoriesByText(String searchTerm) async* {
    if (searchTerm.isEmpty) {
      yield [];
      return;
    }

    final lowerSearchTerm = searchTerm.toLowerCase();

    await for (final allStories in getStoriesFromWhitelist()) {
      final matchingStories = <UserStories>[];

      for (final userStories in allStories) {
        // Buscar en nombre de usuario
        if (userStories.userName.toLowerCase().contains(lowerSearchTerm)) {
          matchingStories.add(userStories);
          continue;
        }

        // Buscar en texto de historias
        final matchingUserStories = userStories.stories
            .where((story) =>
              story.caption?.toLowerCase().contains(lowerSearchTerm) == true)
            .toList();

        if (matchingUserStories.isNotEmpty) {
          matchingStories.add(UserStories(
            userId: userStories.userId,
            userName: userStories.userName,
            userPhotoURL: userStories.userPhotoURL,
            stories: matchingUserStories,
            hasUnviewed: userStories.hasUnviewed,
          ));
        }
      }

      yield matchingStories;
    }
  }

  /// Filtrar historias por tipo de media
  Stream<List<UserStories>> filterStoriesByMediaType(String mediaType) async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      final filteredStories = <UserStories>[];

      for (final userStories in allStories) {
        final filteredUserStories = userStories.stories
            .where((story) => story.mediaType == mediaType)
            .toList();

        if (filteredUserStories.isNotEmpty) {
          filteredStories.add(UserStories(
            userId: userStories.userId,
            userName: userStories.userName,
            userPhotoURL: userStories.userPhotoURL,
            stories: filteredUserStories,
            hasUnviewed: userStories.hasUnviewed,
          ));
        }
      }

      yield filteredStories;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CACHE OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Invalidar cache y forzar recarga
  Future<void> refreshStories() async {
    await _streamManager.forceRefresh();
  }

  /// Verificar si cache es válido
  bool isCacheValid() {
    return _cacheManager.isCacheValid();
  }

  /// Obtener métricas de cache
  Map<String, dynamic> getCacheMetrics() {
    return _cacheManager.getMetrics();
  }

  // ═══════════════════════════════════════════════════════════════
  // BACKGROUND MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Iniciar procesos background para mantener cache actualizado
  Future<void> startBackgroundProcesses() async {
    await _streamManager.startBackgroundStreams();
  }

  /// Detener procesos background
  void stopBackgroundProcesses() {
    _streamManager.stopBackgroundStreams();
  }

  /// Verificar si procesos background están activos
  bool get isBackgroundActive => _streamManager.isBackgroundStreamActive;

  // ═══════════════════════════════════════════════════════════════
  // DATA UTILITIES
  // ═══════════════════════════════════════════════════════════════

  /// Obtener conteo total de historias
  Stream<int> getTotalStoriesCount() async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      final totalCount = allStories
          .map((userStories) => userStories.stories.length)
          .fold<int>(0, (sum, count) => sum + count);

      yield totalCount;
    }
  }

  /// Obtener conteo de historias no vistas
  Stream<int> getUnviewedStoriesCount() async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      final unviewedCount = allStories
          .where((userStories) => userStories.hasUnviewed)
          .length;

      yield unviewedCount;
    }
  }

  /// Obtener estadísticas de historias
  Stream<Map<String, int>> getStoriesStats() async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      int totalStories = 0;
      int imageStories = 0;
      int videoStories = 0;
      int textStories = 0;
      int unviewedUsers = 0;

      for (final userStories in allStories) {
        totalStories += userStories.stories.length;

        if (userStories.hasUnviewed) {
          unviewedUsers++;
        }

        for (final story in userStories.stories) {
          switch (story.mediaType) {
            case 'image':
              imageStories++;
              break;
            case 'video':
              videoStories++;
              break;
            case 'text':
              textStories++;
              break;
          }
        }
      }

      yield {
        'totalStories': totalStories,
        'totalUsers': allStories.length,
        'imageStories': imageStories,
        'videoStories': videoStories,
        'textStories': textStories,
        'unviewedUsers': unviewedUsers,
      };
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PAGINATION SUPPORT (para futuras extensiones)
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias paginadas
  Stream<List<UserStories>> getStoriesPaginated({
    int limit = 20,
    int offset = 0,
  }) async* {
    await for (final allStories in getStoriesFromWhitelist()) {
      if (offset >= allStories.length) {
        yield [];
        continue;
      }

      final endIndex = (offset + limit).clamp(0, allStories.length);
      final paginatedStories = allStories.sublist(offset, endIndex);

      yield paginatedStories;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // DEBUGGING & METRICS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener información de debugging
  Map<String, dynamic> getDebugInfo() {
    return {
      'cacheValid': isCacheValid(),
      'backgroundActive': isBackgroundActive,
      'cacheMetrics': getCacheMetrics(),
      'streamMetrics': _streamManager.getMetrics(),
      'contactsCache': _contactRepository.getCachedContactIds()?.length ?? 0,
    };
  }

  /// Log estado actual para debugging
  void logCurrentState() {
    // Método vacío - logs removidos según CODING_RULES.md
  }
}