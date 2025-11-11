
/// Helper para sanitización y validación de contenido de mensajes de chat
///
/// SEGURIDAD: Previene inyección de HTML/JavaScript y caracteres peligrosos
/// en mensajes de texto, nombres de grupos y otros inputs de usuario
///
/// ENFOQUE NATIVO: Usa dart:convert nativo en lugar de packages desactualizados
class ContentSanitizer {
  // Límites de longitud para diferentes tipos de contenido
  static const int maxMessageLength = 5000;
  static const int maxGroupNameLength = 50;
  static const int maxGroupDescriptionLength = 200;
  static const int maxNicknameLength = 30;

  /// Sanitiza contenido de mensaje de chat
  static String sanitizeMessage(String? input) {
    if (input == null || input.trim().isEmpty) {
      return '';
    }
    return _sanitizeGeneral(input, maxMessageLength);
  }

  /// Sanitiza nombre de grupo (requerido)
  static String sanitizeGroupName(String? input) {
    if (input == null || input.trim().isEmpty) {
      throw Exception('Nombre de grupo no puede estar vacío');
    }
    return _sanitizeGeneral(input, maxGroupNameLength);
  }

  /// Sanitiza descripción de grupo
  static String sanitizeGroupDescription(String? input) {
    if (input == null || input.trim().isEmpty) {
      return '';
    }
    return _sanitizeGeneral(input, maxGroupDescriptionLength);
  }

  /// Sanitiza nickname/alias de contacto
  static String sanitizeNickname(String? input) {
    if (input == null || input.trim().isEmpty) {
      return '';
    }
    return _sanitizeGeneral(input, maxNicknameLength);
  }

  /// Sanitización general para cualquier texto
  static String _sanitizeGeneral(String input, int maxLength) {
    // 1. Trim inicial
    String sanitized = input.trim();

    // 2. Remover caracteres de control peligrosos
    sanitized = _removeControlCharacters(sanitized);

    // 3. Escapar caracteres HTML/JS
    sanitized = _escapeHtmlCharacters(sanitized);

    // 4. Normalizar espacios en blanco
    sanitized = _normalizeWhitespace(sanitized);

    // 5. Limitar longitud
    if (sanitized.length > maxLength) {
      sanitized = sanitized.substring(0, maxLength).trim();
    }

    return sanitized;
  }

  /// Remover caracteres de control que pueden ser problemáticos
  static String _removeControlCharacters(String input) {
    // Remover caracteres de control C0 (excepto tab, new line, carriage return)
    String result = input.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

    // Remover caracteres de control C1
    result = result.replaceAll(RegExp(r'[\x80-\x9F]'), '');

    return result;
  }

  /// Escapar caracteres HTML peligrosos
  static String _escapeHtmlCharacters(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#x27;')
        .replaceAll('/', '&#x2F;');
  }

