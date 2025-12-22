import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';
import '../utils/release_logger.dart';

/// Servicio para cachear videos de red
///
/// Usa flutter_cache_manager para descargar y cachear videos,
/// permitiendo reproducción más rápida en accesos posteriores.
class VideoCacheService {
  static final VideoCacheService _instance = VideoCacheService._internal();
  factory VideoCacheService() => _instance;
  VideoCacheService._internal();

  // Cache manager con configuración específica para videos
  static final _videoCacheManager = CacheManager(
    Config(
      'video_cache',
      stalePeriod: const Duration(days: 7), // Mantener videos 7 días
      maxNrOfCacheObjects: 50, // Máximo 50 videos en cache
    ),
  );

  /// Obtener VideoPlayerController con cache
  ///
  /// Si el video ya está en cache, lo reproduce desde el archivo local.
  /// Si no, lo descarga primero y luego lo reproduce.
  Future<VideoPlayerController> getController(String videoUrl) async {
    try {
      // Intentar obtener del cache o descargar
      final file = await _videoCacheManager.getSingleFile(videoUrl);

      ReleaseLogger.log(
        '🎬 Video desde cache: ${file.path}',
        tag: 'VideoCache',
      );

      return VideoPlayerController.file(file);
    } catch (e) {
      ReleaseLogger.error(
        '⚠️ Error cacheando video, usando network: $e',
        tag: 'VideoCache',
      );
      // Fallback a network si falla el cache
      return VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    }
  }

  /// Precargar video en cache sin reproducir
  Future<File?> preloadVideo(String videoUrl) async {
    try {
      final file = await _videoCacheManager.getSingleFile(videoUrl);
      ReleaseLogger.log(
        '✅ Video precargado: ${videoUrl.substring(0, 50)}...',
        tag: 'VideoCache',
      );
      return file;
    } catch (e) {
      ReleaseLogger.error(
        '❌ Error precargando video: $e',
        tag: 'VideoCache',
      );
      return null;
    }
  }

  /// Verificar si un video está en cache
  Future<bool> isVideoCached(String videoUrl) async {
    try {
      final fileInfo = await _videoCacheManager.getFileFromCache(videoUrl);
      return fileInfo != null;
    } catch (e) {
      return false;
    }
  }

  /// Limpiar cache de videos
  Future<void> clearCache() async {
    await _videoCacheManager.emptyCache();
    ReleaseLogger.log('🧹 Cache de videos limpiado', tag: 'VideoCache');
  }
}
