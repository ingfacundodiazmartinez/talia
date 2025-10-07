import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

class MediaService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _imagePicker = ImagePicker();

  // Subir imagen desde cámara o galería
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
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_${path.basename(image.path)}';
      final String storagePath = 'chats/$chatId/images/$fileName';

      final UploadTask uploadTask = _storage.ref(storagePath).putFile(file);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      print('Error subiendo imagen: $e');
      return null;
    }
  }

  // Subir video
  Future<String?> uploadVideo({
    required String chatId,
    required String userId,
  }) async {
    try {
      final XFile? video = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: Duration(minutes: 5),
      );

      if (video == null) return null;

      final File file = File(video.path);
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_${path.basename(video.path)}';
      final String storagePath = 'chats/$chatId/videos/$fileName';

      final UploadTask uploadTask = _storage.ref(storagePath).putFile(file);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      print('Error subiendo video: $e');
      return null;
    }
  }

  // Subir audio
  Future<String?> uploadAudio({
    required String audioPath,
    required String chatId,
    required String userId,
  }) async {
    try {
      final File file = File(audioPath);
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_audio.m4a';
      final String storagePath = 'chats/$chatId/audios/$fileName';

      final UploadTask uploadTask = _storage.ref(storagePath).putFile(file);
      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } catch (e) {
      print('Error subiendo audio: $e');
      return null;
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
      print('Error seleccionando archivo: $e');
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
      print('Error subiendo archivo: $e');
      return null;
    }
  }
}
