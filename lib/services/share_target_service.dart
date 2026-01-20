import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../models/shared_content.dart';
import '../utils/release_logger.dart';
import 'share_extension_cache_service.dart';

/// Servicio para manejar contenido compartido desde otras apps (Share Target)
///
/// Soporta:
/// - Android: Intent filters (ACTION_SEND, ACTION_SEND_MULTIPLE)
/// - iOS: Share Extension via App Group
///
/// Responsabilidades:
/// - Escuchar incoming shares
/// - Parsear y validar contenido
/// - Copiar media a ubicación accesible
/// - Notificar cuando llega contenido nuevo
class ShareTargetService {
  static final ShareTargetService _instance = ShareTargetService._internal();
  factory ShareTargetService() => _instance;
  ShareTargetService._internal();

  StreamSubscription<List<SharedMediaFile>>? _mediaStreamSubscription;

  /// Stream de contenido compartido entrante
  final _sharedContentController =
      StreamController<List<SharedContent>>.broadcast();
  Stream<List<SharedContent>> get sharedContentStream =>
      _sharedContentController.stream;

  /// Contenido pendiente actual
  List<SharedContent>? _pendingContent;
  List<SharedContent>? get pendingContent => _pendingContent;

  /// Indica si hay contenido pendiente
  bool get hasPendingContent =>
      _pendingContent != null && _pendingContent!.isNotEmpty;

  /// Callback cuando se recibe share
  void Function(List<SharedContent>)? onShareReceived;

  /// ✅ Timer para acumular shares que llegan en rápida sucesión
  /// Algunas apps envían múltiples fotos como intents separados
  Timer? _accumulationTimer;
  static const _accumulationWindow = Duration(milliseconds: 500);

  /// Límite máximo de items (para evitar abusos)
  static const int maxShareItems = 10;

  // ═══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar el servicio de share target
  Future<void> initialize() async {
    ReleaseLogger.log(
      '📥 [ShareTarget] Initializing service...',
      tag: 'ShareTarget',
    );

    // Verificar si hay share inicial (cuando la app se abrió desde share)
    await _checkInitialShare();

    // En iOS, verificar App Group para shares pendientes
    if (Platform.isIOS) {
      await _checkIOSAppGroupShare();
    }

    // Escuchar shares mientras la app está corriendo
    _mediaStreamSubscription =
        ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleIncomingMediaShare,
      onError: (error) {
        ReleaseLogger.error(
          '📥 [ShareTarget] Media stream error: $error',
          tag: 'ShareTarget',
        );
      },
    );

