import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import '../repositories/story_repository.dart';
import '../managers/story_cache_manager.dart';
import '../../../models/story.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado para aprobación de historias (parent-child flow)
///
/// Responsabilidades:
/// - Lógica de aprobación/rechazo de historias
/// - Streams de historias pendientes/aprobadas/rechazadas
/// - Notificaciones de cambios de estado
/// - Gestión de permisos padre-hijo
class StoryApprovalService {
  final StoryRepository _storyRepository;
  final StoryCacheManager _cacheManager;
  final FirebaseFunctions _functions;

  StoryApprovalService({
    required StoryRepository storyRepository,
    required StoryCacheManager cacheManager,
    FirebaseFunctions? functions,
  }) : _storyRepository = storyRepository,
       _cacheManager = cacheManager,
       _functions = functions ?? FirebaseFunctions.instance;

  // ═══════════════════════════════════════════════════════════════
  // APPROVAL ACTIONS
  // ═══════════════════════════════════════════════════════════════

  /// Aprobar historia usando Cloud Function (SEGURO)
  Future<void> approveStory(String storyId, {String? message}) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    try {
      // Llamar Cloud Function segura
      final result = await _functions.httpsCallable('approveStory').call({
        'storyId': storyId,
        'message': message,
      });

      final response = result.data as Map<String, dynamic>;

      if (response['success'] == true) {
        // Actualizar cache local después de éxito server-side
        _cacheManager.updateStoryStatus(storyId, StoryStatus.approved);
      } else {
        throw Exception(
          'Cloud Function falló: ${response['message'] ?? 'Error desconocido'}',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        'Error llamando Cloud Function approveStory: $e',
        tag: 'StoryApproval',
      );
      throw Exception('Error aprobando historia: $e');
    }
  }

  /// Rechazar historia usando Cloud Function (SEGURO)
  Future<void> rejectStory(String storyId, {String? reason}) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    try {
      // Llamar Cloud Function segura
      final result = await _functions.httpsCallable('rejectStory').call({
        'storyId': storyId,
        'reason': reason,
      });

      final response = result.data as Map<String, dynamic>;

      if (response['success'] == true) {
        // Actualizar cache local después de éxito server-side
        _cacheManager.updateStoryStatus(storyId, StoryStatus.rejected);
      } else {
        throw Exception(
          'Cloud Function returned failure: ${response['message'] ?? 'Unknown error'}',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        'Error en Cloud Function rejectStory: $e',
        tag: 'StoryApproval',
      );
      throw Exception('Error rechazando historia: $e');
    }
  }

  /// Aprobar múltiples historias en batch
  Future<void> approveMultipleStories(
    List<String> storyIds, {
    String? message,
  }) async {
    final futures = storyIds.map(
      (storyId) => approveStory(storyId, message: message),
    );

    await Future.wait(futures);
  }

