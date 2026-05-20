import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../models/story.dart';
import 'repositories/story_repository.dart';
import 'repositories/contact_repository.dart';
import 'services/story_creation_service.dart';
import 'services/story_retrieval_service.dart';
import 'services/story_approval_service.dart';
import 'services/story_viewing_service.dart';
import 'managers/story_cache_manager.dart';
import 'managers/story_stream_manager.dart';
import 'managers/story_upload_manager.dart';

/// Orchestrator principal que coordina todos los servicios de historias
///
/// Responsabilidades:
/// - Coordinar entre servicios especializados
/// - Mantener API pública compatible
/// - Gestionar dependencias entre servicios
/// - Proporcionar punto único de acceso
class StoryOrchestrator {
  // Repositorios (Data Layer)
  late final StoryRepository _storyRepository;
  late final ContactRepository _contactRepository;

  // Servicios especializados (Business Logic Layer)
  late final StoryCreationService _creationService;
  late final StoryRetrievalService _retrievalService;
  late final StoryApprovalService _approvalService;
  late final StoryViewingService _viewingService;

  // Managers (Data Layer)
  late final StoryCacheManager _cacheManager;
  late final StoryStreamManager _streamManager;
  late final StoryUploadManager _uploadManager;

  // Singleton instance
  static StoryOrchestrator? _instance;

  /// Factory constructor que devuelve singleton
  factory StoryOrchestrator({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
  }) {
    _instance ??= StoryOrchestrator._internal(
      firestore: firestore,
      auth: auth,
      storage: storage,
    );
    return _instance!;
  }

  /// Constructor interno para inicialización
  StoryOrchestrator._internal({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
  }) {
    _initializeServices(firestore, auth, storage);
  }

  /// Inicializar todos los servicios y sus dependencias
  void _initializeServices(
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
  ) {
    // Repositorios base
    _storyRepository = StoryRepository(
      firestore: firestore ?? FirebaseFirestore.instance,
      auth: auth ?? FirebaseAuth.instance,
    );

    _contactRepository = ContactRepository(
      firestore: firestore ?? FirebaseFirestore.instance,
      auth: auth ?? FirebaseAuth.instance,
    );

    // Managers
    _cacheManager = StoryCacheManager();
    _uploadManager = StoryUploadManager(
      storage: storage ?? FirebaseStorage.instance,
    );

    _streamManager = StoryStreamManager(
      storyRepository: _storyRepository,
      contactRepository: _contactRepository,
      cacheManager: _cacheManager,
    );

    // Servicios especializados
    _creationService = StoryCreationService(
      storyRepository: _storyRepository,
      uploadManager: _uploadManager,
      cacheManager: _cacheManager,
      contactRepository: _contactRepository,
    );

    _retrievalService = StoryRetrievalService(
      streamManager: _streamManager,
      cacheManager: _cacheManager,
      contactRepository: _contactRepository,
    );

    _approvalService = StoryApprovalService(
      storyRepository: _storyRepository,
      cacheManager: _cacheManager,
    );

    _viewingService = StoryViewingService(storyRepository: _storyRepository);
  }

  // ═══════════════════════════════════════════════════════════════
  // API PÚBLICA - Compatible con StoryService actual
  // ═══════════════════════════════════════════════════════════════

