/// Utilidades para el manejo seguro de strings
class StringUtils {
  /// Sanitiza un string para prevenir errores de UTF-16
  ///
  /// Elimina caracteres inválidos y surrogates mal formados
  /// que pueden causar el error "string is not well-formed UTF-16"
  static String sanitize(String? input) {
    if (input == null || input.isEmpty) {
      return '';
    }

    try {
      // Intentar crear una lista de runes para validar la codificación
      final runes = input.runes.toList();

      // Reconstruir el string desde runes válidos
      return String.fromCharCodes(runes);
    } catch (e) {
      // Si falla, eliminar caracteres problemáticos
      return input.replaceAll(RegExp(r'[\uD800-\uDFFF]'), '�');
    }
  }

  /// Sanitiza un string y provee un valor por defecto si está vacío
  static String sanitizeWithDefault(String? input, String defaultValue) {
    final sanitized = sanitize(input);
    return sanitized.isEmpty ? defaultValue : sanitized;
  }
}