  /// Rechazar múltiples historias en batch
  Future<void> rejectMultipleStories(
    List<String> storyIds, {
    String? reason,
  }) async {
    final futures = storyIds.map(
      (storyId) => rejectStory(storyId, reason: reason),
    );

    await Future.wait(futures);
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAMS FOR PARENT DASHBOARD
  // ═══════════════════════════════════════════════════════════════

  /// Stream de historias pendientes para padre
  Stream<List<Story>> getPendingStoriesForParent() {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _storyRepository.getPendingForParent(currentUserId);
  }

  /// Stream de historias aprobadas por padre
  Stream<List<Story>> getApprovedStoriesForParent() {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _storyRepository.getApprovedByParent(currentUserId);
  }

  /// Stream de historias rechazadas por padre
  Stream<List<Story>> getRejectedStoriesForParent() {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return _storyRepository.getRejectedByParent(currentUserId);
  }

  /// Stream de historias pendientes para un hijo específico
  Stream<List<Story>> getPendingStoriesForChild(String childId) {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return getPendingStoriesForParent().map(
      (stories) => stories.where((story) => story.userId == childId).toList(),
    );
  }

  /// Stream de historias aprobadas para un hijo específico
  Stream<List<Story>> getApprovedStoriesForChild(String childId) {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return getApprovedStoriesForParent().map(
      (stories) => stories.where((story) => story.userId == childId).toList(),
    );
  }

  /// Stream de historias rechazadas para un hijo específico
  Stream<List<Story>> getRejectedStoriesForChild(String childId) {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      return Stream.value([]);
    }

    return getRejectedStoriesForParent().map(
      (stories) => stories.where((story) => story.userId == childId).toList(),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // AGGREGATED STREAMS & STATS
  // ═══════════════════════════════════════════════════════════════

  /// Stream de conteo de historias pendientes
  Stream<int> getPendingStoriesCount() {
    return getPendingStoriesForParent().map((stories) => stories.length);
  }

  /// Stream de conteo de historias por hijo
  Stream<Map<String, int>> getPendingStoriesCountByChild() {
    return getPendingStoriesForParent().map((stories) {
      final countByChild = <String, int>{};

      for (final story in stories) {
        countByChild[story.userId] = (countByChild[story.userId] ?? 0) + 1;
      }

      return countByChild;
    });
  }

  /// Stream de estadísticas de aprobación
  Stream<Map<String, dynamic>> getApprovalStats() async* {
    await for (final _ in getPendingStoriesForParent()) {
      // Combinar datos de múltiples streams
      final pendingStories = await getPendingStoriesForParent().first;
      final approvedStories = await getApprovedStoriesForParent().first;
      final rejectedStories = await getRejectedStoriesForParent().first;

      // Calcular estadísticas por período
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final weekStart = now.subtract(Duration(days: 7));

      final todayPending = pendingStories
          .where((s) => s.createdAt.isAfter(todayStart))
          .length;

      final todayApproved = approvedStories
          .where((s) => s.createdAt.isAfter(todayStart))
          .length;

      final weekPending = pendingStories
          .where((s) => s.createdAt.isAfter(weekStart))
          .length;

      yield {
        'totalPending': pendingStories.length,
        'totalApproved': approvedStories.length,
        'totalRejected': rejectedStories.length,
        'todayPending': todayPending,
        'todayApproved': todayApproved,
        'weekPending': weekPending,
      };
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PERMISSION VALIDATION
  // ═══════════════════════════════════════════════════════════════
  // NOTA: Validación de permisos movida a Cloud Functions para mayor seguridad

  /// Verificar si usuario puede aprobar historias de un hijo
  Future<bool> canApproveForChild(String childId) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) return false;

    try {
      // En implementación real, verificar relación padre-hijo
      // Por ahora, simple verificación de usuario diferente
      return currentUserId != childId;
    } catch (e) {
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // NOTIFICATION HELPERS
  // ═══════════════════════════════════════════════════════════════
  // NOTA: Notificaciones movidas a Cloud Functions para mayor seguridad

  // ═══════════════════════════════════════════════════════════════
  // UTILITIES
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias que requieren acción del padre actual
  Future<List<Story>> getStoriesRequiringAction() async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) return [];

    final pendingStories = await getPendingStoriesForParent().first;
    return pendingStories;
  }

  /// Verificar si hay historias pendientes
  Future<bool> hasPendingStories() async {
    final pendingCount = await getPendingStoriesCount().first;
    return pendingCount > 0;
  }

  /// Obtener tiempo promedio de aprobación
  Future<Duration?> getAverageApprovalTime() async {
    try {
      final approvedStories = await getApprovedStoriesForParent().first;

      if (approvedStories.isEmpty) return null;

      final totalSeconds = approvedStories
          .where((story) => story.approvedAt != null)
          .map(
            (story) => story.approvedAt!.difference(story.createdAt).inSeconds,
          )
          .fold<int>(0, (sum, seconds) => sum + seconds);

      final averageSeconds = totalSeconds / approvedStories.length;
      return Duration(seconds: averageSeconds.round());
    } catch (e) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // DEBUG UTILITIES
  // ═══════════════════════════════════════════════════════════════

  /// Log estado actual de aprobaciones
  Future<void> logApprovalState() async {
    try {
      final stats = await getApprovalStats().first;
      ReleaseLogger.error(
        'Approval Service State: $stats',
        tag: 'StoryApproval',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error logging approval state: $e',
        tag: 'StoryApproval',
      );
    }
  }
}
