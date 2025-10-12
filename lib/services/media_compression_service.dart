import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

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

  /// Valida y prepara un video para envío
  ///
  /// Por ahora solo valida tamaño. En el futuro se puede agregar
  /// compresión de video usando ffmpeg o similar.
  Future<File?> validateVideo(File videoFile) async {
    try {
      final isValid = await validateFileSize(videoFile);

      if (!isValid) {
        final sizeMB = await getFileSizeMB(videoFile);
        print('❌ Video muy grande: ${sizeMB.toStringAsFixed(2)} MB (máx 10 MB)');
        return null;
      }

      final sizeMB = await getFileSizeMB(videoFile);
      print('✅ Video válido: ${sizeMB.toStringAsFixed(2)} MB');
      return videoFile;
    } catch (e) {
      print('❌ Error validando video: $e');
      return null;
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
