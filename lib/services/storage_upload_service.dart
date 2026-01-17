import 'dart:async';
import 'package:talia/services/remote_logger_service.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:http/http.dart' as http;

/// Servicio para subir archivos a Firebase Storage
///
/// WORKAROUND: El SDK de Firebase Storage en iOS/Flutter tiene un bug crítico
/// donde los uploads se congelan después de solo 194 bytes (headers HTTP).
/// Este servicio bypasea el SDK y usa el REST API directamente.
class StorageUploadService {
  static final StorageUploadService _instance = StorageUploadService._internal();
  factory StorageUploadService() => _instance;
  StorageUploadService._internal();

  /// Subir archivo a Firebase Storage usando REST API
  ///
  /// [filePath] Ruta en Storage (ej: "profile_images/user123.jpg")
  /// [fileBytes] Bytes del archivo a subir
  /// [contentType] Tipo MIME del archivo (ej: "image/jpeg", "video/mp4")
  ///
  /// Retorna la URL de descarga del archivo
  Future<String> uploadFile({
    required String filePath,
    required Uint8List fileBytes,
    required String contentType,
  }) async {
    try {
      appLogger.log('📤 [StorageUpload] Subiendo archivo: $filePath', level: 'INFO');
      appLogger.log('📦 [StorageUpload] Tamaño: ${fileBytes.length} bytes', level: 'INFO');
      appLogger.log('📄 [StorageUpload] Content-Type: $contentType', level: 'INFO');

      // Obtener ID token del usuario autenticado
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      final idToken = await user.getIdToken(true);
      if (idToken == null) {
        throw Exception('No se pudo obtener ID token');
      }

      // Obtener bucket de Storage
      final bucket = FirebaseStorage.instance.bucket;

      // URL del REST API de Firebase Storage
      final uploadUrl = Uri.parse(
        'https://firebasestorage.googleapis.com/v0/b/$bucket/o?uploadType=media&name=${Uri.encodeComponent(filePath)}'
      );

      appLogger.log('📡 [StorageUpload] URL: $uploadUrl', level: 'INFO');

      // Crear request HTTP POST
      final request = http.Request('POST', uploadUrl);

      // Headers
      request.headers['Authorization'] = 'Bearer $idToken';
      request.headers['Content-Type'] = contentType;
      request.headers['Content-Length'] = fileBytes.length.toString();

      // Body
      request.bodyBytes = fileBytes;

      appLogger.log('📤 [StorageUpload] Enviando request...', level: 'INFO');

      // Enviar request con timeout
      final streamedResponse = await request.send().timeout(
        Duration(seconds: 120),
        onTimeout: () {
          appLogger.log('⏱️ [StorageUpload] Timeout después de 120 segundos', level: 'INFO');
          throw TimeoutException('Upload timeout');
        },
      );

      appLogger.log('📥 [StorageUpload] Response status: ${streamedResponse.statusCode}', level: 'INFO');

      if (streamedResponse.statusCode != 200) {
        final responseBody = await streamedResponse.stream.bytesToString();
        appLogger.log('❌ [StorageUpload] Error response: $responseBody', level: 'ERROR');
        throw Exception('Upload failed: ${streamedResponse.statusCode} - $responseBody');
      }

      // Leer response
      final responseBody = await streamedResponse.stream.bytesToString();
      appLogger.log('✅ [StorageUpload] Upload exitoso', level: 'INFO');

      // Parse response JSON para obtener download URL
      final responseJson = jsonDecode(responseBody);
      final downloadToken = responseJson['downloadTokens'];

      if (downloadToken == null) {
        throw Exception('No se pudo obtener download token del response');
      }

      // Construir download URL
      final downloadUrl = 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/${Uri.encodeComponent(filePath)}?alt=media&token=$downloadToken';

      appLogger.log('📸 [StorageUpload] URL de descarga: $downloadUrl', level: 'INFO');

      return downloadUrl;
    } catch (e) {
      appLogger.log('❌ [StorageUpload] Error subiendo archivo: $e', level: 'ERROR');
      rethrow;
    }
  }

