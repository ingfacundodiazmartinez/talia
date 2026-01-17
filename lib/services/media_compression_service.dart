import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:video_compress/video_compress.dart';
import '../utils/release_logger.dart';

/// Servicio para comprimir y validar archivos multimedia
///
/// Responsabilidades:
/// - Comprimir imágenes manteniendo calidad aceptable
/// - Validar tamaño de archivos (max 10MB)
/// - Comprimir videos (resize si es necesario)
///
/// ✅ OPTIMIZACIÓN: Compresión agresiva para reducir costos de storage y mejorar tiempos de carga
class MediaCompressionService {
  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10 MB

  // Configuración de compresión AGRESIVA (optimizada para balance calidad/tamaño)
  static const int targetImageWidth = 1280; // Reducido de 1920
  static const int targetImageHeight = 1280; // Reducido de 1920
  static const int imageQuality = 70; // Reducido de 85

  // Configuración para profile photos (más pequeñas)
  static const int profilePhotoWidth = 512;
  static const int profilePhotoHeight = 512;
  static const int profilePhotoQuality = 75;

  /// Valida que un archivo no exceda el tamaño máximo
  Future<bool> validateFileSize(File file) async {
    try {
      final fileSize = await file.length();
      return fileSize <= maxFileSizeBytes;
    } catch (e) {
      ReleaseLogger.error('❌ Error validando tamaño: $e', tag: 'MediaCompressionService');
      return false;
    }
  }

  /// Obtiene el tamaño de un archivo en MB
  Future<double> getFileSizeMB(File file) async {
    try {
      final fileSize = await file.length();
      return fileSize / (1024 * 1024);
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo tamaño: $e', tag: 'MediaCompressionService');
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
        ReleaseLogger.error('❌ No se pudo decodificar la imagen', tag: 'MediaCompressionService');
        return null;
      }

      ReleaseLogger.log('📸 Imagen original: ${image.width}x${image.height}', tag: 'MediaCompressionService');

      // ✅ FIX: Aplicar rotación EXIF antes de redimensionar
      // Esto corrige fotos que aparecen ensanchadas o rotadas
      image = img.bakeOrientation(image);

      // 1. Redimensionar si excede las dimensiones objetivo
      if (image.width > targetImageWidth || image.height > targetImageHeight) {
        image = img.copyResize(
          image,
          width: image.width > image.height ? targetImageWidth : null,
          height: image.height >= image.width ? targetImageHeight : null,
        );
        ReleaseLogger.log('📏 Redimensionada a: ${image.width}x${image.height}', tag: 'MediaCompressionService');
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
        ReleaseLogger.log('🗜️ Comprimida (calidad $quality): ${sizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');

        if (sizeMB <= 10) {
          ReleaseLogger.log('✅ Imagen comprimida exitosamente: ${sizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');
          return compressedFile;
        }

        // Reducir calidad para siguiente intento
        quality -= 10;
      }

      // 3. Si aún es muy grande, reducir dimensiones más agresivamente
      if (compressedFile != null) {
        final sizeMB = await getFileSizeMB(compressedFile);
        if (sizeMB > 10) {
          ReleaseLogger.log('⚠️ Reduciendo dimensiones agresivamente...', tag: 'MediaCompressionService');
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
          ReleaseLogger.log('🗜️ Compresión agresiva: ${finalSize.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');

          if (finalSize <= 10) {
            return compressedFile;
          }
        }
      }

      ReleaseLogger.error('❌ No se pudo comprimir la imagen bajo 10 MB', tag: 'MediaCompressionService');
      return null;
    } catch (e) {
      ReleaseLogger.error('❌ Error comprimiendo imagen: $e', tag: 'MediaCompressionService');
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
      ReleaseLogger.log('🎥 Video original: ${originalSizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');

      // 2. Si ya está bajo el límite, retornar sin comprimir
      if (originalSizeMB <= 10) {
        ReleaseLogger.log('✅ Video ya está bajo el límite (${originalSizeMB.toStringAsFixed(2)} MB)', tag: 'MediaCompressionService');
        return videoFile;
      }

      // 3. Comprimir video
      ReleaseLogger.log('🗜️ Comprimiendo video de ${originalSizeMB.toStringAsFixed(2)} MB...', tag: 'MediaCompressionService');

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
        ReleaseLogger.error('❌ Error: La compresión no produjo un archivo', tag: 'MediaCompressionService');
        return null;
      }

      final compressedFile = compressedInfo.file!;
      final compressedSizeMB = await getFileSizeMB(compressedFile);
      ReleaseLogger.log('✅ Video comprimido: ${compressedSizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');

      // 5. Verificar si el video comprimido está bajo el límite
      if (compressedSizeMB <= 10) {
        ReleaseLogger.log('✅ Video comprimido exitosamente de ${originalSizeMB.toStringAsFixed(2)} MB a ${compressedSizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');
        return compressedFile;
      }

      // 6. Si aún es muy grande, intentar con calidad baja
      ReleaseLogger.log('⚠️ Video aún muy grande, intentando con calidad baja...', tag: 'MediaCompressionService');

