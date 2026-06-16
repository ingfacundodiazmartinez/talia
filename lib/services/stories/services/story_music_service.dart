import 'package:cloud_functions/cloud_functions.dart';

import '../../../utils/release_logger.dart';

/// Timing de una "palabra" (puede incluir tags y saltos de línea) en segundos.
class WordTiming {
  final double start;
  final double end;
  final String word;
  WordTiming({required this.start, required this.end, required this.word});
}

/// Resultado de pedir el alignment (timing) de una canción.
class AlignmentResult {
  final String status; // "SUCCESS", "TASK_SENT", "PENDING", ...
  final List<WordTiming>? words;
  AlignmentResult({required this.status, this.words});
  bool get isReady => status.toUpperCase() == 'SUCCESS' && words != null && words!.isNotEmpty;
}

/// Resultado de generar una canción con IA.
class StoryMusicResult {
  final String audioUrl;
  final String prompt;
  final bool instrumental;
  final String? lyrics; // letra COMPLETA (se conserva para re-editar el crop)
  final String? suggestedTitle; // título sugerido por Sonauto (default editable)
  final String? taskId; // para pedir el alignment (timing) por separado
  final int? creditsSpent;
  final int? newBalance;

  // Recorte elegido en la pantalla de crop (null = canción completa).
  int? startMs;
  int? clipMs;
  // Letra del fragmento elegido = lo que se muestra en la historia (null = sin letra).
  String? fragmentLyrics;
  // Qué mostrar en la historia: 'title' | 'lyrics'. Lo elige el usuario en el crop.
  String? displayMode;
  // Título final a mostrar (editable por el usuario en el crop).
  String? title;
  // Líneas de la letra con timing (ms abs) para el karaoke. Mapas {text,startMs,endMs}.
  List<Map<String, dynamic>>? lineTimings;

  StoryMusicResult({
    required this.audioUrl,
    required this.prompt,
    this.instrumental = false,
    this.lyrics,
    this.suggestedTitle,
    this.taskId,
    this.creditsSpent,
    this.newBalance,
    this.startMs,
    this.clipMs,
    this.fragmentLyrics,
    this.displayMode,
    this.title,
    this.lineTimings,
  });

  /// Título por defecto editable: el sugerido por Sonauto, o uno derivado del
  /// prompt si Sonauto no devolvió título.
  String get defaultTitle {
    final s = suggestedTitle;
    if (s != null && s.trim().isNotEmpty) return s.trim();
    final words = prompt.trim().split(RegExp(r'\s+')).take(6).join(' ');
    if (words.isEmpty) return 'Mi canción';
    final t = words.length > 40 ? words.substring(0, 40).trim() : words;
    return t[0].toUpperCase() + t.substring(1);
  }
}

/// Error de generación con mensaje apto para mostrar al usuario.
class StoryMusicException implements Exception {
  final String message;
  StoryMusicException(this.message);
  @override
  String toString() => message;
}

/// Servicio atómico para generar música con IA (Cloud Function `generateStoryMusic`).
///
/// La generación puede tardar varios minutos, por eso el callable usa un timeout
/// extendido (la función server-side hace polling contra Sonauto hasta 4 min).
class StoryMusicService {
  final FirebaseFunctions _functions;

  StoryMusicService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  /// Genera una canción a partir de un prompt (y opcionalmente letra).
  /// Lanza [StoryMusicException] con un mensaje legible si falla.
  Future<StoryMusicResult> generate({
    required String prompt,
    String? lyrics,
    bool instrumental = false,
  }) async {
    final cleanPrompt = prompt.trim();
    if (cleanPrompt.length < 3) {
      throw StoryMusicException('Describí la canción que querés crear');
    }

    try {
      final callable = _functions.httpsCallable(
        'generateStoryMusic',
        options: HttpsCallableOptions(timeout: const Duration(minutes: 5)),
      );

      final result = await callable.call(<String, dynamic>{
        'prompt': cleanPrompt,
        if (lyrics != null && lyrics.trim().isNotEmpty) 'lyrics': lyrics.trim(),
        'instrumental': instrumental,
      });

      final map = Map<String, dynamic>.from(result.data as Map);
      final audioUrl = (map['audioUrl'] ?? '').toString();
      if (audioUrl.isEmpty) {
        throw StoryMusicException('No se pudo generar la canción. Intentá de nuevo.');
      }

      final rawLyrics = map['lyrics']?.toString();
      final rawTitle = map['title']?.toString();
      return StoryMusicResult(
        audioUrl: audioUrl,
        prompt: (map['prompt'] ?? cleanPrompt).toString(),
        instrumental: map['instrumental'] == true,
        lyrics: (rawLyrics != null && rawLyrics.trim().isNotEmpty) ? rawLyrics : null,
        suggestedTitle: (rawTitle != null && rawTitle.trim().isNotEmpty) ? rawTitle.trim() : null,
        taskId: map['taskId']?.toString(),
        creditsSpent: (map['creditsSpent'] as num?)?.toInt(),
        newBalance: (map['newBalance'] as num?)?.toInt(),
      );
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.warning(
        'generateStoryMusic falló: ${e.code} ${e.message}',
        tag: 'StoryMusicService',
      );
      // El backend ya devuelve mensajes amigables en e.message.
      if (e.code == 'failed-precondition') {
        if ((e.message ?? '').contains('PREMIUM_REQUIRED')) {
          throw StoryMusicException('La creación de canciones es solo para Premium.');
        }
        throw StoryMusicException(
          e.message ?? 'No se pudo crear la canción.',
        );
      }
      if (e.code == 'unauthenticated') {
        throw StoryMusicException('Sesión expirada. Volvé a iniciar sesión.');
      }
      throw StoryMusicException(
        e.message ?? 'No se pudo generar la canción. Intentá de nuevo.',
      );
    } catch (e) {
      ReleaseLogger.error('generateStoryMusic error: $e', tag: 'StoryMusicService');
      throw StoryMusicException('No se pudo generar la canción. Intentá de nuevo.');
    }
  }

  /// Pide el timing (alignment) de una canción. El alignment es asíncrono en
  /// Sonauto; devolvé `isReady == false` hasta que esté listo. Null si falló.
  Future<AlignmentResult?> fetchAlignment(String taskId) async {
    try {
      final callable = _functions.httpsCallable(
        'getMusicAlignment',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{'taskId': taskId});
      final map = Map<String, dynamic>.from(result.data as Map);
      final status = (map['alignmentStatus'] ?? 'UNKNOWN').toString();
      List<WordTiming>? words;
      final raw = map['words'];
      if (raw is List) {
        words = raw.whereType<Map>().map((w) {
          return WordTiming(
            start: (w['start'] as num?)?.toDouble() ?? 0,
            end: (w['end'] as num?)?.toDouble() ?? 0,
            word: (w['word'] ?? '').toString(),
          );
        }).toList();
        if (words.isEmpty) words = null;
      }
      return AlignmentResult(status: status, words: words);
    } catch (e) {
      ReleaseLogger.warning('fetchAlignment falló: $e', tag: 'StoryMusicService');
      return null;
    }
  }
}