  /// Crear nueva historia (optimistic)
  Future<String> createStory({
    required String mediaType,
    required String mediaPath,
    String? text,
    Map<String, dynamic>? filter,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
    return await _creationService.createStory(
      mediaType: mediaType,
      mediaPath: mediaPath,
      text: text,
      filter: filter,
      onProgressUpdate: onProgressUpdate,
    );
  }

  /// Crear historia de mood (respuesta a encuesta)
  Future<String> createMoodStory({
    required String emoji,
    required String text,
    required String questionText,
  }) async {
    return await _creationService.createMoodStory(
      emoji: emoji,
      text: text,
      questionText: questionText,
    );
  }

  /// Obtener stream de historias desde whitelist
  Stream<List<UserStories>> getStoriesFromWhitelist() {
    return _retrievalService.getStoriesFromWhitelist();
  }

  /// Obtener stream reactivo desde cache
  Stream<List<UserStories>> get storiesFromCache {
    return _retrievalService.storiesFromCache;
  }

  /// Obtener cache actual (snapshot síncrono)
  List<UserStories> getCachedStories() {
    return _cacheManager.getCachedStories();
  }

  /// Marcar historia como vista
  /// ✅ FIX #7: También actualiza cache local para UI instantánea
  Future<void> markStoryAsViewed(String storyId) async {
    final currentUserId = _storyRepository.currentUserId;

    // Primero actualizar cache local para UI instantánea (optimistic update)
    if (currentUserId != null) {
      _cacheManager.markStoryAsViewedLocally(storyId, currentUserId);
    }

    // Luego actualizar Firestore (confirmación)
    await _viewingService.markStoryAsViewed(storyId);
  }

  /// Eliminar historia
  Future<void> deleteStory(String storyId) async {
    await _creationService.deleteStory(storyId);
  }

  /// Aprobar historia (parent)
  Future<void> approveStory(String storyId, {String? message}) async {
    await _approvalService.approveStory(storyId, message: message);
  }

  /// Rechazar historia (parent)
  Future<void> rejectStory(String storyId, {String? reason}) async {
    await _approvalService.rejectStory(storyId, reason: reason);
  }

  /// Restaurar historia rechazada a pending (undo de reject)
  Future<void> restoreStoryToPending(String storyId) async {
    await _approvalService.restoreStoryToPending(storyId);
  }

  /// Obtener historias pendientes para padre
  Stream<List<Story>> getPendingStoriesForParent() {
    return _approvalService.getPendingStoriesForParent();
  }

  /// Obtener historias aprobadas para padre
  Stream<List<Story>> getApprovedStoriesForParent() {
    return _approvalService.getApprovedStoriesForParent();
  }

  /// Obtener historias rechazadas para padre
  Stream<List<Story>> getRejectedStoriesForParent() {
    return _approvalService.getRejectedStoriesForParent();
  }

  /// Responder a historia
  Future<void> replyToStory({
    required String storyId,
    required String replyText,
    String? replyMediaPath,
    String? replyMediaType,
  }) async {
    // Actualizar Firestore - el cache se actualizará via stream
    await _viewingService.replyToStory(
      storyId: storyId,
      replyText: replyText,
      replyMediaPath: replyMediaPath,
      replyMediaType: replyMediaType,
    );
  }

  /// Dar like a una historia
  /// Agrega el userId a likedBy y envía mensaje al chat del owner
  /// También actualiza el cache local para UI instantánea
  Future<void> likeStory(String storyId) async {
    final currentUserId = _storyRepository.currentUserId;

    // Primero actualizar cache local para UI instantánea (optimistic update)
    if (currentUserId != null) {
      _cacheManager.updateStoryLikeLocally(storyId, currentUserId, true);
    }

    // Luego actualizar Firestore (confirmación)
    await _viewingService.likeStory(storyId);
  }

  /// Quitar like de una historia
  /// Remueve el userId de likedBy (no borra el mensaje del chat)
  /// También actualiza el cache local para UI instantánea
  Future<void> unlikeStory(String storyId) async {
    final currentUserId = _storyRepository.currentUserId;

    // Primero actualizar cache local para UI instantánea (optimistic update)
    if (currentUserId != null) {
      _cacheManager.updateStoryLikeLocally(storyId, currentUserId, false);
    }

    // Luego actualizar Firestore (confirmación)
    await _viewingService.unlikeStory(storyId);
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar background processes
  Future<void> startBackgroundProcesses() async {
    await _streamManager.startBackgroundStreams();
  }

  /// Detener background processes
  void stopBackgroundProcesses() {
    _streamManager.stopBackgroundStreams();
  }

  /// Limpiar historias expiradas
  Future<void> cleanupExpiredStories() async {
    await _storyRepository.cleanupExpiredStories();
    _cacheManager.removeExpiredStories();
  }

  /// Dispose del orchestrator
  void dispose() {
    stopBackgroundProcesses();
    _cacheManager.dispose();
    _uploadManager.dispose();
    _instance = null;
  }

  // ═══════════════════════════════════════════════════════════════
  // DEBUG & TESTING HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Acceso a cache manager para testing
  StoryCacheManager get cacheManagerForTesting => _cacheManager;

  /// Acceso a stream manager para testing
  StoryStreamManager get streamManagerForTesting => _streamManager;

  /// Forzar refresh de cache (para testing)
  Future<void> forceRefreshCache() async {
    await _streamManager.forceRefresh();
  }

  /// Soft refresh: reinicia streams SIN invalidar cache de historias
  /// ✅ FIX: Usado cuando la app vuelve de background para evitar parpadeo
  Future<void> softRefreshCache() async {
    await _streamManager.softRefresh();
  }

  /// Limpiar cache completamente
  void clearCache() {
    _cacheManager.invalidateCache();
  }

  /// Limpiar cache completamente al cerrar sesión
  /// Resetea todo incluyendo _hasBeenPopulated
  void resetForLogout() {
    stopBackgroundProcesses();
    _cacheManager.resetForLogout();
  }

  /// Obtener métricas de performance
  Map<String, dynamic> getPerformanceMetrics() {
    return {
      'cacheSize': _cacheManager.getCachedStories().length,
      'activeStreams': _streamManager.getActiveStreamCount(),
      'pendingUploads': _uploadManager.getPendingUploadsCount(),
      'cacheHitRate': _cacheManager.getCacheHitRate(),
    };
  }
}
