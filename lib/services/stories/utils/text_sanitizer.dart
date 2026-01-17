import 'dart:convert';

/// Helper para sanitización y validación de texto de usuario
///
/// SEGURIDAD: Previene inyección de HTML/JavaScript y caracteres peligrosos
/// en captions, respuestas y otros inputs de texto
///
/// ENFOQUE NATIVO: Usa dart:convert nativo en lugar de packages desactualizados
class TextSanitizer {
  // Límites de longitud para diferentes tipos de texto
  static const int maxCaptionLength = 500;
  static const int maxReplyLength = 300;
  static const int maxReasonLength = 200;

  /// Sanitiza texto de caption para stories
  static String sanitizeCaption(String? input) {
    if (input == null || input.trim().isEmpty) {
      return '';
    }
    return _sanitizeGeneral(input, maxCaptionLength);
  }

  /// Sanitiza texto de respuesta a stories
  static String sanitizeReply(String? input) {
    if (input == null || input.trim().isEmpty) {
      throw Exception('Texto de respuesta no puede estar vacío');
    }
    return _sanitizeGeneral(input, maxReplyLength);
  }

  /// Sanitiza razón de rechazo de story
  static String sanitizeRejectionReason(String? input) {
    if (input == null || input.trim().isEmpty) {
      throw Exception('Razón de rechazo no puede estar vacía');
    }
    return _sanitizeGeneral(input, maxReasonLength);
  }

  /// Sanitización general de texto
  static String _sanitizeGeneral(String input, int maxLength) {
    // 1. Remover caracteres de control (excepto salto de línea y tab)
    var clean = input.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '');

    // 2. Normalizar espacios en blanco y saltos de línea
    clean = clean
        .replaceAll(RegExp(r'\r\n|\r'), '\n') // Normalizar line endings
        .replaceAll(RegExp(r'\n{3,}'), '\n\n') // Max 2 líneas seguidas
        .replaceAll(RegExp(r'[ \t]+'), ' '); // Múltiples espacios -> uno

    // 3. Trim general
    clean = clean.trim();

    // 4. Validar longitud
    if (clean.length > maxLength) {
      throw Exception('Texto demasiado largo. Máximo: $maxLength caracteres');
    }

    // 5. Escapar caracteres peligrosos para prevenir inyección
    clean = _escapeHtml(clean);

    // 6. Validar contenido sospechoso
    _validateSuspiciousContent(clean);

    return clean;
  }

  /// Escapa caracteres HTML peligrosos usando dart:convert nativo
  /// NATIVO: Usa HtmlEscape de dart:convert en lugar de packages externos
  static String _escapeHtml(String input) {
    const htmlEscape = HtmlEscape();
    return htmlEscape.convert(input);
  }

  /// Valida contenido potencialmente malicioso
  static void _validateSuspiciousContent(String input) {
    final suspiciousPatterns = [
      // Patrones de JavaScript
      RegExp(r'<script.*?>', caseSensitive: false),
      RegExp(r'javascript:', caseSensitive: false),
      RegExp(r'on\w+\s*=', caseSensitive: false), // onclick, onload, etc.


      // Caracteres Unicode peligrosos (que podrían usarse para spoofing)
      RegExp(r'[\u200B-\u200F\u2028-\u202F\u205F-\u206F]'), // Espacios invisibles
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'), // Caracteres de control
    ];

    for (final pattern in suspiciousPatterns) {
      if (pattern.hasMatch(input)) {
        throw Exception('Texto contiene caracteres o patrones no permitidos');
      }
    }

    // Verificar exceso de caracteres especiales (posible spam/abuse)
    final specialCharCount = input.split('').where((char) =>
        RegExp(r'''[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?~`]''').hasMatch(char)
    ).length;

    if (specialCharCount > input.length * 0.5) {
      throw Exception('Texto contiene demasiados caracteres especiales');
    }
  }

  /// Valida que el texto no esté vacío después de sanitización
  static void validateNotEmpty(String sanitized, String fieldName) {
    if (sanitized.trim().isEmpty) {
      throw Exception('$fieldName no puede estar vacío');
    }
  }

  /// Genera versión segura para logs (primeros N caracteres + hash del resto)
  static String toSafeLogString(String input, {int maxVisibleChars = 10}) {
    if (input.length <= maxVisibleChars) {
      return input;
    }

    final visible = input.substring(0, maxVisibleChars);
    final hash = input.hashCode.toRadixString(16);
    return '$visible...(#$hash)';
  }

  // ═══════════════════════════════════════════════════════════════
  // VALIDADORES NATIVOS - Reemplazan form_field_validator
  // ═══════════════════════════════════════════════════════════════

  /// Valida email usando regex nativa (más segura que packages desactualizados)
  static bool isValidEmail(String email) {
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    );
    return emailRegex.hasMatch(email.trim());
  }

  /// Valida URL usando Uri nativo de Dart
  static bool isValidUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
    } catch (e) {
      return false;
    }
  }

  /// Valida longitud de string
  static bool hasValidLength(String input, {int? min, int? max}) {
    final length = input.length;
    if (min != null && length < min) return false;
    if (max != null && length > max) return false;
    return true;
  }

  /// Valida que el string no esté vacío
  static bool isNotEmpty(String? input) {
    return input != null && input.trim().isNotEmpty;
  }

  /// Valida números
  static bool isValidNumber(String input) {
    return double.tryParse(input.trim()) != null;
  }

  /// Valida enteros
  static bool isValidInteger(String input) {
    return int.tryParse(input.trim()) != null;
  }

  /// Valida que esté en un rango numérico
  static bool isInRange(String input, double min, double max) {
    final number = double.tryParse(input.trim());
    return number != null && number >= min && number <= max;
  }

  /// Valida patrones custom con regex
  static bool matchesPattern(String input, String pattern) {
    try {
      final regex = RegExp(pattern);
      return regex.hasMatch(input);
    } catch (e) {
      return false;
    }
  }
}