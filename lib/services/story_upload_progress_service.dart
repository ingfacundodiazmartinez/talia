import 'dart:async';

/// Service to manage story upload progress globally.
/// Allows the UI to react to progress updates across the app.
class StoryUploadProgressService {
  // Singleton pattern
  static final StoryUploadProgressService _instance =
      StoryUploadProgressService._internal();

  factory StoryUploadProgressService() {
    return _instance;
  }

  StoryUploadProgressService._internal();

  // Map to store upload progress for each story
  final Map<String, double> _uploadProgress = {};

  // Stream controller to broadcast progress updates
  final StreamController<Map<String, double>> _progressController =
      StreamController<Map<String, double>>.broadcast();

  // Timers for auto-cleanup
  final Map<String, Timer> _cleanupTimers = {};

  /// Get the broadcast stream of progress updates
  Stream<Map<String, double>> get progressStream => _progressController.stream;

  /// Update progress for a specific story
  /// [storyId] - The unique identifier for the story
  /// [progress] - Progress value (0.0 to 1.0, or -1.0 for error)
  void updateProgress(String storyId, double progress) {
    _uploadProgress[storyId] = progress;

    // Broadcast the updated map to all listeners
    _progressController.add(Map.from(_uploadProgress));

    // Handle completed uploads (progress == 1.0)
    if (progress == 1.0) {
      _scheduleCleanup(storyId);
    }

    // Handle errors (progress == -1.0)
    if (progress == -1.0) {
      _scheduleCleanup(storyId, delay: const Duration(seconds: 5));
    }
  }

  /// Get current progress for a specific story
  /// Returns null if no progress data exists
  double? getProgress(String storyId) {
    return _uploadProgress[storyId];
  }

  /// Remove progress data for a specific story
  /// Useful for cleaning up completed or failed uploads
  void removeProgress(String storyId) {
    _uploadProgress.remove(storyId);

    // Cancel any pending cleanup timer
    _cleanupTimers[storyId]?.cancel();
    _cleanupTimers.remove(storyId);

    // Broadcast the updated map
    _progressController.add(Map.from(_uploadProgress));
  }

  /// Schedule automatic cleanup of progress data
  void _scheduleCleanup(String storyId,
      {Duration delay = const Duration(seconds: 2)}) {
    // Cancel any existing cleanup timer for this story
    _cleanupTimers[storyId]?.cancel();

    // Schedule new cleanup
    _cleanupTimers[storyId] = Timer(delay, () {
      removeProgress(storyId);
    });
  }

  /// Get all current upload progress data
  Map<String, double> getAllProgress() {
    return Map.from(_uploadProgress);
  }

  /// Check if any uploads are in progress
  bool hasActiveUploads() {
    return _uploadProgress.values.any((progress) =>
      progress >= 0.0 && progress < 1.0
    );
  }

  /// Get count of active uploads
  int getActiveUploadCount() {
    return _uploadProgress.values.where((progress) =>
      progress >= 0.0 && progress < 1.0
    ).length;
  }

  /// Clear all progress data
  void clearAll() {
    _uploadProgress.clear();

    // Cancel all cleanup timers
    for (var timer in _cleanupTimers.values) {
      timer.cancel();
    }
    _cleanupTimers.clear();

    // Broadcast empty map
    _progressController.add({});
  }

  /// Dispose of the service and clean up resources
  void dispose() {
    // Cancel all timers
    for (var timer in _cleanupTimers.values) {
      timer.cancel();
    }
    _cleanupTimers.clear();

    // Close the stream controller
    _progressController.close();

    // Clear progress data
    _uploadProgress.clear();
  }
}