      final MediaInfo? lowQualityInfo = await VideoCompress.compressVideo(
        videoFile.path,
        quality: VideoQuality.LowQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      if (lowQualityInfo == null || lowQualityInfo.file == null) {
        ReleaseLogger.error('❌ Error en compresión de baja calidad', tag: 'MediaCompressionService');
        return null;
      }

      final lowQualityFile = lowQualityInfo.file!;
      final lowQualitySizeMB = await getFileSizeMB(lowQualityFile);
      ReleaseLogger.log('🗜️ Video calidad baja: ${lowQualitySizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');

      if (lowQualitySizeMB <= 10) {
        ReleaseLogger.log('✅ Video comprimido con calidad baja: ${lowQualitySizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');
        return lowQualityFile;
      }

      // 7. Si aún es muy grande, fallar
      ReleaseLogger.error('❌ No se pudo comprimir el video bajo 10 MB', tag: 'MediaCompressionService');
      return null;
    } catch (e) {
      ReleaseLogger.error('❌ Error comprimiendo video: $e', tag: 'MediaCompressionService');
      return null;
    }
  }

  /// Cancela la compresión de video en curso
  Future<void> cancelVideoCompression() async {
    try {
      await VideoCompress.cancelCompression();
    } catch (e) {
      ReleaseLogger.log('⚠️ Error cancelando compresión: $e', tag: 'MediaCompressionService');
    }
  }

  /// Limpia archivos temporales de video_compress
  Future<void> cleanupVideoCompress() async {
    try {
      await VideoCompress.deleteAllCache();
    } catch (e) {
      ReleaseLogger.log('⚠️ Error limpiando cache de videos: $e', tag: 'MediaCompressionService');
    }
  }

  /// Comprime una imagen para foto de perfil (más agresiva)
  ///
  /// Las fotos de perfil son pequeñas y se muestran en thumbnails,
  /// por lo que pueden ser más comprimidas sin pérdida perceptible.
  Future<File?> compressProfilePhoto(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);

      if (image == null) {
        ReleaseLogger.error('No se pudo decodificar imagen de perfil', tag: 'MediaCompressionService');
        return null;
      }

      ReleaseLogger.log('📸 Foto de perfil original: ${image.width}x${image.height}', tag: 'MediaCompressionService');

      // ✅ FIX: Aplicar rotación EXIF antes de redimensionar
      // Esto corrige fotos que aparecen ensanchadas o rotadas
      image = img.bakeOrientation(image);
      ReleaseLogger.log('📸 Orientación EXIF aplicada: ${image.width}x${image.height}', tag: 'MediaCompressionService');

      // ✅ FIX: Redimensionar manteniendo aspect ratio SIN recortar
      // El CircleAvatar con BoxFit.cover se encargará del recorte visual
      // Esto preserva la imagen completa en storage
      final int maxSize = profilePhotoWidth; // 512

      if (image.width > maxSize || image.height > maxSize) {
        // Redimensionar manteniendo aspect ratio (lado más largo = maxSize)
        if (image.width > image.height) {
          image = img.copyResize(image, width: maxSize);
        } else {
          image = img.copyResize(image, height: maxSize);
        }
      }

      ReleaseLogger.log('📸 Imagen redimensionada: ${image.width}x${image.height}', tag: 'MediaCompressionService');

      // Comprimir con calidad de perfil
      final compressedBytes = Uint8List.fromList(
        img.encodeJpg(image, quality: profilePhotoQuality),
      );

      final tempDir = await getTemporaryDirectory();
      final tempPath = path.join(
        tempDir.path,
        'profile_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final compressedFile = await File(tempPath).writeAsBytes(compressedBytes);

      final sizeMB = await getFileSizeMB(compressedFile);
      ReleaseLogger.log('✅ Foto de perfil comprimida: ${sizeMB.toStringAsFixed(2)} MB (${profilePhotoWidth}x$profilePhotoHeight)', tag: 'MediaCompressionService');

      return compressedFile;
    } catch (e) {
      ReleaseLogger.error('Error comprimiendo foto de perfil: $e', tag: 'MediaCompressionService');
      return null;
    }
  }

  /// Comprime video para stories (siempre comprime para mejor UX)
  ///
  /// A diferencia de validateVideo, este método SIEMPRE comprime
  /// para optimizar tiempos de carga en stories.
  Future<File?> compressVideoForStory(File videoFile) async {
    try {
      final originalSizeMB = await getFileSizeMB(videoFile);
      ReleaseLogger.log('🎥 Video story original: ${originalSizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');

      // Siempre comprimir para stories (mejor UX de carga)
      ReleaseLogger.log('🗜️ Comprimiendo video para story...', tag: 'MediaCompressionService');

      final MediaInfo? compressedInfo = await VideoCompress.compressVideo(
        videoFile.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      if (compressedInfo == null || compressedInfo.file == null) {
        ReleaseLogger.error('❌ Error: La compresión no produjo un archivo', tag: 'MediaCompressionService');
        return videoFile; // Retornar original si falla
      }

      final compressedFile = compressedInfo.file!;
      final compressedSizeMB = await getFileSizeMB(compressedFile);
      ReleaseLogger.log(
        '✅ Video story comprimido: ${originalSizeMB.toStringAsFixed(2)} MB → ${compressedSizeMB.toStringAsFixed(2)} MB',
        tag: 'MediaCompressionService',
      );

      return compressedFile;
    } catch (e) {
      ReleaseLogger.error('❌ Error comprimiendo video story: $e', tag: 'MediaCompressionService');
      return videoFile; // Retornar original si falla
    }
  }

  /// Valida un archivo de audio
  Future<File?> validateAudio(File audioFile) async {
    try {
      final isValid = await validateFileSize(audioFile);

      if (!isValid) {
        final sizeMB = await getFileSizeMB(audioFile);
        ReleaseLogger.error('❌ Audio muy grande: ${sizeMB.toStringAsFixed(2)} MB (máx 10 MB)', tag: 'MediaCompressionService');
        return null;
      }

      final sizeMB = await getFileSizeMB(audioFile);
      ReleaseLogger.log('✅ Audio válido: ${sizeMB.toStringAsFixed(2)} MB', tag: 'MediaCompressionService');
      return audioFile;
    } catch (e) {
      ReleaseLogger.error('❌ Error validando audio: $e', tag: 'MediaCompressionService');
      return null;
    }
  }
}
