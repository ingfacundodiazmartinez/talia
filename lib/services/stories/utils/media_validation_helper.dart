import 'dart:io';

/// Helper centralizado para validaciones de archivos multimedia
///
/// Evita duplicación de código entre servicios y screens
/// que necesitan validar formatos de imagen/video
///
/// SEGURIDAD: Incluye validaciones de tamaño para prevenir abuse
class MediaValidationHelper {

  // Extensiones válidas para imágenes
  static const List<String> _imageExtensions = [
    '.jpg', '.jpeg', '.png', '.gif'
  ];

  // Extensiones válidas para videos
  static const List<String> _videoExtensions = [
    '.mp4', '.mov', '.avi', '.mkv'
  ];

  // Todas las extensiones válidas
  static const List<String> _validExtensions = [
    ..._imageExtensions,
    ..._videoExtensions,
  ];

  // Límites de tamaño de archivo (en bytes)
  static const int _maxImageSizeBytes = 20 * 1024 * 1024; // 20 MB para imágenes
  static const int _maxVideoSizeBytes = 100 * 1024 * 1024; // 100 MB para videos

  /// Valida si el archivo tiene una extensión válida
  static bool isValidMediaFile(String filePath) {
    final lowercasePath = filePath.toLowerCase();
    return _validExtensions.any((ext) => lowercasePath.endsWith(ext));
  }

  /// Determina el tipo de media desde la extensión del archivo
  /// Retorna: 'image', 'video', o 'unknown'
  static String getMediaTypeFromPath(String filePath) {
    final lowercasePath = filePath.toLowerCase();

    if (_imageExtensions.any((ext) => lowercasePath.endsWith(ext))) {
      return 'image';
    } else if (_videoExtensions.any((ext) => lowercasePath.endsWith(ext))) {
      return 'video';
    } else {
      return 'unknown';
    }
  }

  /// Valida si el tipo de media corresponde con la extensión del archivo
  static bool validateMediaTypeMatchesPath(String filePath, String mediaType) {
    final detectedType = getMediaTypeFromPath(filePath);
    return detectedType == mediaType;
  }

  /// Valida tamaño del archivo según el tipo de media
  /// SEGURIDAD: Previene uploads masivos que podrían causar DoS
  static Future<ValidationResult> validateFileSize(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return ValidationResult.error('Archivo no encontrado: $filePath');
      }

      final fileSize = await file.length();
      final mediaType = getMediaTypeFromPath(filePath);

      switch (mediaType) {
        case 'image':
          if (fileSize > _maxImageSizeBytes) {
            final maxMB = _maxImageSizeBytes / (1024 * 1024);
            return ValidationResult.error(
              'Imagen demasiado grande. Máximo permitido: ${maxMB.toInt()}MB'
            );
          }
          break;
        case 'video':
          if (fileSize > _maxVideoSizeBytes) {
            final maxMB = _maxVideoSizeBytes / (1024 * 1024);
            return ValidationResult.error(
              'Video demasiado grande. Máximo permitido: ${maxMB.toInt()}MB'
            );
          }
          break;
        default:
          return ValidationResult.error('Tipo de archivo no soportado');
      }

      return ValidationResult.success();
    } catch (e) {
      return ValidationResult.error('Error validando archivo: $e');
    }
  }

  /// Validación completa de archivo multimedia
  /// Incluye formato, tamaño y existencia
  static Future<ValidationResult> validateMediaFileComplete(String filePath) async {
    // 1. Validar que existe
    final file = File(filePath);
    if (!await file.exists()) {
      return ValidationResult.error('Archivo no encontrado: $filePath');
    }

    // 2. Validar extensión
    if (!isValidMediaFile(filePath)) {
      return ValidationResult.error(
        'Formato no soportado. Formatos válidos: ${_validExtensions.join(', ')}'
      );
    }

    // 3. Validar tamaño
    final sizeValidation = await validateFileSize(filePath);
    if (!sizeValidation.isValid) {
      return sizeValidation;
    }

    return ValidationResult.success();
  }

  /// Retorna extensiones válidas para mostrar en UI
  static List<String> get validImageExtensions => List.unmodifiable(_imageExtensions);
  static List<String> get validVideoExtensions => List.unmodifiable(_videoExtensions);
  static List<String> get allValidExtensions => List.unmodifiable(_validExtensions);

  /// Getters para límites de tamaño (para mostrar en UI)
  static int get maxImageSizeMB => _maxImageSizeBytes ~/ (1024 * 1024);
  static int get maxVideoSizeMB => _maxVideoSizeBytes ~/ (1024 * 1024);
}

/// Resultado de validación con detalles del error si aplica
class ValidationResult {
  final bool isValid;
  final String? errorMessage;

  ValidationResult._(this.isValid, this.errorMessage);

  factory ValidationResult.success() => ValidationResult._(true, null);
  factory ValidationResult.error(String message) => ValidationResult._(false, message);
}