import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';

/// Tipos de multimedia soportados
enum MediaType {
  image,
  audio,
  video,
}

/// Resultado de la moderación de multimedia
class MultimediaModerationResult {
  final bool flagged;
  final String severity;
  final String reason;
  final List<FlaggedCategory> categories;
  final String? error;
  final String? transcription; // Para audios: texto transcrito
  final MediaType? mediaType;

  MultimediaModerationResult({
    required this.flagged,
    required this.severity,
    required this.reason,
    this.categories = const [],
    this.error,
    this.transcription,
    this.mediaType,
  });

  factory MultimediaModerationResult.fromMap(Map<String, dynamic> data) {
    final categoriesList = (data['categories'] as List<dynamic>?)
        ?.map((c) => FlaggedCategory.fromMap(c as Map<String, dynamic>))
        .toList() ?? [];

    MediaType? mediaType;
    final typeStr = data['mediaType'] as String?;
    if (typeStr == 'image') mediaType = MediaType.image;
    else if (typeStr == 'audio') mediaType = MediaType.audio;
    else if (typeStr == 'video') mediaType = MediaType.video;

    return MultimediaModerationResult(
      flagged: data['flagged'] as bool? ?? false,
      severity: data['severity'] as String? ?? 'none',
      reason: data['reason'] as String? ?? '',
      categories: categoriesList,
      error: data['error'] as String?,
      transcription: data['transcription'] as String?,
      mediaType: mediaType,
    );
  }

  /// Crea un resultado aprobado por defecto (para errores o cuando no hay moderación)
  factory MultimediaModerationResult.approved() {
    return MultimediaModerationResult(
      flagged: false,
      severity: 'none',
      reason: '',
    );
  }
}

/// Categoría flaggeada por la moderación
class FlaggedCategory {
  final String category;
  final double score;

  FlaggedCategory({
    required this.category,
    required this.score,
  });

