import 'dart:async';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as path;
import '../../../utils/release_logger.dart';

/// Manager para gestión de uploads de archivos de mensajes de chat
///
/// Responsabilidades:
/// - Upload de archivos multimedia a Firebase Storage
/// - Progress tracking y callbacks
/// - Retry logic para uploads fallidos
/// - Cleanup de archivos temporales
/// - NO contiene lógica de mensajes, solo uploads
class MessageUploadManager {
  final FirebaseStorage _storage;

  // Tracking de uploads activos
  final Map<String, UploadTask> _activeUploads = {};
  final Map<String, StreamController<double>> _progressControllers = {};

  // Retry configuration
  static const int _maxRetryAttempts = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  // Métricas
  int _uploadsCompleted = 0;
  int _uploadsFailed = 0;
  int _uploadsInProgress = 0;

  MessageUploadManager({
    FirebaseStorage? storage,
  }) : _storage = storage ?? FirebaseStorage.instance;

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API - UPLOAD OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Upload archivo de mensaje con retry automático
  Future<String> uploadWithRetry({
    required String filePath,
    required String chatId,
    required String messageId,
    Function(double)? onProgressUpdate,
  }) async {
    const maxRetries = _maxRetryAttempts;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await uploadMessageMedia(
          filePath: filePath,
          chatId: chatId,
          messageId: messageId,
          onProgressUpdate: onProgressUpdate,
        );
      } catch (e) {
        ReleaseLogger.error('Upload attempt ${attempt + 1} failed: $e',
                           tag: 'MessageUpload');

        if (attempt == maxRetries - 1) {
          _uploadsFailed++;
          rethrow; // Re-lanzar en último intento
        }

        // Wait before retry
        await Future.delayed(_retryDelay * (attempt + 1));
      }
    }

    throw Exception('Failed to upload after $maxRetries attempts');
  }

  /// Upload archivo de mensaje con progress tracking
  Future<String> uploadMessageMedia({
    required String filePath,
    required String chatId,
    required String messageId,
    Function(double progress)? onProgressUpdate,
  }) async {
    final uploadId = '${chatId}_$messageId';

    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw Exception('Archivo no encontrado: $filePath');
      }

      _uploadsInProgress++;

      // Generar path único en Storage
      final storagePath = _generateStoragePath(chatId, messageId, filePath);

      // Crear referencia y task
      final ref = _storage.ref().child(storagePath);
      final uploadTask = ref.putFile(file);

      // Registrar upload activo
      _activeUploads[uploadId] = uploadTask;

      // Setup progress tracking
      if (onProgressUpdate != null) {
        uploadTask.snapshotEvents.listen((snapshot) {
          final progress = snapshot.bytesTransferred / snapshot.totalBytes;
          onProgressUpdate(progress);
        });
      }

      // Esperar completación CON TIMEOUT. Sin esto, si Storage se estanca (red
      // o token App Check que no llega) el upload se cuelga para siempre y el
      // mensaje queda en "pending" eterno. Con timeout, lanza → uploadWithRetry
      // reintenta y, si agota, el mensaje pasa a error (reintentable por el user).
      final taskSnapshot = await uploadTask.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          uploadTask.cancel();
          throw TimeoutException('Upload de Storage excedió 45s');
        },
      );
      final downloadUrl = await taskSnapshot.ref
          .getDownloadURL()
          .timeout(const Duration(seconds: 15));

      // Cleanup
      _activeUploads.remove(uploadId);
      _uploadsCompleted++;
      _uploadsInProgress--;

      ReleaseLogger.info('Upload completado: $downloadUrl', tag: 'MessageUpload');
      return downloadUrl;

    } catch (e) {
      _activeUploads.remove(uploadId);
      _uploadsInProgress--;

      ReleaseLogger.error('Error en upload: $e', tag: 'MessageUpload');
      throw Exception('Upload failed: $e');
    }
  }

  /// Cancelar upload específico
  Future<void> cancelUpload({
    required String chatId,
    required String messageId,
  }) async {
    final uploadId = '${chatId}_$messageId';
    final uploadTask = _activeUploads[uploadId];

    if (uploadTask != null) {
      try {
        await uploadTask.cancel();
        _activeUploads.remove(uploadId);
        _uploadsInProgress--;
        ReleaseLogger.info('Upload cancelado: $uploadId', tag: 'MessageUpload');
      } catch (e) {
        ReleaseLogger.error('Error cancelando upload: $e', tag: 'MessageUpload');
      }
    }
  }

  /// Pausar upload específico
  Future<void> pauseUpload({
    required String chatId,
    required String messageId,
  }) async {
    final uploadId = '${chatId}_$messageId';
    final uploadTask = _activeUploads[uploadId];

    if (uploadTask != null) {
      try {
        await uploadTask.pause();
        ReleaseLogger.info('Upload pausado: $uploadId', tag: 'MessageUpload');
      } catch (e) {
        ReleaseLogger.error('Error pausando upload: $e', tag: 'MessageUpload');
      }
    }
  }

  /// Reanudar upload específico
  Future<void> resumeUpload({
    required String chatId,
    required String messageId,
  }) async {
    final uploadId = '${chatId}_$messageId';
    final uploadTask = _activeUploads[uploadId];

    if (uploadTask != null) {
      try {
        await uploadTask.resume();
        ReleaseLogger.info('Upload reanudado: $uploadId', tag: 'MessageUpload');
      } catch (e) {
        ReleaseLogger.error('Error reanudando upload: $e', tag: 'MessageUpload');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Generar path único en Firebase Storage
  String _generateStoragePath(String chatId, String messageId, String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Determinar tipo de media por extensión
    String mediaType;
    if (['.jpg', '.jpeg', '.jfif', '.png', '.gif', '.webp', '.heic', '.heif', '.bmp', '.tiff', '.tif', '.avif'].contains(extension)) {
      mediaType = 'images';
    } else if (['.mp4', '.mov', '.avi', '.webm'].contains(extension)) {
      mediaType = 'videos';
    } else if (['.mp3', '.aac', '.wav', '.m4a'].contains(extension)) {
      mediaType = 'audio';
    } else {
      mediaType = 'files';
    }

    return 'chat_media/$mediaType/$chatId/${messageId}_$timestamp$extension';
  }

  /// Verificar si un upload está activo
  bool isUploadActive(String chatId, String messageId) {
    final uploadId = '${chatId}_$messageId';
    return _activeUploads.containsKey(uploadId);
  }

  /// Obtener progress de un upload específico
  Stream<double>? getUploadProgress(String chatId, String messageId) {
    final uploadId = '${chatId}_$messageId';
    final uploadTask = _activeUploads[uploadId];

    if (uploadTask == null) return null;

    return uploadTask.snapshotEvents.map((snapshot) {
      return snapshot.bytesTransferred / snapshot.totalBytes;
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // BATCH OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Cancelar todos los uploads activos
  Future<void> cancelAllUploads() async {
    final activeUploads = List.from(_activeUploads.values);

    for (final uploadTask in activeUploads) {
      try {
        await uploadTask.cancel();
      } catch (e) {
        ReleaseLogger.error('Error cancelando upload: $e', tag: 'MessageUpload');
      }
    }

    _activeUploads.clear();
    _uploadsInProgress = 0;
    ReleaseLogger.info('Todos los uploads cancelados', tag: 'MessageUpload');
  }

  /// Pausar todos los uploads activos
  Future<void> pauseAllUploads() async {
    for (final uploadTask in _activeUploads.values) {
      try {
        await uploadTask.pause();
      } catch (e) {
        ReleaseLogger.error('Error pausando upload: $e', tag: 'MessageUpload');
      }
    }
    ReleaseLogger.info('Todos los uploads pausados', tag: 'MessageUpload');
  }

  /// Reanudar todos los uploads pausados
  Future<void> resumeAllUploads() async {
    for (final uploadTask in _activeUploads.values) {
      try {
        await uploadTask.resume();
      } catch (e) {
        ReleaseLogger.error('Error reanudando upload: $e', tag: 'MessageUpload');
      }
    }
    ReleaseLogger.info('Todos los uploads reanudados', tag: 'MessageUpload');
  }

  // ═══════════════════════════════════════════════════════════════
  // METRICS & MONITORING
  // ═══════════════════════════════════════════════════════════════

  /// Obtener número de uploads pendientes
  int getPendingUploadsCount() => _uploadsInProgress;

  /// Obtener número de uploads activos
  int getActiveUploadsCount() => _activeUploads.length;

  /// Obtener métricas completas
  Map<String, dynamic> getUploadMetrics() {
    return {
      'active': _activeUploads.length,
      'inProgress': _uploadsInProgress,
      'completed': _uploadsCompleted,
      'failed': _uploadsFailed,
      'successRate': _uploadsCompleted + _uploadsFailed > 0
          ? _uploadsCompleted / (_uploadsCompleted + _uploadsFailed)
          : 0.0,
    };
  }

  /// Reset métricas
  void resetMetrics() {
    _uploadsCompleted = 0;
    _uploadsFailed = 0;
    // No resetear _uploadsInProgress porque representa estado actual
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Dispose completo - cancelar todos los uploads
  void dispose() {
    // Cancelar uploads sin esperar (fire and forget)
    for (var task in _activeUploads.values) {
      task.cancel().then((_) {}).catchError((e) {
        ReleaseLogger.error('Error en dispose upload: $e', tag: 'MessageUpload');
      });
    }

    _activeUploads.clear();

    // Cerrar progress controllers
    for (var controller in _progressControllers.values) {
      controller.close();
    }
    _progressControllers.clear();

    _uploadsInProgress = 0;
    ReleaseLogger.info('MessageUploadManager disposed', tag: 'MessageUpload');
  }
}