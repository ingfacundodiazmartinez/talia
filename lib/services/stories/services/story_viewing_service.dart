import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:uuid/uuid.dart';

import '../repositories/story_repository.dart';
import '../managers/story_upload_manager.dart';
import '../utils/auth_validation_helper.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado para visualización e interacción con historias
///
/// Responsabilidades:
/// - Marcar historias como vistas
/// - Responder a historias
/// - Gestionar interacciones de viewing
/// - Tracking de visualizaciones
class StoryViewingService {
  final StoryRepository _storyRepository;
  final StoryUploadManager? _uploadManager;
  final FirebaseFunctions _functions;

  StoryViewingService({
    required StoryRepository storyRepository,
    StoryUploadManager? uploadManager,
    FirebaseFunctions? functions,
  }) : _storyRepository = storyRepository,
       _uploadManager = uploadManager,
       _functions = functions ?? FirebaseFunctions.instance;

  // ═══════════════════════════════════════════════════════════════
  // VIEWING ACTIONS
  // ═══════════════════════════════════════════════════════════════

  /// Marcar historia como vista
  Future<void> markStoryAsViewed(String storyId) async {
    final currentUserId = AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'markStoryAsViewed'
    );

    try {
      await _storyRepository.markAsViewed(storyId, currentUserId);
    } catch (e) {
      ReleaseLogger.error('Error marcando historia como vista: $e', tag: 'StoryViewing');
      throw Exception('Error marcando historia como vista: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // STORY REPLIES
  // ═══════════════════════════════════════════════════════════════

  /// Responder a historia (REFACTORIZADO: Ahora usa Cloud Function)
  ///
  /// CAMBIOS:
  /// - ✅ Usa Cloud Function 'replyToStory' en lugar de escritura directa
  /// - ✅ Garantiza moderación automática via trigger 'moderateMessage'
  /// - ✅ Server-side validation y permisos
  /// - ✅ Mejor seguridad y consistencia
  Future<void> replyToStory({
    required String storyId,
    required String replyText,
    String? replyMediaPath,
    String? replyMediaType,
  }) async {
    final currentUserId = AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'replyToStory'
    );

    try {

      // 1. Upload media si es necesaria (antes de llamar Cloud Function)
      String? replyMediaUrl;
      if (replyMediaPath != null && _uploadManager != null) {
        replyMediaUrl = await _uploadManager.uploadStoryMedia(
          filePath: replyMediaPath,
          storyId: 'reply_${DateTime.now().millisecondsSinceEpoch}',
          userId: currentUserId,
        );
      }

      // 2. Generar localId para rastreo optimista
      final localId = const Uuid().v4();

      // 3. LLAMAR CLOUD FUNCTION SEGURA (reemplaza toda la lógica anterior)
      final result = await _functions.httpsCallable('replyToStory').call({
        'storyId': storyId,
        'replyText': replyText.trim(),
        'replyMediaUrl': replyMediaUrl,
        'replyMediaType': replyMediaType,
        'localId': localId, // Para rastreo optimista
      });

      final data = result.data as Map<String, dynamic>;

      if (data['success'] != true) {
        throw Exception('Cloud Function falló: ${data['message'] ?? 'Error desconocido'}');
      }

    } catch (e) {
      ReleaseLogger.error('Error en Cloud Function: $e', tag: 'StoryReply');

      // Preservar errores específicos de Cloud Functions
      if (e.toString().contains('permission-denied')) {
        throw Exception('No tienes permisos para responder esta historia');
      } else if (e.toString().contains('not-found')) {
        throw Exception('Historia no encontrada');
      } else if (e.toString().contains('invalid-argument')) {
        throw Exception('Datos de respuesta inválidos');
      } else {
        throw Exception('Error respondiendo a historia: $e');
      }
    }
  }
}