import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:video_compress/video_compress.dart';

/// Servicio para comprimir y validar archivos multimedia
///
/// Responsabilidades:
/// - Comprimir imágenes manteniendo calidad aceptable
/// - Validar tamaño de archivos (max 10MB)
/// - Comprimir videos (resize si es necesario)
class MediaCompressionService {
  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10 MB
  static const int targetImageWidth = 1920;
  static const int targetImageHeight = 1920;
  static const int imageQuality = 85;

  /// Valida que un archivo no exceda el tamaño máximo
  Future<bool> validateFileSize(File file) async {
    try {
      final fileSize = await file.length();
      return fileSize <= maxFileSizeBytes;
    } catch (e) {
      print('❌ Error validando tamaño: $e');
      return false;
    }
  }

  /// Obtiene el tamaño de un archivo en MB
  Future<double> getFileSizeMB(File file) async {
    try {
      final fileSize = await file.length();
      return fileSize / (1024 * 1024);
    } catch (e) {
      print('❌ Error obteniendo tamaño: $e');
      return 0;
    }
  }

  /// Comprime una imagen hasta que esté bajo el límite de tamaño
  ///
  /// Estrategia:
  /// 1. Redimensionar si es muy grande
  /// 2. Reducir calidad progresivamente
  /// 3. Si aún es muy grande, seguir reduciendo dimensiones
  Future<File?> compressImage(File imageFile) async {
    try {
      // Leer imagen original
      final bytes = await imageFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);

      if (image == null) {
        print('❌ No se pudo decodificar la imagen');
        return null;
      }

      print('📸 Imagen original: ${image.width}x${image.height}');

      // 1. Redimensionar si excede las dimensiones objetivo
      if (image.width > targetImageWidth || image.height > targetImageHeight) {
        image = img.copyResize(
          image,
          width: image.width > image.height ? targetImageWidth : null,
          height: image.height >= image.width ? targetImageHeight : null,
        );
        print('📏 Redimensionada a: ${image.width}x${image.height}');
      }

      // 2. Comprimir con calidad inicial
      int quality = imageQuality;
      Uint8List? compressedBytes;
      File? compressedFile;

      while (quality >= 20) {
        // Comprimir con la calidad actual
        compressedBytes = Uint8List.fromList(
          img.encodeJpg(image, quality: quality),
        );

        // Guardar temporalmente
        final tempDir = await getTemporaryDirectory();
        final tempPath = path.join(
          tempDir.path,
          'compressed_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        compressedFile = await File(tempPath).writeAsBytes(compressedBytes);

        // Verificar tamaño
        final sizeMB = await getFileSizeMB(compressedFile);
        print('🗜️ Comprimida (calidad $quality): ${sizeMB.toStringAsFixed(2)} MB');

        if (sizeMB <= 10) {
          print('✅ Imagen comprimida exitosamente: ${sizeMB.toStringAsFixed(2)} MB');
          return compressedFile;
        }

        // Reducir calidad para siguiente intento
        quality -= 10;
      }

      // 3. Si aún es muy grande, reducir dimensiones más agresivamente
      if (compressedFile != null) {
        final sizeMB = await getFileSizeMB(compressedFile);
        if (sizeMB > 10) {
          print('⚠️ Reduciendo dimensiones agresivamente...');
          image = img.copyResize(
            image,
            width: (image.width * 0.7).toInt(),
            height: (image.height * 0.7).toInt(),
          );

          compressedBytes = Uint8List.fromList(
            img.encodeJpg(image, quality: 50),
          );

          final tempDir = await getTemporaryDirectory();
          final tempPath = path.join(
            tempDir.path,
            'compressed_aggressive_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          compressedFile = await File(tempPath).writeAsBytes(compressedBytes);

          final finalSize = await getFileSizeMB(compressedFile);
          print('🗜️ Compresión agresiva: ${finalSize.toStringAsFixed(2)} MB');

          if (finalSize <= 10) {
            return compressedFile;
          }
        }
      }

      print('❌ No se pudo comprimir la imagen bajo 10 MB');
      return null;
    } catch (e) {
      print('❌ Error comprimiendo imagen: $e');
      return null;
    }
  }

  /// Comprime y valida un video para envío
  ///
  /// Si el video excede 10MB, lo comprime automáticamente.
  /// Retorna el archivo comprimido si es exitoso, null si falla.
  Future<File?> validateVideo(File videoFile, {Function(double)? onProgress}) async {
    try {
      // 1. Verificar tamaño original
      final originalSizeMB = await getFileSizeMB(videoFile);
      print('🎥 Video original: ${originalSizeMB.toStringAsFixed(2)} MB');

      // 2. Si ya está bajo el límite, retornar sin comprimir
      if (originalSizeMB <= 10) {
        print('✅ Video ya está bajo el límite (${originalSizeMB.toStringAsFixed(2)} MB)');
        return videoFile;
      }

      // 3. Comprimir video
      print('🗜️ Comprimiendo video de ${originalSizeMB.toStringAsFixed(2)} MB...');

      // Comprimir con calidad media (sin escuchar progreso para evitar error de Stream)
      // El progreso se imprime internamente por video_compress
      final MediaInfo? compressedInfo = await VideoCompress.compressVideo(
        videoFile.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false, // Mantener original por si falla
        includeAudio: true,
      );

      // 4. Verificar si la compresión fue exitosa
      if (compressedInfo == null || compressedInfo.file == null) {
        print('❌ Error: La compresión no produjo un archivo');
        return null;
      }

      final compressedFile = compressedInfo.file!;
      final compressedSizeMB = await getFileSizeMB(compressedFile);
      print('✅ Video comprimido: ${compressedSizeMB.toStringAsFixed(2)} MB');

      // 5. Verificar si el video comprimido está bajo el límite
      if (compressedSizeMB <= 10) {
        print('✅ Video comprimido exitosamente de ${originalSizeMB.toStringAsFixed(2)} MB a ${compressedSizeMB.toStringAsFixed(2)} MB');
        return compressedFile;
      }

      // 6. Si aún es muy grande, intentar con calidad baja
      print('⚠️ Video aún muy grande, intentando con calidad baja...');

      final MediaInfo? lowQualityInfo = await VideoCompress.compressVideo(
        videoFile.path,
        quality: VideoQuality.LowQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      if (lowQualityInfo == null || lowQualityInfo.file == null) {
        print('❌ Error en compresión de baja calidad');
        return null;
      }

      final lowQualityFile = lowQualityInfo.file!;
      final lowQualitySizeMB = await getFileSizeMB(lowQualityFile);
      print('🗜️ Video calidad baja: ${lowQualitySizeMB.toStringAsFixed(2)} MB');

      if (lowQualitySizeMB <= 10) {
        print('✅ Video comprimido con calidad baja: ${lowQualitySizeMB.toStringAsFixed(2)} MB');
        return lowQualityFile;
      }

      // 7. Si aún es muy grande, fallar
      print('❌ No se pudo comprimir el video bajo 10 MB');
      return null;
    } catch (e) {
      print('❌ Error comprimiendo video: $e');
      return null;
    }
  }

  /// Cancela la compresión de video en curso
  Future<void> cancelVideoCompression() async {
    try {
      await VideoCompress.cancelCompression();
    } catch (e) {
      print('⚠️ Error cancelando compresión: $e');
    }
  }

  /// Limpia archivos temporales de video_compress
  Future<void> cleanupVideoCompress() async {
    try {
      await VideoCompress.deleteAllCache();
    } catch (e) {
      print('⚠️ Error limpiando cache de videos: $e');
    }
  }

  /// Valida un archivo de audio
  Future<File?> validateAudio(File audioFile) async {
    try {
      final isValid = await validateFileSize(audioFile);

      if (!isValid) {
        final sizeMB = await getFileSizeMB(audioFile);
        print('❌ Audio muy grande: ${sizeMB.toStringAsFixed(2)} MB (máx 10 MB)');
        return null;
      }

      final sizeMB = await getFileSizeMB(audioFile);
      print('✅ Audio válido: ${sizeMB.toStringAsFixed(2)} MB');
      return audioFile;
    } catch (e) {
      print('❌ Error validando audio: $e');
      return null;
    }
  }
}
