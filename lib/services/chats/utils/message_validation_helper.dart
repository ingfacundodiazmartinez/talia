import 'dart:io';

/// Helper centralizado para validaciones de mensajes y archivos de chat
///
/// Evita duplicación de código entre servicios y screens
/// que necesitan validar contenido de mensajes
///
/// SEGURIDAD: Incluye validaciones de tamaño y contenido para prevenir abuse
class MessageValidationHelper {

  // Extensiones válidas para imágenes
  // Incluye formatos comunes: JPEG, PNG, GIF, WebP, HEIC/HEIF (iPhone), BMP, TIFF, AVIF
  static const List<String> _imageExtensions = [
    '.jpg', '.jpeg', '.jfif', '.png', '.gif', '.webp',
    '.heic', '.heif',  // iPhone iOS 11+
    '.bmp',            // Bitmap
    '.tiff', '.tif',   // TIFF
    '.avif',           // AV1 Image Format (moderno)
  ];

  // Extensiones válidas para videos
  static const List<String> _videoExtensions = [
    '.mp4', '.mov', '.avi', '.mkv', '.webm'
  ];

  // Extensiones válidas para audio
  static const List<String> _audioExtensions = [
    '.mp3', '.aac', '.wav', '.m4a', '.ogg'
  ];

  // Extensiones válidas para documentos
  static const List<String> _documentExtensions = [
    '.pdf', '.doc', '.docx', '.txt', '.rtf'
  ];

  // Todas las extensiones válidas
  static const List<String> _validExtensions = [
    ..._imageExtensions,
    ..._videoExtensions,
    ..._audioExtensions,
    ..._documentExtensions,
  ];

  // Límites de tamaño de archivo (en bytes)
  static const int _maxImageSizeBytes = 20 * 1024 * 1024;     // 20 MB para imágenes
  static const int _maxVideoSizeBytes = 100 * 1024 * 1024;    // 100 MB para videos
  static const int _maxAudioSizeBytes = 50 * 1024 * 1024;     // 50 MB para audio
  static const int _maxDocumentSizeBytes = 25 * 1024 * 1024;  // 25 MB para documentos

  // Límites de contenido de texto
  static const int _maxMessageLength = 5000; // Máximo caracteres por mensaje
  static const int _maxLinksPerMessage = 5;  // Máximo links por mensaje

  // Patrones de contenido bloqueado
  static final RegExp _urlPattern = RegExp(
    r'https?://[^\s]+',
    caseSensitive: false,
  );

  // ═══════════════════════════════════════════════════════════════
  // VALIDACIÓN DE ARCHIVOS MULTIMEDIA
  // ═══════════════════════════════════════════════════════════════

  /// Valida si el archivo tiene una extensión válida
  static bool isValidMediaFile(String filePath) {
    final lowercasePath = filePath.toLowerCase();
    return _validExtensions.any((ext) => lowercasePath.endsWith(ext));
  }

  /// Determina el tipo de media desde la extensión del archivo
  /// Retorna: 'image', 'video', 'audio', 'document', o 'unknown'
  static String getMediaTypeFromPath(String filePath) {
    final lowercasePath = filePath.toLowerCase();

    if (_imageExtensions.any((ext) => lowercasePath.endsWith(ext))) {
      return 'image';
    } else if (_videoExtensions.any((ext) => lowercasePath.endsWith(ext))) {
      return 'video';
    } else if (_audioExtensions.any((ext) => lowercasePath.endsWith(ext))) {
      return 'audio';
    } else if (_documentExtensions.any((ext) => lowercasePath.endsWith(ext))) {
      return 'document';
    }

    return 'unknown';
  }

