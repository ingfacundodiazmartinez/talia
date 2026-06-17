import 'dart:async';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

/// Manager para gestión de uploads de archivos de historias
///
/// Responsabilidades:
/// - Upload de archivos a Firebase Storage
/// - Progress tracking y callbacks
/// - Retry logic para uploads fallidos
/// - Cleanup de archivos temporales
/// - NO contiene lógica de historias, solo uploads
class StoryUploadManager {
  final FirebaseStorage _storage;

  // Tracking de uploads activos
  final Map<String, UploadTask> _activeUploads = {};
  final Map<String, StreamController<double>> _progressControllers = {};

  // Métricas
  int _uploadsCompleted = 0;
  int _uploadsFailed = 0;

  StoryUploadManager({
    required FirebaseStorage storage,
  }) : _storage = storage;

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API - UPLOAD OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Upload archivo con progress tracking
  Future<String> uploadStoryMedia({
    required String filePath,
    required String storyId,
    required String userId,
    Function(double progress)? onProgressUpdate,
  }) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw Exception('Archivo no encontrado: $filePath');
      }

      // Generar path único en Storage
      final storagePath = _generateStoragePath(userId, storyId, filePath);

      // Crear referencia y task
      final ref = _storage.ref().child(storagePath);
      final uploadTask = ref.putFile(file);

      // Registrar upload activo
      _activeUploads[storyId] = uploadTask;

      // Crear progress controller si se necesita
      if (onProgressUpdate != null) {
        final progressController = StreamController<double>.broadcast();
        _progressControllers[storyId] = progressController;

        // Escuchar progress
        uploadTask.snapshotEvents.listen(
          (taskSnapshot) {
            // Firebase reporta totalBytes == 0 en el primer snapshot (o con
            // archivos vacíos). 0/0 = NaN, y luego `NaN.toInt()` en los
            // consumidores lanza UnsupportedError (crash). Guardamos y clampeamos.
            final total = taskSnapshot.totalBytes;
            final progress = total > 0
                ? (taskSnapshot.bytesTransferred / total).clamp(0.0, 1.0)
                : 0.0;
            onProgressUpdate(progress);
            if (!progressController.isClosed) progressController.add(progress);
          },
          onError: (error) {
            if (!progressController.isClosed) progressController.addError(error);
          },
        );
      }

      // Esperar completion
      final snapshot = await uploadTask;

      // Obtener download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();

      // Cleanup
      _cleanupUpload(storyId);
      _uploadsCompleted++;

      return downloadUrl;
    } catch (e) {
      _cleanupUpload(storyId);
      _uploadsFailed++;
      throw Exception('Error en upload: $e');
    }
  }

  /// Upload con retry automático
  Future<String> uploadWithRetry({
    required String filePath,
    required String storyId,
    required String userId,
    Function(double progress)? onProgressUpdate,
    int maxRetries = 3,
  }) async {
    Exception? lastError;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        return await uploadStoryMedia(
          filePath: filePath,
          storyId: storyId,
          userId: userId,
          onProgressUpdate: onProgressUpdate,
        );
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());

        if (attempt < maxRetries) {
          // Delay exponencial entre reintentos
          final delay = Duration(seconds: attempt * 2);
          await Future.delayed(delay);
        }
      }
    }

    throw lastError ?? Exception('Upload falló después de $maxRetries intentos');
  }

  /// Cancelar upload activo
  Future<void> cancelUpload(String storyId) async {
    final uploadTask = _activeUploads[storyId];
    if (uploadTask != null) {
      await uploadTask.cancel();
      _cleanupUpload(storyId);
    }
  }

  /// Pausar upload
  Future<void> pauseUpload(String storyId) async {
    final uploadTask = _activeUploads[storyId];
    if (uploadTask != null) {
      await uploadTask.pause();
    }
  }

  /// Resumir upload pausado
  Future<void> resumeUpload(String storyId) async {
    final uploadTask = _activeUploads[storyId];
    if (uploadTask != null) {
      await uploadTask.resume();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PROGRESS STREAMS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener stream de progreso para un upload específico
  Stream<double>? getProgressStream(String storyId) {
    return _progressControllers[storyId]?.stream;
  }

  /// Verificar si un upload está activo
  bool isUploadActive(String storyId) {
    return _activeUploads.containsKey(storyId);
  }

  /// Obtener estado de upload
  TaskState? getUploadState(String storyId) {
    final uploadTask = _activeUploads[storyId];
    return uploadTask?.snapshot.state;
  }

  // ═══════════════════════════════════════════════════════════════
  // FILE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Eliminar archivo de Storage
  Future<void> deleteStoryMedia(String downloadUrl) async {
    try {
      final ref = _storage.refFromURL(downloadUrl);
      await ref.delete();
    } catch (e) {
      throw Exception('Error eliminando archivo: $e');
    }
  }

  /// Copiar archivo para reply permanente
  Future<String> copyFileForReply({
    required String originalUrl,
    required String newStoryId,
    required String userId,
  }) async {
    try {
      // Descargar archivo original
      final originalRef = _storage.refFromURL(originalUrl);
      final tempFile = await _downloadToTemp(originalRef);

      // Upload a nueva ubicación
      final newUrl = await uploadStoryMedia(
        filePath: tempFile.path,
        storyId: newStoryId,
        userId: userId,
      );

      // Limpiar archivo temporal
      await tempFile.delete();

      return newUrl;
    } catch (e) {
      throw Exception('Error copiando archivo: $e');
    }
  }

  /// Obtener metadata de archivo
  Future<FullMetadata> getFileMetadata(String downloadUrl) async {
    try {
      final ref = _storage.refFromURL(downloadUrl);
      return await ref.getMetadata();
    } catch (e) {
      throw Exception('Error obteniendo metadata: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // BATCH OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Upload múltiples archivos en paralelo
  Future<List<String>> uploadMultipleFiles({
    required List<String> filePaths,
    required String storyId,
    required String userId,
    Function(String filePath, double progress)? onProgressUpdate,
  }) async {
    final futures = filePaths.asMap().entries.map((entry) {
      final index = entry.key;
      final filePath = entry.value;

      return uploadStoryMedia(
        filePath: filePath,
        storyId: '${storyId}_$index',
        userId: userId,
        onProgressUpdate: onProgressUpdate != null
            ? (progress) => onProgressUpdate(filePath, progress)
            : null,
      );
    });

    return await Future.wait(futures);
  }

  /// Cancelar todos los uploads activos
  Future<void> cancelAllUploads() async {
    final futures = _activeUploads.keys.map(cancelUpload);
    await Future.wait(futures);
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Generar path único en Storage
  String _generateStoragePath(String userId, String storyId, String filePath) {
    final file = File(filePath);
    final extension = file.path.split('.').last.toLowerCase();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    return 'stories/$userId/$storyId/$timestamp.$extension';
  }

  /// Limpiar recursos de upload
  void _cleanupUpload(String storyId) {
    _activeUploads.remove(storyId);

    final progressController = _progressControllers.remove(storyId);
    progressController?.close();
  }

  /// Descargar archivo a temporal
  Future<File> _downloadToTemp(Reference ref) async {
    final tempDir = Directory.systemTemp;
    final tempFile = File('${tempDir.path}/${ref.name}_${DateTime.now().millisecondsSinceEpoch}');

    await ref.writeToFile(tempFile);
    return tempFile;
  }

  // ═══════════════════════════════════════════════════════════════
  // METRICS & DEBUGGING
  // ═══════════════════════════════════════════════════════════════

  /// Obtener número de uploads pendientes
  int getPendingUploadsCount() => _activeUploads.length;

  /// Obtener métricas de uploads
  Map<String, dynamic> getMetrics() {
    return {
      'activeUploads': _activeUploads.length,
      'uploadsCompleted': _uploadsCompleted,
      'uploadsFailed': _uploadsFailed,
      'successRate': _uploadsCompleted + _uploadsFailed > 0
          ? _uploadsCompleted / (_uploadsCompleted + _uploadsFailed)
          : 0.0,
      'activeUploadIds': _activeUploads.keys.toList(),
    };
  }

  /// Reset métricas
  void resetMetrics() {
    _uploadsCompleted = 0;
    _uploadsFailed = 0;
  }

  /// Obtener información detallada de uploads activos
  Map<String, Map<String, dynamic>> getActiveUploadsInfo() {
    final info = <String, Map<String, dynamic>>{};

    for (final entry in _activeUploads.entries) {
      final storyId = entry.key;
      final uploadTask = entry.value;
      final snapshot = uploadTask.snapshot;

      info[storyId] = {
        'state': snapshot.state.toString(),
        'bytesTransferred': snapshot.bytesTransferred,
        'totalBytes': snapshot.totalBytes,
        'progress': snapshot.bytesTransferred / snapshot.totalBytes,
      };
    }

    return info;
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar recursos
  void dispose() {
    // Cerrar controllers de progreso
    for (final controller in _progressControllers.values) {
      controller.close();
    }
    _progressControllers.clear();

    // Cancelar uploads activos
    cancelAllUploads();

    // Reset métricas
    resetMetrics();
  }
}