  factory FlaggedCategory.fromMap(Map<String, dynamic> data) {
    return FlaggedCategory(
      category: data['category'] as String? ?? '',
      score: (data['score'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Estado de moderación multimedia para un chat/grupo
class MultimediaModerationStatus {
  final bool isPremiumPlus;
  final String tier;
  final bool moderationEnabled;
  final bool multimediaModerationEnabled;
  final bool canUseMultimediaModeration;

  MultimediaModerationStatus({
    required this.isPremiumPlus,
    required this.tier,
    required this.moderationEnabled,
    required this.multimediaModerationEnabled,
    required this.canUseMultimediaModeration,
  });

  factory MultimediaModerationStatus.fromMap(Map<String, dynamic> data) {
    return MultimediaModerationStatus(
      isPremiumPlus: data['isPremiumPlus'] as bool? ?? false,
      tier: data['tier'] as String? ?? 'free',
      moderationEnabled: data['moderationEnabled'] as bool? ?? false,
      multimediaModerationEnabled: data['multimediaModerationEnabled'] as bool? ?? false,
      canUseMultimediaModeration: data['canUseMultimediaModeration'] as bool? ?? false,
    );
  }

  /// Estado por defecto (sin moderación)
  factory MultimediaModerationStatus.disabled() {
    return MultimediaModerationStatus(
      isPremiumPlus: false,
      tier: 'free',
      moderationEnabled: false,
      multimediaModerationEnabled: false,
      canUseMultimediaModeration: false,
    );
  }
}

/// Servicio para moderación de multimedia usando OpenAI
///
/// Este servicio permite moderar imágenes antes de enviarlas,
/// detectando contenido inapropiado como:
/// - Contenido sexual
/// - Violencia
/// - Autolesión
/// - Acoso y odio (cuando se incluye texto extraído por OCR)
///
/// IMPORTANTE: Solo disponible para usuarios Premium+
class MultimediaModerationService {
  static final MultimediaModerationService _instance = MultimediaModerationService._internal();
  factory MultimediaModerationService() => _instance;
  MultimediaModerationService._internal();

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Modera una imagen usando OpenAI omni-moderation-latest
  ///
  /// [imageUrl] - URL pública de la imagen (debe ser accesible por OpenAI)
  /// [extractedText] - Texto extraído de la imagen por OCR (opcional)
  /// [chatId] - ID del chat para logging (opcional)
  ///
  /// Returns [MultimediaModerationResult] con el resultado de la moderación
  ///
  /// Throws [FirebaseFunctionsException] si:
  /// - El usuario no está autenticado
  /// - El usuario no tiene Premium+
  /// - Se alcanzó el rate limit
  Future<MultimediaModerationResult> moderateImage({
    required String imageUrl,
    String? extractedText,
    String? chatId,
  }) async {
    try {
      ReleaseLogger.log(
        '[MultimediaModeration] Iniciando moderación de imagen',
        tag: 'MultimediaModeration',
      );

      final callable = _functions.httpsCallable('moderateImageWithOpenAI');
      final result = await callable.call({
        'imageUrl': imageUrl,
        'extractedText': extractedText,
        'chatId': chatId,
      });

      final data = result.data as Map<String, dynamic>;
      final moderationResult = MultimediaModerationResult.fromMap(data);

      ReleaseLogger.log(
        '[MultimediaModeration] Resultado: flagged=${moderationResult.flagged}, severity=${moderationResult.severity}',
        tag: 'MultimediaModeration',
      );

      return moderationResult;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error imagen: ${e.code} - ${e.message}',
        tag: 'MultimediaModeration',
      );

      // Re-lanzar errores específicos que el UI debe manejar
      if (e.code == 'permission-denied' ||
          e.code == 'resource-exhausted' ||
          e.code == 'unauthenticated') {
        rethrow;
      }

      // Para otros errores, retornar aprobado para no bloquear
      return MultimediaModerationResult.approved();
    } catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error inesperado imagen: $e',
        tag: 'MultimediaModeration',
      );
      // En caso de error, aprobar para no bloquear la comunicación
      return MultimediaModerationResult.approved();
    }
  }

  /// Modera un audio usando Whisper (transcripción) + Gemini (análisis)
  ///
  /// [audioUrl] - URL pública del audio
  /// [chatId] - ID del chat para logging (opcional)
  /// [moderationLevel] - Nivel de moderación: 'high', 'medium', 'low'
  ///
  /// Returns [MultimediaModerationResult] con el resultado de la moderación
  /// Incluye [transcription] con el texto transcrito del audio
  Future<MultimediaModerationResult> moderateAudio({
    required String audioUrl,
    String? chatId,
    String moderationLevel = 'high',
  }) async {
    try {
      ReleaseLogger.log(
        '[MultimediaModeration] Iniciando moderación de audio',
        tag: 'MultimediaModeration',
      );

      final callable = _functions.httpsCallable(
        'moderateAudioWithWhisper',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
      );
      final result = await callable.call({
        'audioUrl': audioUrl,
        'chatId': chatId,
        'moderationLevel': moderationLevel,
      });

      final data = result.data as Map<String, dynamic>;
      final moderationResult = MultimediaModerationResult.fromMap(data);

      ReleaseLogger.log(
        '[MultimediaModeration] Resultado audio: flagged=${moderationResult.flagged}, severity=${moderationResult.severity}',
        tag: 'MultimediaModeration',
      );

      if (moderationResult.transcription != null) {
        ReleaseLogger.log(
          '[MultimediaModeration] Transcripción: ${moderationResult.transcription!.substring(0, moderationResult.transcription!.length.clamp(0, 50))}...',
          tag: 'MultimediaModeration',
        );
      }

      return moderationResult;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error audio: ${e.code} - ${e.message}',
        tag: 'MultimediaModeration',
      );

      if (e.code == 'permission-denied' ||
          e.code == 'resource-exhausted' ||
          e.code == 'unauthenticated') {
        rethrow;
      }

      return MultimediaModerationResult.approved();
    } catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error inesperado audio: $e',
        tag: 'MultimediaModeration',
      );
      return MultimediaModerationResult.approved();
    }
  }

  /// Función unificada para moderar cualquier tipo de multimedia
  ///
  /// Detecta automáticamente el tipo de contenido y aplica la moderación apropiada:
  /// - Imágenes: OpenAI omni-moderation-latest
  /// - Audios: Whisper + Gemini
  /// - Videos: No soportado aún
  ///
  /// [mediaUrl] - URL del multimedia
  /// [mediaType] - Tipo de multimedia
  /// [extractedText] - Texto extraído (para imágenes con OCR)
  /// [chatId] - ID del chat
  /// [moderationLevel] - Nivel de moderación
  Future<MultimediaModerationResult> moderateMultimedia({
    required String mediaUrl,
    required MediaType mediaType,
    String? extractedText,
    String? chatId,
    String moderationLevel = 'high',
  }) async {
    try {
      ReleaseLogger.log(
        '[MultimediaModeration] Moderando ${mediaType.name}',
        tag: 'MultimediaModeration',
      );

      final callable = _functions.httpsCallable(
        'moderateMultimedia',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
      );
      final result = await callable.call({
        'mediaUrl': mediaUrl,
        'mediaType': mediaType.name,
        'extractedText': extractedText,
        'chatId': chatId,
        'moderationLevel': moderationLevel,
      });

      final data = result.data as Map<String, dynamic>;
      return MultimediaModerationResult.fromMap(data);
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error unificado: ${e.code} - ${e.message}',
        tag: 'MultimediaModeration',
      );

      if (e.code == 'permission-denied' ||
          e.code == 'resource-exhausted' ||
          e.code == 'unauthenticated') {
        rethrow;
      }

      return MultimediaModerationResult.approved();
    } catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error inesperado unificado: $e',
        tag: 'MultimediaModeration',
      );
      return MultimediaModerationResult.approved();
    }
  }

  /// Verifica el estado de moderación multimedia para un chat/grupo
  ///
  /// [chatId] - ID del chat o grupo
  ///
  /// Returns [MultimediaModerationStatus] con el estado actual
  Future<MultimediaModerationStatus> checkModerationStatus(String chatId) async {
    try {
      final callable = _functions.httpsCallable('checkMultimediaModerationStatus');
      final result = await callable.call({'chatId': chatId});

      final data = result.data as Map<String, dynamic>;
      return MultimediaModerationStatus.fromMap(data);
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error verificando estado: ${e.code} - ${e.message}',
        tag: 'MultimediaModeration',
      );
      return MultimediaModerationStatus.disabled();
    } catch (e) {
      ReleaseLogger.error(
        '[MultimediaModeration] Error inesperado verificando estado: $e',
        tag: 'MultimediaModeration',
      );
      return MultimediaModerationStatus.disabled();
    }
  }

  /// Verifica si el usuario actual puede usar moderación multimedia
  /// (requiere Premium+)
  Future<bool> canUseMultimediaModeration() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    try {
      // Usar checkModerationStatus con un chatId dummy solo para verificar Premium+
      final callable = _functions.httpsCallable('checkMultimediaModerationStatus');
      final result = await callable.call({'chatId': 'check_premium'});
      final data = result.data as Map<String, dynamic>;
      return data['isPremiumPlus'] as bool? ?? false;
    } catch (e) {
      return false;
    }
  }
}
