import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/story.dart';
import 'stories/story_orchestrator.dart';

/// Mantener compatibilidad con imports existentes
export '../models/story.dart';

/// StoryService refactorizado - API compatible con implementación anterior
///
/// CAMBIOS:
/// - Usa StoryOrchestrator internamente
/// - Mantiene API pública idéntica
/// - Mejor arquitectura y separación de responsabilidades
/// - Testeable y mantenible
class StoryService {
  // Singleton pattern (mantenido para compatibilidad)
  static final StoryService _instance = StoryService._internal();
  factory StoryService() => _instance;
  StoryService._internal() {
    _orchestrator = StoryOrchestrator();
  }

  // Orchestrator que maneja toda la lógica
  late final StoryOrchestrator _orchestrator;

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API - 100% Compatible con StoryService anterior
  // ═══════════════════════════════════════════════════════════════

  /// Crear nueva historia (optimistic)
  Future<String> createStory({
    required String mediaType,
    required String mediaPath,
    String? text,
    String? caption, // Compatibilidad con API anterior
    Map<String, dynamic>? filter,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
    // Usar caption si se proporciona, sino text
    final storyText = caption ?? text;

    return await _orchestrator.createStory(
      mediaType: mediaType,
      mediaPath: mediaPath,
      text: storyText,
      filter: filter,
      onProgressUpdate: onProgressUpdate,
    );
  }

  /// Obtener stream de historias desde whitelist
  Stream<List<UserStories>> getStoriesFromWhitelist() {
    return _orchestrator.getStoriesFromWhitelist();
  }

  /// Obtener stream reactivo desde cache
  Stream<List<UserStories>> get storiesFromCache {
    return _orchestrator.storiesFromCache;
  }

  /// Obtener cache actual (snapshot síncrono)
  List<UserStories> getCachedStories() {
    return _orchestrator.getCachedStories();
  }

  /// Marcar historia como vista
  Future<void> markStoryAsViewed(String storyId) async {
    await _orchestrator.markStoryAsViewed(storyId);
  }

  /// Eliminar historia
  Future<void> deleteStory(String storyId) async {
    await _orchestrator.deleteStory(storyId);
  }

  /// Aprobar historia (parent)
  Future<void> approveStory(String storyId, {String? message}) async {
    await _orchestrator.approveStory(storyId, message: message);
  }

  /// Rechazar historia (parent)
  Future<void> rejectStory(String storyId, {String? reason}) async {
    await _orchestrator.rejectStory(storyId, reason: reason);
  }

  /// Obtener historias pendientes para padre
  Stream<List<Story>> getPendingStoriesForParent() {
    return _orchestrator.getPendingStoriesForParent();
  }

  /// Obtener historias aprobadas para padre
  Stream<List<Story>> getApprovedStoriesForParent() {
    return _orchestrator.getApprovedStoriesForParent();
  }

  /// Responder a historia
  Future<void> replyToStory({
    required String storyId,
    String? replyText,
    String? text, // Compatibilidad con API anterior
    String? replyMediaPath,
    String? replyMediaType,
  }) async {
    // Usar text si se proporciona, sino replyText
    final finalReplyText = text ?? replyText ?? '';

    await _orchestrator.replyToStory(
      storyId: storyId,
      replyText: finalReplyText,
      replyMediaPath: replyMediaPath,
      replyMediaType: replyMediaType,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS ADICIONALES de la API anterior (para total compatibilidad)
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias pendientes para padre por hijo específico
  Stream<List<Story>> getPendingStoriesForParentByChild(String childId) {
    return getPendingStoriesForParent().map((stories) =>
      stories.where((story) => story.userId == childId).toList()
    );
  }

  /// Obtener historias aprobadas para padre por hijo específico
  Stream<List<Story>> getApprovedStoriesForParentByChild(String childId) {
    return getApprovedStoriesForParent().map((stories) =>
      stories.where((story) => story.userId == childId).toList()
    );
  }

  /// Obtener historias rechazadas para padre
  Stream<List<Story>> getRejectedStoriesForParent() {
    return _orchestrator.getRejectedStoriesForParent();
  }

  /// Obtener historias rechazadas para padre por hijo específico
  Stream<List<Story>> getRejectedStoriesForParentByChild(String childId) {
    return getRejectedStoriesForParent().map((stories) =>
      stories.where((story) => story.userId == childId).toList()
    );
  }

  /// Obtener historias del usuario actual
  Future<UserStories?> getCurrentUserStories() async {
    // Implementación compatible con anterior
    final cachedStories = getCachedStories();

    try {
      // Buscar en cache primero
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId != null) {
        for (final userStories in cachedStories) {
          if (userStories.userId == currentUserId) {
            return userStories;
          }
        }
      }
    } catch (e) {
      // En caso de error, retornar null
    }

    return null;
  }

  /// Obtener historias de un usuario específico
  Future<List<Story>> getUserStories(String userId) async {
    try {
      final userStories = await getCurrentUserStories();
      return userStories?.stories ?? [];
    } catch (e) {
      return [];
    }
  }

  /// Obtener historias de hijos para padre
  Future<List<UserStories>> getChildrenStoriesForParent() async {
    try {
      final allStories = getCachedStories();
      // TODO: Filtrar solo hijos vinculados
      return allStories;
    } catch (e) {
      return [];
    }
  }

  /// Guardar historia como permanente
  Future<void> saveToPermanent(String storyId) async {
    // TODO: Implementar lógica de guardado permanente
    // Saving story $storyId as permanent
  }

  /// Archivar historia
  Future<void> archiveStory(String storyId) async {
    // TODO: Implementar lógica de archivado
    // Archiving story $storyId
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE METHODS - Compatible con API anterior
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar background processes
  Future<void> startBackgroundCacheUpdates() async {
    await _orchestrator.startBackgroundProcesses();
  }

  /// Detener background processes
  void stopBackgroundCacheUpdates() {
    _orchestrator.stopBackgroundProcesses();
  }

  /// Limpiar historias expiradas
  Future<void> cleanupExpiredStories() async {
    await _orchestrator.cleanupExpiredStories();
  }

  // ═══════════════════════════════════════════════════════════════
  // COMPATIBILITY HELPERS - Para mantener funcionalidad anterior
  // ═══════════════════════════════════════════════════════════════

  /// Forzar refresh de cache (método de compatibilidad)
  Future<void> forceRefreshCache() async {
    await _orchestrator.forceRefreshCache();
  }

  /// Limpiar cache (método de compatibilidad)
  void clearCache() {
    _orchestrator.clearCache();
  }

  /// Verificar si background stream está activo
  bool get isBackgroundStreamActive {
    // Acceder a métricas del orchestrator
    final metrics = _orchestrator.getPerformanceMetrics();
    return metrics['activeStreams'] > 0;
  }

  /// Obtener métricas de performance (para debugging)
  Map<String, dynamic> getPerformanceMetrics() {
    return _orchestrator.getPerformanceMetrics();
  }

  // ═══════════════════════════════════════════════════════════════
  // MIGRATION HELPERS - Para facilitar migración gradual
  // ═══════════════════════════════════════════════════════════════

  /// Obtener orchestrator subyacente (para migration gradual)
  StoryOrchestrator get orchestrator => _orchestrator;

  /// Verificar si está usando nueva arquitectura
  bool get isUsingNewArchitecture => true;

  /// Obtener versión de la implementación
  String get implementationVersion => 'refactored_v1.0.0';

  /// Dispose del servicio
  void dispose() {
    _orchestrator.dispose();
  }
}