  /// Normalizar espacios en blanco
  static String _normalizeWhitespace(String input) {
    // Convertir múltiples espacios, tabs y newlines en espacios únicos
    return input
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Validar que el contenido no esté vacío después de sanitización
  static bool isValidContent(String? input) {
    if (input == null) return false;
    final sanitized = _sanitizeGeneral(input, maxMessageLength);
    return sanitized.isNotEmpty;
  }

  /// Detectar y filtrar URLs sospechosas
  static String filterSuspiciousUrls(String input) {
    // Pattern para URLs maliciosas comunes
    final suspiciousPatterns = [
      RegExp(r'javascript:', caseSensitive: false),
      RegExp(r'data:', caseSensitive: false),
      RegExp(r'vbscript:', caseSensitive: false),
      RegExp(r'file:', caseSensitive: false),
    ];

    String result = input;
    for (final pattern in suspiciousPatterns) {
      result = result.replaceAll(pattern, '[FILTERED]');
    }

    return result;
  }

  /// Validar que no contenga scripts inline
  static bool containsInlineScript(String input) {
    final scriptPatterns = [
      RegExp(r'<script', caseSensitive: false),
      RegExp(r'javascript:', caseSensitive: false),
      RegExp(r'on\w+\s*=', caseSensitive: false), // onclick, onload, etc.
    ];

    return scriptPatterns.any((pattern) => pattern.hasMatch(input));
  }

  /// Limpiar emojis duplicados o excesivos
  static String limitEmojis(String input, {int maxConsecutive = 5}) {
    // Pattern para detectar emojis consecutivos
    final emojiPattern = RegExp(r'[\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F1E0}-\u{1F1FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]', unicode: true);

    return input.replaceAllMapped(RegExp(r'([\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F1E0}-\u{1F1FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]){${maxConsecutive + 1},}', unicode: true), (match) {
      final emoji = match.group(0)!.substring(0, 2); // Tomar el primer emoji
      return emoji * maxConsecutive; // Limitarlo al máximo
    });
  }

  /// Validación completa de contenido
  static ContentValidationResult validateAndSanitize(String? input, ContentType type) {
    if (input == null || input.trim().isEmpty) {
      if (_isRequired(type)) {
        return ContentValidationResult.error('El contenido es requerido');
      }
      return ContentValidationResult.success('');
    }

    // Verificar scripts inline
    if (containsInlineScript(input)) {
      return ContentValidationResult.error('Contenido contiene scripts no permitidos');
    }

    try {
      String sanitized;
      switch (type) {
        case ContentType.message:
          sanitized = sanitizeMessage(input);
          break;
        case ContentType.groupName:
          sanitized = sanitizeGroupName(input);
          break;
        case ContentType.groupDescription:
          sanitized = sanitizeGroupDescription(input);
          break;
        case ContentType.nickname:
          sanitized = sanitizeNickname(input);
          break;
      }

      // Filtrar URLs sospechosas
      sanitized = filterSuspiciousUrls(sanitized);

      // Limitar emojis excesivos
      sanitized = limitEmojis(sanitized);

      return ContentValidationResult.success(sanitized);

    } catch (e) {
      return ContentValidationResult.error(e.toString());
    }
  }

  /// Verificar si un tipo de contenido es requerido
  static bool _isRequired(ContentType type) {
    return type == ContentType.groupName;
  }

  /// Obtener estadísticas del contenido
  static ContentStats getContentStats(String input) {
    final lines = input.split('\n').length;
    final words = input.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
    final characters = input.length;
    final charactersNoSpaces = input.replaceAll(RegExp(r'\s'), '').length;

    return ContentStats(
      lines: lines,
      words: words,
      characters: characters,
      charactersNoSpaces: charactersNoSpaces,
    );
  }
}

/// Tipos de contenido para validación
enum ContentType {
  message,
  groupName,
  groupDescription,
  nickname,
}

/// Resultado de validación de contenido
class ContentValidationResult {
  final bool isValid;
  final String? errorMessage;
  final String? sanitizedContent;

  ContentValidationResult._(this.isValid, this.errorMessage, this.sanitizedContent);

  factory ContentValidationResult.success(String content) {
    return ContentValidationResult._(true, null, content);
  }

  factory ContentValidationResult.error(String message) {
    return ContentValidationResult._(false, message, null);
  }

  @override
  String toString() {
    return isValid
        ? 'Valid: "${sanitizedContent?.substring(0, 50) ?? ''}"'
        : 'Invalid: $errorMessage';
  }
}

/// Estadísticas de contenido
class ContentStats {
  final int lines;
  final int words;
  final int characters;
  final int charactersNoSpaces;

  ContentStats({
    required this.lines,
    required this.words,
    required this.characters,
    required this.charactersNoSpaces,
  });

  @override
  String toString() {
    return 'Lines: $lines, Words: $words, Chars: $characters ($charactersNoSpaces no spaces)';
  }
}