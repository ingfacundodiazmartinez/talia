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

  /// Responder a historia
  ///
  /// 🔒 SEGURIDAD: SIEMPRE usa Cloud Function para:
  /// - Validar userId == auth.uid (previene spoofing)
  /// - Validar permisos de contacto
  /// - Aplicar rate limiting
  /// - Pasar por moderación automática
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
      final story = await _storyRepository.getById(storyId);
      if (story == null) throw Exception('Historia no encontrada');
      if (currentUserId == story.userId) throw Exception('No puedes responder tu propia historia');

      final replyMediaUrl = await _uploadMediaIfNeeded(replyMediaPath, currentUserId);
      final localId = const Uuid().v4();

      // 🔒 SIEMPRE usar Cloud Function (Firestore rules bloquean escritura directa)
      await _replyViaCloudFunction(storyId, replyText, replyMediaUrl, replyMediaType, localId);
    } catch (e) {
      ReleaseLogger.error('Error respondiendo historia: $e', tag: 'StoryReply');
      _handleReplyError(e);
    }
  }

  /// Upload media si es necesario
  Future<String?> _uploadMediaIfNeeded(String? mediaPath, String userId) async {
    if (mediaPath == null || _uploadManager == null) return null;
    return await _uploadManager.uploadStoryMedia(
      filePath: mediaPath,
      storyId: 'reply_${DateTime.now().millisecondsSinceEpoch}',
      userId: userId,
    );
  }

  /// Responder via Cloud Function (seguro y con moderación)
  /// La Cloud Function ya guarda el reply en el story document
  Future<void> _replyViaCloudFunction(String storyId, String replyText, String? mediaUrl, String? mediaType, String localId) async {
    ReleaseLogger.log('🔒 [StoryReply] Usando Cloud Function', tag: 'StoryReply');
    final result = await _functions.httpsCallable('replyToStory').call({
      'storyId': storyId,
      'replyText': replyText.trim(),
      'replyMediaUrl': mediaUrl,
      'replyMediaType': mediaType,
      'localId': localId,
    });
    if ((result.data as Map<String, dynamic>)['success'] != true) {
      throw Exception('Cloud Function falló');
    }
    ReleaseLogger.log('✅ [StoryReply] Respuesta enviada via Cloud Function', tag: 'StoryReply');
  }

  Never _handleReplyError(dynamic e) {
    if (e.toString().contains('permission-denied')) throw Exception('No tienes permisos para responder esta historia');
    if (e.toString().contains('not-found')) throw Exception('Historia no encontrada');
    if (e.toString().contains('invalid-argument')) throw Exception('Datos de respuesta inválidos');
    throw e;
  }

  // ═══════════════════════════════════════════════════════════════
  // STORY LIKES
  // ═══════════════════════════════════════════════════════════════

  /// Dar like a una historia
  /// Usa Cloud Function para:
  /// - Agregar userId a likedBy
  /// - Crear chat si no existe (padre-hijo puede no tener chat)
  /// - Enviar mensaje "❤️ Le gustó tu historia"
  Future<void> likeStory(String storyId) async {
    AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'likeStory'
    );

    try {
      ReleaseLogger.log('Llamando Cloud Function likeStory para historia $storyId', tag: 'StoryLike');

      final callable = _functions.httpsCallable('likeStory');
      final result = await callable.call({'storyId': storyId});

      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['success'] != true) {
        throw Exception(data['message'] ?? 'Error desconocido');
      }

      if (data['alreadyLiked'] == true) {
        ReleaseLogger.log('Usuario ya dio like a esta historia', tag: 'StoryLike');
      } else {
        ReleaseLogger.log('✅ Like agregado a historia $storyId via Cloud Function', tag: 'StoryLike');
      }

    } catch (e) {
      ReleaseLogger.error('Error dando like a historia: $e', tag: 'StoryLike');
      throw Exception('Error dando like a historia: $e');
    }
  }

  /// Quitar like de una historia
  /// Solo remueve userId de likedBy (no borra el mensaje del chat)
  Future<void> unlikeStory(String storyId) async {
    final currentUserId = AuthValidationHelper.ensureAuthenticated(
      _storyRepository,
      context: 'unlikeStory'
    );

    try {
      final story = await _storyRepository.getById(storyId);
      if (story == null) throw Exception('Historia no encontrada');

      // Verificar si tiene like
      if (!story.likedBy.contains(currentUserId)) {
        ReleaseLogger.log('Usuario no tiene like en esta historia', tag: 'StoryLike');
        return;
      }

      // Remover like en Firestore
      await _storyRepository.removeLike(storyId, currentUserId);
      ReleaseLogger.log('✅ Like removido de historia $storyId', tag: 'StoryLike');

    } catch (e) {
      ReleaseLogger.error('Error quitando like de historia: $e', tag: 'StoryLike');
      throw Exception('Error quitando like de historia: $e');
    }
  }
}