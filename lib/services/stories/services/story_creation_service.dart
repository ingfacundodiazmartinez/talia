import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../repositories/story_repository.dart';
import '../repositories/contact_repository.dart';
import '../managers/story_cache_manager.dart';
import '../managers/story_upload_manager.dart';
import '../utils/media_validation_helper.dart';
import '../../../models/story.dart';
import '../../../services/media_compression_service.dart';
import '../../../services/optimistic_story_media_cache.dart';
import '../../../utils/release_logger.dart';
import '../failed_story_store.dart';

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
    bool aiGenerated = false,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
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
    Story? builtOptimistic;

    try {
      // 2. Crear historia optimista
      final optimisticStory = await _createOptimisticStory(
        storyId: tempStoryId,
        userId: currentUserId,
        mediaType: mediaType,
        mediaPath: mediaPath,
        text: text,
        filter: filter,
        aiGenerated: aiGenerated,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings,
      );
      builtOptimistic = optimisticStory;

      // 3. Agregar a cache optimista (aparece inmediatamente en UI)
      _cacheManager.addOptimisticStory(currentUserId, optimisticStory);

      // 3b. Registrar el path local en el cache para que el viewer pueda
      // mostrar la imagen mientras se sube, aunque el stream re-emita
      // la story desde Firestore (donde localMediaPath no se persiste).
      OptimisticStoryMediaCache().set(tempStoryId, mediaPath);

      // 4. Hacer upload síncronamente (errores se propagan correctamente)
      await _uploadStoryAndCreateInDatabase(
        tempStoryId: tempStoryId,
        mediaPath: mediaPath,
        optimisticStory: optimisticStory,
        aiGenerated: aiGenerated,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings,
        onProgressUpdate: onProgressUpdate,
      );

      // Upload completado con éxito → mediaUrl ya está en Firestore.
      OptimisticStoryMediaCache().clear(tempStoryId);

      return tempStoryId;
    } catch (e) {
      // En vez de descartar la historia (se perdía al cerrar la app), la
      // guardamos localmente como "fallida" para poder reintentarla.
      await _persistFailedStory(
        tempStoryId: tempStoryId,
        userId: currentUserId,
        userName: builtOptimistic?.userName ?? 'Usuario',
        userPhotoURL: builtOptimistic?.userPhotoURL,
        mediaType: mediaType,
        sourceMediaPath: mediaPath,
        caption: text,
        aiGenerated: aiGenerated,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings,
        error: e.toString(),
      );

      // Re-lanzar el error original para que el UI pueda mostrar el aviso.
      rethrow;
    }
  }

  /// Guarda una historia fallida en el store persistente y la deja visible en
  /// el cache optimista con estado `failed` (con botón de reintento en la UI).
  Future<void> _persistFailedStory({
    required String tempStoryId,
    required String userId,
    required String userName,
    String? userPhotoURL,
    required String mediaType,
    String? sourceMediaPath,
    String? caption,
    bool aiGenerated = false,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
    String? error,
  }) async {
    try {
      final record = await FailedStoryStore().save(
        id: tempStoryId,
        userId: userId,
        userName: userName,
        userPhotoURL: userPhotoURL,
        mediaType: mediaType,
        sourceMediaPath: sourceMediaPath,
        caption: caption,
        aiGenerated: aiGenerated,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings ?? const [],
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        error: error,
      );

      // Mostrar la historia fallida en la UI apuntando al media persistido.
      if (record.localMediaPath != null) {
        OptimisticStoryMediaCache().set(tempStoryId, record.localMediaPath!);
      } else {
        OptimisticStoryMediaCache().clear(tempStoryId);
      }
      _cacheManager.updateOrAddOptimisticStory(userId, record.toStory());
    } catch (e) {
      // Si ni siquiera pudimos persistir, al menos removemos la optimista rota.
      ReleaseLogger.error('No se pudo persistir historia fallida: $e',
          tag: 'StoryCreation');
      _cacheManager.removeOptimisticStory(userId, tempStoryId);
      OptimisticStoryMediaCache().clear(tempStoryId);
    }
  }

  /// Carga las historias fallidas persistidas al cache optimista (al iniciar).
  Future<void> loadFailedStoriesIntoCache() async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) return;
    final records = await FailedStoryStore().getForUser(currentUserId);
    for (final r in records) {
      if (r.localMediaPath != null) {
        OptimisticStoryMediaCache().set(r.id, r.localMediaPath!);
      }
      _cacheManager.updateOrAddOptimisticStory(currentUserId, r.toStory());
    }
  }

  /// Descarta una historia fallida (la borra del store y de la UI).
  Future<void> discardFailedStory(String storyId) async {
    final currentUserId = _storyRepository.currentUserId;
    await FailedStoryStore().remove(storyId);
    OptimisticStoryMediaCache().clear(storyId);
    if (currentUserId != null) {
      _cacheManager.removeOptimisticStory(currentUserId, storyId);
    }
  }

  /// Reintenta subir una historia fallida. Devuelve true si quedó encolada.
  Future<bool> retryFailedStory(String storyId) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) return false;
    final records = await FailedStoryStore().getForUser(currentUserId);
    final matches = records.where((r) => r.id == storyId).toList();
    if (matches.isEmpty) return false;
    final r = matches.first;

    // Sacamos la versión fallida de la UI; el flujo de creación agrega una nueva
    // historia optimista (en estado uploading) con su propio id.
    _cacheManager.removeOptimisticStory(currentUserId, storyId);

    try {
      if (r.isMusicOnly) {
        if (r.musicUrl == null) throw Exception('musicUrl ausente');
        await createMusicOnlyStory(
          musicUrl: r.musicUrl!,
          musicPrompt: r.musicPrompt,
          musicLyrics: r.musicLyrics,
          musicStartMs: r.musicStartMs,
          musicClipMs: r.musicClipMs,
          musicTitle: r.musicTitle,
          musicDisplayMode: r.musicDisplayMode,
          musicLyricsTimings: r.musicLyricsTimings,
          caption: r.caption,
        );
      } else {
        final path = r.localMediaPath;
        if (path == null || !await File(path).exists()) {
          throw Exception('El archivo de la historia ya no está disponible');
        }
        await createStory(
          mediaType: r.mediaType,
          mediaPath: path,
          text: r.caption,
          aiGenerated: r.aiGenerated,
          musicUrl: r.musicUrl,
          musicPrompt: r.musicPrompt,
          musicLyrics: r.musicLyrics,
          musicStartMs: r.musicStartMs,
          musicClipMs: r.musicClipMs,
          musicTitle: r.musicTitle,
          musicDisplayMode: r.musicDisplayMode,
          musicLyricsTimings: r.musicLyricsTimings,
        );
      }
      // Éxito: borrar el registro fallido persistido.
      await FailedStoryStore().remove(storyId);
      return true;
    } catch (e) {
      // createStory/createMusicOnlyStory ya re-persistió el fallo con un id
      // nuevo; borramos el registro viejo para no duplicar.
      await FailedStoryStore().remove(storyId);
      ReleaseLogger.warning('Reintento de historia falló de nuevo: $e',
          tag: 'StoryCreation');
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

      // 5. ✅ FIX: Limpiar story_approval_requests asociados
      // Esto evita que el padre vea solicitudes para historias eliminadas
      await _cleanupStoryApprovalRequests(storyId);
    } catch (e) {
      throw Exception('Error eliminando historia: $e');
    }
  }

  /// Limpiar solicitudes de aprobación y notificaciones asociadas a una historia eliminada
  Future<void> _cleanupStoryApprovalRequests(String storyId) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();
      int cleanedCount = 0;

      // 1. Eliminar story_approval_requests
      final approvalRequests = await firestore
          .collection('story_approval_requests')
          .where('storyId', isEqualTo: storyId)
          .get();

      for (final doc in approvalRequests.docs) {
        batch.delete(doc.reference);
        cleanedCount++;
      }

      // 2. Eliminar notificaciones asociadas
      final notifications = await firestore
          .collection('notifications')
          .where('type', isEqualTo: 'story_approval_request')
          .where('data.storyId', isEqualTo: storyId)
          .get();

      for (final doc in notifications.docs) {
        batch.delete(doc.reference);
        cleanedCount++;
      }

      if (cleanedCount > 0) {
        await batch.commit();
        ReleaseLogger.log(
          'Cleanup: ${approvalRequests.docs.length} requests, ${notifications.docs.length} notificaciones para historia $storyId',
          tag: 'StoryCreation',
        );
      }
    } catch (e) {
      // No fallar la eliminación principal si esto falla
      // El trigger onStoryDeleted en Cloud Functions es el safety net
      ReleaseLogger.error(
        'Error en cleanup (trigger CF lo reintentará): $e',
        tag: 'StoryCreation',
      );
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
    bool aiGenerated = false,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
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
      aiGenerated: aiGenerated,
      musicUrl: musicUrl,
      musicPrompt: musicPrompt,
      musicLyrics: musicLyrics,
      musicStartMs: musicStartMs,
      musicClipMs: musicClipMs,
      musicTitle: musicTitle,
      musicDisplayMode: musicDisplayMode,
      musicLyricsTimings: (musicLyricsTimings ?? const [])
          .map((m) => LyricLine.fromMap(m))
          .toList(),
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
    bool aiGenerated = false,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
      try {
        // 1. ✅ OPTIMIZACIÓN: Comprimir imagen/video antes de subir
        String finalMediaPath = mediaPath;
        final compressionService = MediaCompressionService();

        if (optimisticStory.mediaType == 'image') {
          final imageFile = File(mediaPath);
          final compressedFile = await compressionService.compressImage(imageFile);
          if (compressedFile != null) {
            finalMediaPath = compressedFile.path;
          }
        } else if (optimisticStory.mediaType == 'video') {
          // Comprimir video para mejor tiempo de carga
          final videoFile = File(mediaPath);
          final compressedFile = await compressionService.compressVideoForStory(videoFile);
          if (compressedFile != null) {
            finalMediaPath = compressedFile.path;
          }
        }

        // 2. Upload archivo a Storage
        final mediaUrl = await _uploadManager.uploadWithRetry(
          filePath: finalMediaPath,
          storyId: tempStoryId,
          userId: optimisticStory.userId,
          onProgressUpdate: onProgressUpdate != null
              ? (progress) => onProgressUpdate(tempStoryId, progress)
              : null,
        );

        // 3. SEGURIDAD: Usar Cloud Function con rate limiting
        final functions = FirebaseFunctions.instance;
        final createStoryFunction = functions.httpsCallable('createStory');

        final result = await createStoryFunction.call({
          'mediaType': optimisticStory.mediaType,
          'mediaUrl': mediaUrl,
          'caption': optimisticStory.caption,
          'filter': optimisticStory.filter,
          'tempStoryId': tempStoryId,
          'aiGenerated': aiGenerated,
          if (musicUrl != null) 'musicUrl': musicUrl,
          if (musicPrompt != null) 'musicPrompt': musicPrompt,
          if (musicLyrics != null) 'musicLyrics': musicLyrics,
          if (musicStartMs != null) 'musicStartMs': musicStartMs,
          if (musicClipMs != null) 'musicClipMs': musicClipMs,
          if (musicTitle != null) 'musicTitle': musicTitle,
          if (musicDisplayMode != null) 'musicDisplayMode': musicDisplayMode,
          if (musicLyricsTimings != null) 'musicLyricsTimings': musicLyricsTimings,
        });

        // 4. Validar respuesta de la Cloud Function
        if (!result.data['success']) {
          throw Exception(
            result.data['message'] ?? 'Error creando historia en servidor',
          );
        }

        final serverStatus = result.data['status'];
        final storyStatus = serverStatus == 'approved'
            ? StoryStatus.approved
            : StoryStatus.pending;

        // 5. Crear story actualizada con datos del servidor
        final realStory = optimisticStory.copyWith(
          mediaUrl: mediaUrl,
          localMediaPath: null,
          status: storyStatus,
        );

        // 6. Actualizar cache optimista con URL real
        _cacheManager.updateOptimisticStory(
          optimisticStory.userId,
          tempStoryId,
          realStory,
        );

        // 7. NOTA: Los approval requests ahora se crean en la Cloud Function
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

  // ═══════════════════════════════════════════════════════════════
  // MOOD STORY CREATION
  // ═══════════════════════════════════════════════════════════════

  /// Crear historia de mood (respuesta a encuesta)
  /// Esta historia no tiene media, solo un fondo de color con emoji y texto
  Future<String> createMoodStory({
    required String emoji,
    required String text,
    required String questionText,
  }) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 1. Generar ID
    final storyId = _generateTempStoryId();

    try {
      // 2. Obtener información del usuario y AMIGOS (no todos los contactos)
      // ✅ FRIENDS ONLY: Solo amigos pueden ver historias
      final userInfo = await _contactRepository.getUserInfo(currentUserId);
      final friendIds = await _contactRepository.getFriendIds();

      final now = DateTime.now();
      final expiresAt = now.add(Duration(hours: 24));

      // 3. Crear historia de tipo "mood"
      // El mediaUrl contendrá un placeholder especial que el UI interpretará
      // para mostrar un fondo de color con el emoji
      final moodStory = Story(
        id: storyId,
        userId: currentUserId,
        userName: userInfo?['name'] ?? 'Usuario',
        userPhotoURL: userInfo?['photoURL'],
        mediaUrl: 'mood://$emoji', // URL especial para mood stories
        mediaType: 'mood',
        caption: '$emoji $text', // Emoji + respuesta
        createdAt: now,
        expiresAt: expiresAt,
        viewedBy: [],
        replies: [],
        filter: {
          'type': 'mood_poll',
          'emoji': emoji,
          'text': text,
          'questionText': questionText,
        },
        status: StoryStatus.approved, // Mood stories se aprueban automáticamente
        availableFor: friendIds.toList(), // ✅ FRIENDS ONLY: Solo amigos pueden ver
      );

      // 4. Agregar a cache optimista
      _cacheManager.addOptimisticStory(currentUserId, moodStory);

      // 5. Guardar en Firestore
      await _storyRepository.create(moodStory);

      ReleaseLogger.log(
        'Mood story creada: $emoji - $text (visible para ${friendIds.length} amigos)',
        tag: 'StoryCreation',
      );

      return storyId;
    } catch (e) {
      _cacheManager.removeOptimisticStory(currentUserId, storyId);
      ReleaseLogger.error('Error creando mood story: $e', tag: 'StoryCreation');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MUSIC-ONLY STORY CREATION
  // ═══════════════════════════════════════════════════════════════

  /// Crear historia de solo-música (sin foto/video).
  ///
  /// La canción ya fue generada y persistida en Storage por la Cloud Function
  /// `generateStoryMusic`; acá solo creamos el doc de la historia vía el CF
  /// `createStory` (que respeta rate limiting y aprobación parental).
  Future<String> createMusicOnlyStory({
    required String musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
    String? caption,
  }) async {
    final currentUserId = _storyRepository.currentUserId;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    final tempStoryId = _generateTempStoryId();

    String failUserName = 'Usuario';
    String? failUserPhoto;
    try {
      final userInfo = await _contactRepository.getUserInfo(currentUserId);
      failUserName = userInfo?['name'] ?? 'Usuario';
      failUserPhoto = userInfo?['photoURL'];
      final now = DateTime.now();
      final expiresAt = now.add(Duration(hours: 24));

      // Historia optimista (aparece inmediatamente con un fondo de música).
      final optimisticStory = Story(
        id: tempStoryId,
        userId: currentUserId,
        userName: userInfo?['name'] ?? 'Usuario',
        userPhotoURL: userInfo?['photoURL'],
        mediaUrl: '',
        mediaType: 'music',
        caption: caption,
        createdAt: now,
        expiresAt: expiresAt,
        viewedBy: [],
        replies: [],
        status: StoryStatus.uploading,
        aiGenerated: true,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: (musicLyricsTimings ?? const [])
            .map((m) => LyricLine.fromMap(m))
            .toList(),
      );

      _cacheManager.addOptimisticStory(currentUserId, optimisticStory);

      final functions = FirebaseFunctions.instance;
      final createStoryFunction = functions.httpsCallable('createStory');

      final result = await createStoryFunction.call({
        'mediaType': 'music',
        'mediaUrl': '',
        'caption': caption,
        'musicUrl': musicUrl,
        'musicPrompt': musicPrompt,
        'musicLyrics': musicLyrics,
        'musicStartMs': musicStartMs,
        'musicClipMs': musicClipMs,
        if (musicTitle != null) 'musicTitle': musicTitle,
        if (musicDisplayMode != null) 'musicDisplayMode': musicDisplayMode,
        if (musicLyricsTimings != null) 'musicLyricsTimings': musicLyricsTimings,
        'tempStoryId': tempStoryId,
        'aiGenerated': true,
      });

      if (result.data['success'] != true) {
        throw Exception(
          result.data['message'] ?? 'Error creando historia en servidor',
        );
      }

      final serverStatus = result.data['status'];
      final storyStatus = serverStatus == 'approved'
          ? StoryStatus.approved
          : StoryStatus.pending;

      final realStory = optimisticStory.copyWith(status: storyStatus);
      _cacheManager.updateOptimisticStory(
        currentUserId,
        tempStoryId,
        realStory,
      );

      ReleaseLogger.log(
        'Música-only story creada: $tempStoryId (status: $serverStatus)',
        tag: 'StoryCreation',
      );

      return tempStoryId;
    } catch (e) {
      // Guardar como fallida para reintentar (la canción ya está en Storage).
      await _persistFailedStory(
        tempStoryId: tempStoryId,
        userId: currentUserId,
        userName: failUserName,
        userPhotoURL: failUserPhoto,
        mediaType: 'music',
        caption: caption,
        aiGenerated: true,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings,
        error: e.toString(),
      );
      ReleaseLogger.error('Error creando música story: $e', tag: 'StoryCreation');
      rethrow;
    }
  }
}
