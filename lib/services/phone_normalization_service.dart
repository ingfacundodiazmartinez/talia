/// Servicio para normalizar números telefónicos
///
/// Maneja diferentes formatos de números, especialmente para Argentina
/// donde pueden existir variaciones con/sin el "9" de celular
library;

class PhoneNormalizationService {
  static final PhoneNormalizationService _instance = PhoneNormalizationService._internal();
  factory PhoneNormalizationService() => _instance;
  PhoneNormalizationService._internal();

  /// Normaliza un número telefónico para comparación
  ///
  /// Ejemplos Argentina:
  /// - "+54 9 387 5433442" -> "+543875433442"
  /// - "+54 387 5433442" -> "+543875433442"
  /// - "+54 9 11 5433442" -> "+54115433442"
  /// - "387 5433442" -> "3875433442"
  ///
  /// Estrategia:
  /// 1. Remover espacios, guiones, paréntesis
  /// 2. Si tiene código de país argentino (+54), remover el 9 si existe
  /// 3. Mantener el + al inicio si existe
  String normalizePhone(String phone) {
    if (phone.isEmpty) return '';

    // 1. Limpiar caracteres no numéricos (excepto +)
    String cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');

    // 2. Normalizar formato argentino
    if (cleaned.startsWith('+54')) {
      // Extraer código de país
      String withoutCountryCode = cleaned.substring(3);

      // Si empieza con 9, removerlo (es el prefijo de celular)
      if (withoutCountryCode.startsWith('9')) {
        withoutCountryCode = withoutCountryCode.substring(1);
      }

      return '+54$withoutCountryCode';
    }

    // 3. Si empieza con 54 sin +, agregar el +
    if (cleaned.startsWith('54') && !cleaned.startsWith('+')) {
      String withoutCountryCode = cleaned.substring(2);

      if (withoutCountryCode.startsWith('9')) {
        withoutCountryCode = withoutCountryCode.substring(1);
      }

      return '+54$withoutCountryCode';
    }

    return cleaned;
  }

  /// Genera múltiples variaciones posibles de un número
  ///
  /// Útil para buscar en base de datos con diferentes formatos
  List<String> generateVariations(String phone) {
    final normalized = normalizePhone(phone);
    final variations = <String>{normalized};

    // Si es argentino, agregar variación con 9
    if (normalized.startsWith('+54')) {
      final withoutCode = normalized.substring(3);

      // Variación con 9
      variations.add('+549$withoutCode');

      // Variaciones sin +
      variations.add('54$withoutCode');
      variations.add('549$withoutCode');

      // Variación solo número local
      variations.add(withoutCode);
      variations.add('9$withoutCode');
    }

    return variations.toList();
  }

  /// Compara dos números telefónicos normalizados
  bool arePhoneNumbersEqual(String phone1, String phone2) {
    final normalized1 = normalizePhone(phone1);
    final normalized2 = normalizePhone(phone2);

    return normalized1 == normalized2;
  }

  /// Formatea un número para mostrar
  ///
  /// Argentina: +54 9 387 543-3442
  String formatForDisplay(String phone) {
    final normalized = normalizePhone(phone);

    // Formato argentino
    if (normalized.startsWith('+54')) {
      final withoutCode = normalized.substring(3);

      if (withoutCode.length >= 10) {
        // +54 9 387 543-3442
        final areaCode = withoutCode.substring(0, 3);
        final firstPart = withoutCode.substring(3, 6);
        final lastPart = withoutCode.substring(6);

        return '+54 9 $areaCode $firstPart-$lastPart';
      }

      return '+54 9 $withoutCode';
    }

    return normalized;
  }

  /// Detecta el país del número
  String? detectCountry(String phone) {
    final normalized = normalizePhone(phone);

    if (normalized.startsWith('+54')) return 'AR';
    if (normalized.startsWith('+1')) return 'US';
    if (normalized.startsWith('+52')) return 'MX';
    if (normalized.startsWith('+34')) return 'ES';
    if (normalized.startsWith('+55')) return 'BR';
    if (normalized.startsWith('+56')) return 'CL';
    if (normalized.startsWith('+57')) return 'CO';
    if (normalized.startsWith('+58')) return 'VE';
    if (normalized.startsWith('+51')) return 'PE';
    if (normalized.startsWith('+598')) return 'UY';

    return null;
  }

  /// Valida si un número tiene formato válido
  bool isValidPhone(String phone) {
    if (phone.isEmpty) return false;

    final normalized = normalizePhone(phone);

    // Debe tener al menos 8 dígitos (sin contar el +)
    final digitsOnly = normalized.replaceAll('+', '');
    if (digitsOnly.length < 8) return false;

    // Si tiene código de país, debe empezar con +
    if (phone.contains('+') && !normalized.startsWith('+')) {
      return false;
    }

    return true;
  }

  /// Extrae información del número
  PhoneInfo getPhoneInfo(String phone) {
    final normalized = normalizePhone(phone);
    final country = detectCountry(phone);
    final isValid = isValidPhone(phone);
    final displayFormat = formatForDisplay(phone);
    final variations = generateVariations(phone);

    return PhoneInfo(
      original: phone,
      normalized: normalized,
      country: country,
      isValid: isValid,
      displayFormat: displayFormat,
      variations: variations,
    );
  }
}

/// Información de un número telefónico
class PhoneInfo {
  final String original;
  final String normalized;
  final String? country;
  final bool isValid;
  final String displayFormat;
  final List<String> variations;

  PhoneInfo({
    required this.original,
    required this.normalized,
    required this.country,
    required this.isValid,
    required this.displayFormat,
    required this.variations,
  });

  @override
  String toString() {
    return 'PhoneInfo(original: $original, normalized: $normalized, country: $country, isValid: $isValid)';
  }
}

/// Global accessor
PhoneNormalizationService get phoneNormalizer => PhoneNormalizationService();