  /// Subir imagen desde File a Firebase Storage
  ///
  /// [filePath] Ruta en Storage (ej: "profile_images/user123.jpg")
  /// [imageFile] Archivo de imagen a subir
  ///
  /// Retorna la URL de descarga de la imagen
  Future<String> uploadImageFile({
    required String filePath,
    required File imageFile,
  }) async {
    try {
      appLogger.log('📷 [StorageUpload] Leyendo imagen desde: ${imageFile.path}', level: 'INFO');

      // Verificar que el archivo existe
      final exists = await imageFile.exists();
      if (!exists) {
        throw Exception('El archivo no existe: ${imageFile.path}');
      }

      // Leer bytes de la imagen
      final imageBytes = await imageFile.readAsBytes();

      if (imageBytes.isEmpty) {
        throw Exception('La imagen está vacía');
      }

      // Detectar tipo de imagen por magic bytes
      String contentType = 'image/jpeg'; // Default

      if (imageBytes.length >= 12) {
        // Formatos comunes por magic bytes
        final isJPEG = imageBytes[0] == 0xFF && imageBytes[1] == 0xD8 && imageBytes[2] == 0xFF;
        final isPNG = imageBytes[0] == 0x89 && imageBytes[1] == 0x50 && imageBytes[2] == 0x4E && imageBytes[3] == 0x47;
        final isGIF = imageBytes[0] == 0x47 && imageBytes[1] == 0x49 && imageBytes[2] == 0x46;
        final isBMP = imageBytes[0] == 0x42 && imageBytes[1] == 0x4D; // "BM"
        final isWebP = imageBytes[0] == 0x52 && imageBytes[1] == 0x49 && imageBytes[2] == 0x46 && imageBytes[3] == 0x46 &&
                       imageBytes[8] == 0x57 && imageBytes[9] == 0x45 && imageBytes[10] == 0x42 && imageBytes[11] == 0x50;

        // TIFF: "II" (little-endian) o "MM" (big-endian) + magic number 42
        final isTIFF = (imageBytes[0] == 0x49 && imageBytes[1] == 0x49 && imageBytes[2] == 0x2A && imageBytes[3] == 0x00) ||
                       (imageBytes[0] == 0x4D && imageBytes[1] == 0x4D && imageBytes[2] == 0x00 && imageBytes[3] == 0x2A);

        // HEIC/HEIF: bytes 4-7 = "ftyp", bytes 8-11 = brand (heic, mif1, heif, msf1, avif, etc.)
        final isFtyp = imageBytes.length >= 12 &&
                       imageBytes[4] == 0x66 && imageBytes[5] == 0x74 && imageBytes[6] == 0x79 && imageBytes[7] == 0x70; // "ftyp"

        final isHEIC = isFtyp && (
          // heic
          (imageBytes[8] == 0x68 && imageBytes[9] == 0x65 && imageBytes[10] == 0x69 && imageBytes[11] == 0x63) ||
          // heif
          (imageBytes[8] == 0x68 && imageBytes[9] == 0x65 && imageBytes[10] == 0x69 && imageBytes[11] == 0x66) ||
          // mif1
          (imageBytes[8] == 0x6D && imageBytes[9] == 0x69 && imageBytes[10] == 0x66 && imageBytes[11] == 0x31)
        );

        // AVIF: ftyp + "avif" o "avis"
        final isAVIF = isFtyp && (
          (imageBytes[8] == 0x61 && imageBytes[9] == 0x76 && imageBytes[10] == 0x69 && imageBytes[11] == 0x66) || // avif
          (imageBytes[8] == 0x61 && imageBytes[9] == 0x76 && imageBytes[10] == 0x69 && imageBytes[11] == 0x73)    // avis
        );

        if (isPNG) {
          contentType = 'image/png';
        } else if (isJPEG) {
          contentType = 'image/jpeg';
        } else if (isGIF) {
          contentType = 'image/gif';
        } else if (isBMP) {
          contentType = 'image/bmp';
        } else if (isWebP) {
          contentType = 'image/webp';
        } else if (isTIFF) {
          contentType = 'image/tiff';
        } else if (isAVIF) {
          contentType = 'image/avif';
        } else if (isHEIC) {
          contentType = 'image/heic';
        } else {
          // Fallback: detectar por extensión del archivo
          final ext = filePath.toLowerCase();
          if (ext.endsWith('.heic') || ext.endsWith('.heif')) {
            contentType = 'image/heic';
          } else if (ext.endsWith('.avif')) {
            contentType = 'image/avif';
          } else if (ext.endsWith('.tiff') || ext.endsWith('.tif')) {
            contentType = 'image/tiff';
          } else if (ext.endsWith('.bmp')) {
            contentType = 'image/bmp';
          } else {
            appLogger.log('⚠️ [StorageUpload] No se pudo detectar tipo de imagen, usando JPEG por defecto', level: 'WARNING');
          }
        }

        appLogger.log('📷 [StorageUpload] Tipo detectado: $contentType', level: 'INFO');
      }

      // Subir usando REST API
      return await uploadFile(
        filePath: filePath,
        fileBytes: imageBytes,
        contentType: contentType,
      );
    } catch (e) {
      appLogger.log('❌ [StorageUpload] Error subiendo imagen: $e', level: 'ERROR');
      rethrow;
    }
  }

  /// Eliminar archivo de Firebase Storage
  ///
  /// [filePath] Ruta en Storage del archivo a eliminar
  Future<void> deleteFile(String filePath) async {
    try {
      appLogger.log('🗑️ [StorageUpload] Eliminando archivo: $filePath', level: 'INFO');

      final ref = FirebaseStorage.instance.ref().child(filePath);
      await ref.delete();

      appLogger.log('✅ [StorageUpload] Archivo eliminado exitosamente', level: 'INFO');
    } catch (e) {
      appLogger.log('❌ [StorageUpload] Error eliminando archivo: $e', level: 'ERROR');
      rethrow;
    }
  }
}
