import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:talia/utils/release_logger.dart';

class MediaService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _imagePicker = ImagePicker();

  /// Subir imagen desde un archivo File
  Future<String?> uploadImageFile({
    required File imageFile,
    required String chatId,
    required String userId,
  }) async {
    try {
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_${path.basename(imageFile.path)}';
      final String storagePath = 'chats/$chatId/images/$fileName';


      final UploadTask uploadTask = _storage.ref(storagePath).putFile(imageFile);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      return null;
    }
  }

  /// Subir video desde un archivo File
  Future<String?> uploadVideoFile({
    required File videoFile,
    required String chatId,
    required String userId,
  }) async {
    try {
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_${path.basename(videoFile.path)}';
      final String storagePath = 'chats/$chatId/videos/$fileName';


      final UploadTask uploadTask = _storage.ref(storagePath).putFile(videoFile);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      return null;
    }
  }

  /// Subir audio desde un archivo File
  Future<String?> uploadAudioFile({
    required File audioFile,
    required String chatId,
    required String userId,
  }) async {
    try {
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_audio.m4a';
      final String storagePath = 'chats/$chatId/audios/$fileName';

      ReleaseLogger.log(
        '📤 Upload audio - chatId: $chatId, userId: $userId, path: $storagePath',
        tag: 'MediaService',
      );

      final UploadTask uploadTask = _storage.ref(storagePath).putFile(audioFile);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      ReleaseLogger.error(
        '❌ Upload audio FAILED - chatId: $chatId, userId: $userId, error: $e',
        tag: 'MediaService',
      );
      rethrow;
    }
  }

  // Seleccionar archivo genérico
  Future<Map<String, dynamic>?> pickFile() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx', 'txt'],
      );

      if (result == null || result.files.isEmpty) return null;

      final PlatformFile file = result.files.first;
      return {
        'path': file.path,
        'name': file.name,
        'size': file.size,
        'extension': file.extension,
      };
    } catch (e) {
      return null;
    }
  }

  // Subir archivo genérico
  Future<String?> uploadFile({
    required String filePath,
    required String fileName,
    required String chatId,
    required String userId,
  }) async {
    try {
      final File file = File(filePath);
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String storagePath = 'chats/$chatId/files/${timestamp}_$fileName';

      final UploadTask uploadTask = _storage.ref(storagePath).putFile(file);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      return null;
    }
  }

  // ========== MÉTODOS DE COMPATIBILIDAD (DEPRECATED) ==========
  // Estos métodos se mantienen para compatibilidad con código antiguo
  // pero se recomienda usar los nuevos métodos *File

  /// @deprecated Usar uploadImageFile() en su lugar
  Future<String?> uploadImage({
    required ImageSource source,
    required String chatId,
    required String userId,
  }) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1920,
        maxHeight: 1920,
      );

      if (image == null) return null;

      final File file = File(image.path);
      return uploadImageFile(
        imageFile: file,
        chatId: chatId,
        userId: userId,
      );
    } catch (e) {
      return null;
    }
  }

  /// @deprecated Usar uploadVideoFile() en su lugar
  Future<String?> uploadVideo({
    required String chatId,
    required String userId,
  }) async {
    try {
      final XFile? video = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );

      if (video == null) return null;

      final File file = File(video.path);
      return uploadVideoFile(
        videoFile: file,
        chatId: chatId,
        userId: userId,
      );
    } catch (e) {
      return null;
    }
  }

  /// @deprecated Usar uploadAudioFile() en su lugar
  Future<String?> uploadAudio({
    required String audioPath,
    required String chatId,
    required String userId,
  }) async {
    try {
      final File file = File(audioPath);
      return uploadAudioFile(
        audioFile: file,
        chatId: chatId,
        userId: userId,
      );
    } catch (e) {
      return null;
    }
  }
}