  /// Valida tamaño del archivo según su tipo
  static Future<ValidationResult> validateFileSize(String filePath) async {
    try {
      final file = File(filePath);

      if (!await file.exists()) {
        return ValidationResult.error('Archivo no encontrado');
      }

      final sizeBytes = await file.length();
      final mediaType = getMediaTypeFromPath(filePath);
      int maxSize;

      switch (mediaType) {
        case 'image':
          maxSize = _maxImageSizeBytes;
          break;
        case 'video':
          maxSize = _maxVideoSizeBytes;
          break;
        case 'audio':
          maxSize = _maxAudioSizeBytes;
          break;
        case 'document':
          maxSize = _maxDocumentSizeBytes;
          break;
        default:
          return ValidationResult.error('Tipo de archivo no soportado');
      }

      if (sizeBytes > maxSize) {
        final maxSizeMB = (maxSize / (1024 * 1024)).toStringAsFixed(1);
        return ValidationResult.error('Archivo demasiado grande. Máximo: ${maxSizeMB}MB');
      }

      return ValidationResult.success();

    } catch (e) {
      return ValidationResult.error('Error validando archivo: $e');
    }
  }

  /// Validación completa de archivo multimedia
  static Future<ValidationResult> validateMediaFile(String filePath) async {
    // 1. Validar extensión
    if (!isValidMediaFile(filePath)) {
      return ValidationResult.error('Formato de archivo no soportado');
    }

    // 2. Validar tamaño
    final sizeValidation = await validateFileSize(filePath);
    if (!sizeValidation.isValid) {
      return sizeValidation;
    }

    return ValidationResult.success();
  }

  // ═══════════════════════════════════════════════════════════════
  // VALIDACIÓN DE CONTENIDO DE TEXTO
  // ═══════════════════════════════════════════════════════════════

  /// Valida contenido de texto de un mensaje
  static ValidationResult validateMessageText(String text) {
    // Validar longitud
    if (text.length > _maxMessageLength) {
      return ValidationResult.error(
        'Mensaje demasiado largo. Máximo: $_maxMessageLength caracteres'
      );
    }

    // Validar cantidad de links
    final links = _urlPattern.allMatches(text);
    if (links.length > _maxLinksPerMessage) {
      return ValidationResult.error(
        'Demasiados enlaces. Máximo: $_maxLinksPerMessage por mensaje'
      );
    }

    return ValidationResult.success();
  }

  /// Sanitizar texto del mensaje
  static String sanitizeMessageText(String text) {
    // Remover caracteres de control y espacios excesivos
    String sanitized = text
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '') // Control characters
        .replaceAll(RegExp(r'\s+'), ' ') // Multiple spaces to single space
        .trim();

    // Limitar longitud si es necesario
    if (sanitized.length > _maxMessageLength) {
      sanitized = sanitized.substring(0, _maxMessageLength);
    }

    return sanitized;
  }

  /// Detectar y validar URLs en el mensaje
  static List<String> extractUrls(String text) {
    final matches = _urlPattern.allMatches(text);
    return matches.map((match) => match.group(0)!).toList();
  }

  // ═══════════════════════════════════════════════════════════════
  // VALIDACIONES ADICIONALES
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si el mensaje está vacío después de sanitización
  static bool isMessageEmpty(String text) {
    return sanitizeMessageText(text).isEmpty;
  }

  /// Validar que el mensaje no sea solo espacios o caracteres especiales
  static bool isValidMessageContent(String text) {
    final sanitized = sanitizeMessageText(text);
    return sanitized.isNotEmpty && sanitized.trim().isNotEmpty;
  }

  /// Obtener información del archivo para logging
  static Future<Map<String, dynamic>> getFileInfo(String filePath) async {
    try {
      final file = File(filePath);
      final sizeBytes = await file.length();
      final sizeKB = (sizeBytes / 1024).toStringAsFixed(1);
      final sizeMB = (sizeBytes / (1024 * 1024)).toStringAsFixed(2);

      return {
        'path': filePath,
        'sizeBytes': sizeBytes,
        'sizeKB': sizeKB,
        'sizeMB': sizeMB,
        'mediaType': getMediaTypeFromPath(filePath),
        'isValid': isValidMediaFile(filePath),
      };
    } catch (e) {
      return {
        'path': filePath,
        'error': e.toString(),
        'isValid': false,
      };
    }
  }
}

/// Resultado de validación
class ValidationResult {
  final bool isValid;
  final String? errorMessage;

  ValidationResult._(this.isValid, this.errorMessage);

  factory ValidationResult.success() => ValidationResult._(true, null);
  factory ValidationResult.error(String message) => ValidationResult._(false, message);

  @override
  String toString() {
    return isValid ? 'Valid' : 'Invalid: $errorMessage';
  }
}