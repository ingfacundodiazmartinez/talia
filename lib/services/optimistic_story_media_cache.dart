/// Cache en memoria del path local de stories en proceso de upload.
///
/// **Por qué existe:** cuando se crea un story optimistic (status `uploading`),
/// el campo `localMediaPath` está en el modelo Dart pero NO se persiste en
/// Firestore. Cuando el stream re-emite desde Firestore, el path local se
/// pierde y el viewer intenta cargar `mediaUrl: ''` → "Error cargando imagen".
///
/// Este cache vive en memoria como singleton y se setea desde el creation
/// service en el momento de crear el optimistic. El viewer consulta este
/// cache primero antes de intentar la URL remota.
///
/// Lifecycle:
///   1. `story_creation_service._createOptimisticStory()` → `set(storyId, path)`
///   2. Mientras dura el upload → viewer renderiza desde `Image.file(path)`
///   3. Upload completa → backend persiste mediaUrl real, `clear(storyId)`
///   4. Upload falla → `clear(storyId)` (el viewer cae a errorWidget)
class OptimisticStoryMediaCache {
  static final OptimisticStoryMediaCache _instance =
      OptimisticStoryMediaCache._internal();

  factory OptimisticStoryMediaCache() => _instance;

  OptimisticStoryMediaCache._internal();

  final Map<String, String> _pathByStoryId = {};

  /// Registrar el path local de un story en upload.
  void set(String storyId, String localPath) {
    _pathByStoryId[storyId] = localPath;
  }

  /// Recuperar el path local si está disponible, sino null.
  String? get(String storyId) => _pathByStoryId[storyId];

  /// Limpiar la entrada cuando termina el upload (éxito o fallo).
  void clear(String storyId) {
    _pathByStoryId.remove(storyId);
  }

  /// Limpiar todo (útil en logout).
  void clearAll() {
    _pathByStoryId.clear();
  }
}
