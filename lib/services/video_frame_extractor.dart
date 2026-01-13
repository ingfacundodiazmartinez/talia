import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../utils/release_logger.dart';

/// Servicio para extraer frames de videos para moderación
///
/// Extrae frames a intervalos regulares del video para enviar a moderación.
/// Funciona tanto para videos grabados como videos de galería.
class VideoFrameExtractor {
  static final VideoFrameExtractor _instance = VideoFrameExtractor._internal();
  factory VideoFrameExtractor() => _instance;
  VideoFrameExtractor._internal();

  /// Número de frames a extraer por defecto
  static const int defaultFrameCount = 4;

  /// Calidad de los frames (0-100)
  static const int frameQuality = 50;

  /// Tamaño máximo del frame en pixels
  static const int maxFrameSize = 512;

  /// Extrae frames de un video local
  ///
  /// [videoPath] - Ruta al archivo de video
  /// [frameCount] - Número de frames a extraer (default: 4)
  /// [durationMs] - Duración del video en ms (opcional, se calcula si no se provee)
  ///
  /// Retorna lista de frames como base64 strings
  Future<List<String>> extractFrames(
    String videoPath, {
    int frameCount = defaultFrameCount,
    int? durationMs,
  }) async {
    try {
      ReleaseLogger.log(
        '🎬 Extrayendo $frameCount frames de: $videoPath',
        tag: 'VideoFrameExtractor',
      );

      final file = File(videoPath);
      if (!await file.exists()) {
        ReleaseLogger.error(
          'Video no existe: $videoPath',
          tag: 'VideoFrameExtractor',
        );
        return [];
      }

      // Si no tenemos duración, extraer frames en posiciones fijas
      // Posiciones: 10%, 30%, 50%, 70% del video
      final positions = _calculatePositions(frameCount, durationMs);

      final List<String> frames = [];

      for (int i = 0; i < positions.length; i++) {
        try {
          final Uint8List? frameData = await VideoThumbnail.thumbnailData(
            video: videoPath,
            imageFormat: ImageFormat.JPEG,
            timeMs: positions[i],
            quality: frameQuality,
            maxWidth: maxFrameSize,
            maxHeight: maxFrameSize,
          );

          if (frameData != null && frameData.isNotEmpty) {
            final base64Frame = base64Encode(frameData);
            frames.add(base64Frame);
            ReleaseLogger.log(
              '🎬 Frame ${i + 1}/${positions.length} extraído (${frameData.length} bytes)',
              tag: 'VideoFrameExtractor',
            );
          }
        } catch (e) {
          ReleaseLogger.error(
            'Error extrayendo frame ${i + 1}: $e',
            tag: 'VideoFrameExtractor',
          );
          // Continuar con los demás frames
        }
      }

      ReleaseLogger.log(
        '🎬 Extracción completada: ${frames.length}/$frameCount frames',
        tag: 'VideoFrameExtractor',
      );

      return frames;
    } catch (e) {
      ReleaseLogger.error(
        'Error en extracción de frames: $e',
        tag: 'VideoFrameExtractor',
      );
      return [];
    }
  }

  /// Calcula las posiciones de los frames en milisegundos
  List<int> _calculatePositions(int frameCount, int? durationMs) {
    if (durationMs != null && durationMs > 0) {
      // Distribuir frames uniformemente (evitando el inicio y final)
      final List<int> positions = [];
      final step = durationMs / (frameCount + 1);
      for (int i = 1; i <= frameCount; i++) {
        positions.add((step * i).round());
      }
      return positions;
    }

    // Sin duración conocida, usar posiciones fijas en segundos
    // Asumimos un video de ~30 segundos
    switch (frameCount) {
      case 1:
        return [3000]; // 3s
      case 2:
        return [2000, 8000]; // 2s, 8s
      case 3:
        return [2000, 6000, 12000]; // 2s, 6s, 12s
      case 4:
        return [2000, 6000, 12000, 20000]; // 2s, 6s, 12s, 20s
      case 5:
        return [2000, 5000, 10000, 15000, 22000];
      default:
        // Generar posiciones cada 5 segundos
        return List.generate(frameCount, (i) => (i + 1) * 5000);
    }
  }

  /// Extrae un solo frame (thumbnail) del video
  ///
  /// Útil para previews o cuando solo se necesita un frame
  Future<String?> extractThumbnail(String videoPath, {int timeMs = 1000}) async {
    try {
      final Uint8List? frameData = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        timeMs: timeMs,
        quality: frameQuality,
        maxWidth: maxFrameSize,
        maxHeight: maxFrameSize,
      );

      if (frameData != null && frameData.isNotEmpty) {
        return base64Encode(frameData);
      }
      return null;
    } catch (e) {
      ReleaseLogger.error(
        'Error extrayendo thumbnail: $e',
        tag: 'VideoFrameExtractor',
      );
      return null;
    }
  }
}