    ReleaseLogger.log(
      '📥 [ShareTarget] Service initialized',
      tag: 'ShareTarget',
    );
  }

  /// Verificar si hay share recibido cuando la app fue lanzada desde share
  Future<void> _checkInitialShare() async {
    try {
      final initialMedia =
          await ReceiveSharingIntent.instance.getInitialMedia();
      if (initialMedia.isNotEmpty) {
        ReleaseLogger.log(
          '📥 [ShareTarget] Found initial share: ${initialMedia.length} items',
          tag: 'ShareTarget',
        );
        _handleIncomingMediaShare(initialMedia);
      }
    } catch (e) {
      ReleaseLogger.error(
        '📥 [ShareTarget] Error checking initial share: $e',
        tag: 'ShareTarget',
      );
    }
  }

  /// Verificar iOS App Group UserDefaults para shares pendientes
  /// Usa ShareExtensionCacheService para leer desde el App Group real
  Future<void> _checkIOSAppGroupShare() async {
    try {
      final cacheService = ShareExtensionCacheService();
      final pendingShare = await cacheService.getPendingShare();

      if (pendingShare == null || pendingShare.items.isEmpty) {
        ReleaseLogger.log(
          '📥 [ShareTarget] No pending iOS Share Extension data',
          tag: 'ShareTarget',
        );
        return;
      }

      // Verificar si el share es reciente (últimos 5 minutos)
      final shareTime = DateTime.fromMillisecondsSinceEpoch(
        (pendingShare.timestamp * 1000).toInt(),
      );
      final now = DateTime.now();

      if (now.difference(shareTime).inMinutes >= 5) {
        ReleaseLogger.log(
          '📥 [ShareTarget] iOS Share too old (${now.difference(shareTime).inMinutes} min), ignoring',
          tag: 'ShareTarget',
        );
        await cacheService.clearPendingShare();
        return;
      }

      ReleaseLogger.log(
        '📥 [ShareTarget] Found pending iOS Share: ${pendingShare.items.length} items for ${pendingShare.chatIds.length} chats',
        tag: 'ShareTarget',
      );

      // Convertir PendingShareItem a SharedContent
      final contents = <SharedContent>[];
      for (final item in pendingShare.items) {
        SharedContentType type;
        switch (item.type) {
          case 'image':
            type = SharedContentType.image;
            break;
          case 'video':
            type = SharedContentType.video;
            break;
          case 'url':
            type = SharedContentType.url;
            break;
          case 'text':
          default:
            type = SharedContentType.text;
            break;
        }

        contents.add(SharedContent(
          id: '${DateTime.now().millisecondsSinceEpoch}_${contents.length}',
          type: type,
          mediaPath: item.path,
          text: item.text,
          url: item.type == 'url' ? item.text : null,
        ));
      }

      if (contents.isNotEmpty) {
        // Guardar los chat IDs de destino para usar en el controller
        _pendingDestinationChatIds = pendingShare.chatIds;
        _handleParsedContent(contents);
      }

      // Limpiar datos del App Group
      await cacheService.clearPendingShare();
    } catch (e) {
      ReleaseLogger.error(
        '📥 [ShareTarget] Error checking iOS App Group: $e',
        tag: 'ShareTarget',
      );
    }
  }

  /// Chat IDs seleccionados desde la iOS Share Extension
  List<String>? _pendingDestinationChatIds;
  List<String>? get pendingDestinationChatIds => _pendingDestinationChatIds;

  // ═══════════════════════════════════════════════════════════════
  // SHARE HANDLING
  // ═══════════════════════════════════════════════════════════════

  /// Manejar share entrante de media
  void _handleIncomingMediaShare(List<SharedMediaFile> mediaFiles) {
    if (mediaFiles.isEmpty) return;

    ReleaseLogger.log(
      '📥 [ShareTarget] Received share: ${mediaFiles.length} items',
      tag: 'ShareTarget',
    );

    final contents = <SharedContent>[];

    for (final media in mediaFiles) {
      final path = media.path;
      final type = _determineContentType(path, media.type);

      // For text and URL types, path contains the actual text/URL
      final isTextOrUrl =
          media.type == SharedMediaType.text || media.type == SharedMediaType.url;

      contents.add(SharedContent(
        id: '${DateTime.now().millisecondsSinceEpoch}_${contents.length}',
        type: type,
        mediaPath: isTextOrUrl ? null : path,
        text: media.type == SharedMediaType.text ? path : null,
        url: media.type == SharedMediaType.url ? path : null,
        mimeType: media.mimeType,
      ));
    }

    if (contents.isNotEmpty) {
      _handleParsedContent(contents);
    }
  }

  /// Procesar contenido parseado
  /// ✅ Acumula items que llegan en rápida sucesión (dentro de 500ms)
  /// para manejar apps que envían múltiples fotos como intents separados
  void _handleParsedContent(List<SharedContent> contents) {
    // Cancelar timer anterior si existe
    _accumulationTimer?.cancel();

    // Acumular con contenido existente si es reciente
    if (_pendingContent != null && _pendingContent!.isNotEmpty) {
      // Agregar nuevos items al contenido existente
      final combined = [..._pendingContent!, ...contents];

      // Limitar a maxShareItems para evitar abusos
      if (combined.length > maxShareItems) {
        _pendingContent = combined.take(maxShareItems).toList();
        ReleaseLogger.log(
          '📥 [ShareTarget] Limitado a $maxShareItems items (recibidos: ${combined.length})',
          tag: 'ShareTarget',
        );
      } else {
        _pendingContent = combined;
      }
    } else {
      // Primera vez - inicializar con estos items
      _pendingContent = contents.length > maxShareItems
          ? contents.take(maxShareItems).toList()
          : contents;
    }

    ReleaseLogger.log(
      '📥 [ShareTarget] Accumulated ${_pendingContent!.length} items (new batch: ${contents.length})',
      tag: 'ShareTarget',
    );

    // Esperar un poco por si llegan más items
    _accumulationTimer = Timer(_accumulationWindow, () {
      // Notificar una vez que no lleguen más items
      if (_pendingContent != null && _pendingContent!.isNotEmpty) {
        ReleaseLogger.log(
          '📥 [ShareTarget] Final count: ${_pendingContent!.length} items ready',
          tag: 'ShareTarget',
        );
        _sharedContentController.add(_pendingContent!);
        onShareReceived?.call(_pendingContent!);
      }
    });
  }

  /// Determinar tipo de contenido desde path y tipo de media
  SharedContentType _determineContentType(String path, SharedMediaType type) {
    switch (type) {
      case SharedMediaType.image:
        return SharedContentType.image;
      case SharedMediaType.video:
        return SharedContentType.video;
      case SharedMediaType.text:
        return SharedContentType.text;
      case SharedMediaType.url:
        return SharedContentType.url;
      case SharedMediaType.file:
        return SharedContentType.document;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CONTENT OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Copiar media compartido al directorio temporal de la app
  /// Retorna el nuevo path, o null si falló
  Future<String?> copyToTempDirectory(String sourcePath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        ReleaseLogger.error(
          '📥 [ShareTarget] Source file not found: $sourcePath',
          tag: 'ShareTarget',
        );
        return null;
      }

      final tempDir = await getTemporaryDirectory();
      final shareDir = Directory('${tempDir.path}/shared_media');
      if (!await shareDir.exists()) {
        await shareDir.create(recursive: true);
      }

      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${sourcePath.split('/').last}';
      final destPath = '${shareDir.path}/$fileName';

      await sourceFile.copy(destPath);
      ReleaseLogger.log(
        '📥 [ShareTarget] Copied to: $destPath',
        tag: 'ShareTarget',
      );

      return destPath;
    } catch (e) {
      ReleaseLogger.error(
        '📥 [ShareTarget] Error copying file: $e',
        tag: 'ShareTarget',
      );
      return null;
    }
  }

  /// Limpiar contenido pendiente después de procesarlo
  void clearPendingContent() {
    _accumulationTimer?.cancel();
    _accumulationTimer = null;
    _pendingContent = null;
    _pendingDestinationChatIds = null;
    ReceiveSharingIntent.instance.reset();
    ReleaseLogger.log(
      '📥 [ShareTarget] Cleared pending content',
      tag: 'ShareTarget',
    );
  }

  /// ✅ NEW: Forzar re-check de contenido pendiente
  /// Llamar cuando se muestra la pantalla de share para asegurar contenido fresco
  Future<void> refreshPendingContent() async {
    ReleaseLogger.log(
      '📥 [ShareTarget] Refreshing pending content...',
      tag: 'ShareTarget',
    );

    // Re-check initial share (receive_sharing_intent)
    await _checkInitialShare();

    // En iOS, re-check App Group
    if (Platform.isIOS) {
      await _checkIOSAppGroupShare();
    }

    ReleaseLogger.log(
      '📥 [ShareTarget] Refresh complete. Has content: $hasPendingContent',
      tag: 'ShareTarget',
    );
  }

  /// Validar archivo de media (tamaño, formato)
  Future<bool> validateMedia(String path, {int maxSizeMB = 50}) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;

      final size = await file.length();
      final maxBytes = maxSizeMB * 1024 * 1024;

      if (size > maxBytes) {
        ReleaseLogger.log(
          '📥 [ShareTarget] File too large: ${size / 1024 / 1024}MB',
          tag: 'ShareTarget',
        );
        return false;
      }

      return true;
    } catch (e) {
      ReleaseLogger.error(
        '📥 [ShareTarget] Validation error: $e',
        tag: 'ShareTarget',
      );
      return false;
    }
  }

  /// Obtener tamaño del archivo en formato legible
  Future<String?> getFileSizeFormatted(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final bytes = await file.length();
      if (bytes < 1024) {
        return '$bytes B';
      } else if (bytes < 1024 * 1024) {
        return '${(bytes / 1024).toStringAsFixed(1)} KB';
      } else {
        return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      }
    } catch (e) {
      return null;
    }
  }

  /// Limpiar archivos temporales antiguos (más de 24 horas)
  Future<void> cleanupOldTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final shareDir = Directory('${tempDir.path}/shared_media');

      if (!await shareDir.exists()) return;

      final now = DateTime.now();
      final files = await shareDir.list().toList();

      for (final entity in files) {
        if (entity is File) {
          final stat = await entity.stat();
          final age = now.difference(stat.modified);

          if (age.inHours > 24) {
            await entity.delete();
            ReleaseLogger.log(
              '📥 [ShareTarget] Cleaned old temp file: ${entity.path}',
              tag: 'ShareTarget',
            );
          }
        }
      }
    } catch (e) {
      ReleaseLogger.error(
        '📥 [ShareTarget] Error cleaning temp files: $e',
        tag: 'ShareTarget',
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Liberar recursos
  void dispose() {
    _accumulationTimer?.cancel();
    _accumulationTimer = null;
    _mediaStreamSubscription?.cancel();
    _mediaStreamSubscription = null;
    _sharedContentController.close();
    ReleaseLogger.log(
      '📥 [ShareTarget] Service disposed',
      tag: 'ShareTarget',
    );
  }
}
