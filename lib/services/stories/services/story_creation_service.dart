import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';

import '../repositories/story_repository.dart';
import '../repositories/contact_repository.dart';
import '../managers/story_cache_manager.dart';
import '../managers/story_upload_manager.dart';
import '../utils/media_validation_helper.dart';
import '../../../models/story.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado para creación y eliminación de historias
///
/// Responsabilidades:
/// - Lógica de negocio para crear historias
/// - Upload optimista con UX inmediata
/// - Gestión de aprobaciones padre-hijo
/// - Cleanup y eliminación de historias
class StoryCreationService {
  final StoryRepository _storyRepository;
  final StoryUploadManager _uploadManager;
  final StoryCacheManager _cacheManager;
  final ContactRepository _contactRepository;

  StoryCreationService({
    required StoryRepository storyRepository,
    required StoryUploadManager uploadManager,
    required StoryCacheManager cacheManager,
    required ContactRepository contactRepository,
  }) : _storyRepository = storyRepository,
       _uploadManager = uploadManager,
       _cacheManager = cacheManager,
       _contactRepository = contactRepository;

  // ═══════════════════════════════════════════════════════════════
  // STORY CREATION - OPTIMISTIC UX
  // ═══════════════════════════════════════════════════════════════

  /// Crear nueva historia con UX optimista
  Future<String> createStory({
    required String mediaType,
    required String mediaPath,
    String? text,
    Map<String, dynamic>? filter,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // SEGURIDAD: Validación completa de archivo (formato, tamaño, existencia)
    final validation = await MediaValidationHelper.validateMediaFileComplete(
      mediaPath,
    );
    if (!validation.isValid) {
      throw Exception(
        'Validación de archivo falló: ${validation.errorMessage}',
      );
    }

    // Validar que el mediaType corresponda con la extensión del archivo
    if (!MediaValidationHelper.validateMediaTypeMatchesPath(
      mediaPath,
      mediaType,
    )) {
      final detectedType = MediaValidationHelper.getMediaTypeFromPath(
        mediaPath,
      );
      throw Exception(
        'El tipo de media "$mediaType" no corresponde con el archivo. Tipo detectado: "$detectedType"',
      );
    }

    // 1. Generar ID temporal
    final tempStoryId = _generateTempStoryId();

    try {
      // 2. Crear historia optimista
      final optimisticStory = await _createOptimisticStory(
        storyId: tempStoryId,
        userId: currentUserId,
        mediaType: mediaType,
        mediaPath: mediaPath,
        text: text,
        filter: filter,
      );

      // 3. Agregar a cache optimista (aparece inmediatamente en UI)
      _cacheManager.addOptimisticStory(currentUserId, optimisticStory);

      // 4. Hacer upload síncronamente (errores se propagan correctamente)
      await _uploadStoryAndCreateInDatabase(
        tempStoryId: tempStoryId,
        mediaPath: mediaPath,
        optimisticStory: optimisticStory,
        onProgressUpdate: onProgressUpdate,
      );

      return tempStoryId;
    } catch (e) {
      // Si el proceso falló después de crear la historia optimista, limpiarla
      _cacheManager.removeOptimisticStory(currentUserId, tempStoryId);

      // Re-lanzar el error original para que el UI pueda manejarlo
      rethrow;
    }
  }

  /// Eliminar historia
  Future<void> deleteStory(String storyId) async {
    try {
      // 1. Obtener historia para cleanup
      final story = await _storyRepository.getById(storyId);

      // 2. Eliminar de Firestore
      await _storyRepository.delete(storyId);

      // 3. Eliminar archivos de Storage si existen
      if (story != null) {
        await _cleanupStoryMedia(story);
      }

      // 4. Remover de cache optimista
      if (story != null) {
        _cacheManager.removeOptimisticStory(story.userId, storyId);
      }
    } catch (e) {
      throw Exception('Error eliminando historia: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // OPTIMISTIC STORY CREATION
  // ═══════════════════════════════════════════════════════════════

  /// Crear historia optimista (temporal para UX inmediata)
  Future<Story> _createOptimisticStory({
    required String storyId,
    required String userId,
    required String mediaType,
    required String mediaPath,
    String? text,
    Map<String, dynamic>? filter,
  }) async {
    // Obtener información del usuario
    final userInfo = await _contactRepository.getUserInfo(userId);

    final now = DateTime.now();
    final expiresAt = now.add(Duration(hours: 24));

    return Story(
      id: storyId,
      userId: userId,
      userName: userInfo?['name'] ?? 'Usuario',
      userPhotoURL: userInfo?['photoURL'],
      mediaUrl: '', // Vacío mientras se sube
      mediaType: mediaType,
      caption: text,
      createdAt: now,
      expiresAt: expiresAt,
      viewedBy: [],
      replies: [],
      filter: filter,
      status: StoryStatus.uploading,
      localMediaPath: mediaPath,
      uploadProgress: 0.0,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // BACKGROUND UPLOAD PROCESS
  // ═══════════════════════════════════════════════════════════════

  /// Upload y creación en base de datos (síncronamente)
  Future<void> _uploadStoryAndCreateInDatabase({
    required String tempStoryId,
    required String mediaPath,
    required Story optimisticStory,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
      try {
        // 1. Upload archivo a Storage
        final mediaUrl = await _uploadManager.uploadWithRetry(
          filePath: mediaPath,
          storyId: tempStoryId,
          userId: optimisticStory.userId,
          onProgressUpdate: onProgressUpdate != null
              ? (progress) => onProgressUpdate(tempStoryId, progress)
              : null,
        );

        // 2. SEGURIDAD: Usar Cloud Function con rate limiting
        final functions = FirebaseFunctions.instance;
        final createStoryFunction = functions.httpsCallable('createStory');

        final result = await createStoryFunction.call({
          'mediaType': optimisticStory.mediaType,
          'mediaUrl': mediaUrl,
          'caption': optimisticStory.caption,
          'filter': optimisticStory.filter,
          'tempStoryId': tempStoryId,
        });

        // 3. Validar respuesta de la Cloud Function
        if (!result.data['success']) {
          throw Exception(
            result.data['message'] ?? 'Error creando historia en servidor',
          );
        }

        final serverStatus = result.data['status'];
        final storyStatus = serverStatus == 'approved'
            ? StoryStatus.approved
            : StoryStatus.pending;

        // 4. Crear story actualizada con datos del servidor
        final realStory = optimisticStory.copyWith(
          mediaUrl: mediaUrl,
          localMediaPath: null,
          status: storyStatus,
        );

        // 5. Actualizar cache optimista con URL real
        _cacheManager.updateOptimisticStory(
          optimisticStory.userId,
          tempStoryId,
          realStory,
        );

        // 6. NOTA: Los approval requests ahora se crean en la Cloud Function
        // No necesitamos crearlos aquí ya que la función server-side lo maneja
      } catch (e) {
        // En caso de error, remover historia optimista
        _cacheManager.removeOptimisticStory(
          optimisticStory.userId,
          tempStoryId,
        );

        // Log error y re-lanzar para que se propague al caller
        ReleaseLogger.error(
          'Error en upload y creación de historia: $e',
          tag: 'StoryCreation',
        );

        // Re-lanzar la excepción para que el usuario vea el error
        rethrow;
      }
  }

  // ═══════════════════════════════════════════════════════════════
  // MEDIA CLEANUP
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar archivos de media de una historia
  Future<void> _cleanupStoryMedia(Story story) async {
    try {
      // Eliminar archivo principal
      if (story.mediaUrl.isNotEmpty) {
        await _uploadManager.deleteStoryMedia(story.mediaUrl);
      }

      // Eliminar archivos adicionales si existen
      // (para futuras extensiones como múltiples media)
    } catch (e) {
      // Log error pero no fallar eliminación principal
      ReleaseLogger.error('Error limpiando media: $e', tag: 'StoryCreation');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Generar ID temporal único
  String _generateTempStoryId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return 'temp_story_${timestamp}_$random';
  }
}
