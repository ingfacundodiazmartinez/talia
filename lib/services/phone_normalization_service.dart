/// Servicio para normalizar números telefónicos al formato E.164 canónico.
///
/// Problema que resuelve:
/// En Argentina, los números móviles pueden escribirse con o sin el "9"
/// después del código de país:
/// - +5493875433442 (con 9) - FORMATO CANÓNICO E.164
/// - +543875433442 (sin 9)
///
/// Según Google libphonenumber, el formato E.164 canónico para
/// móviles argentinos DEBE incluir el "9": +549XXXXXXXXXX
///
/// Esto evita que un usuario pueda crear dos cuentas con el mismo número
/// ingresándolo con y sin el "9".
library;

import '../utils/release_logger.dart';

class PhoneNormalizationService {
  static final PhoneNormalizationService _instance = PhoneNormalizationService._internal();
  factory PhoneNormalizationService() => _instance;
  PhoneNormalizationService._internal();

  /// Normaliza un número telefónico al formato E.164 canónico.
  ///
  /// Para Argentina móvil, SIEMPRE incluye el "9" después del +54.
  ///
  /// Ejemplos Argentina:
  /// - "+54 387 5433442" -> "+5493875433442" (se agrega el 9)
  /// - "+54 9 387 5433442" -> "+5493875433442" (ya tiene el 9)
  /// - "387 5433442" -> "+5493875433442" (se agrega +549)
  ///
  /// [phone] - El número a normalizar (cualquier formato)
  /// [defaultCountryCode] - Código ISO del país por defecto (ej: 'AR')
  ///
  /// Returns: Número normalizado en formato E.164 canónico
  String normalizePhone(String phone, {String defaultCountryCode = 'AR'}) {
    if (phone.isEmpty) return '';

    // 1. Limpiar caracteres no numéricos (excepto +)
    String cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');

    // 2. Si no tiene código de país, agregarlo según el país por defecto
    if (!cleaned.startsWith('+')) {
      if (cleaned.startsWith('54')) {
        cleaned = '+$cleaned';
      } else if (cleaned.startsWith('0')) {
        // Formato local argentino con 0
        cleaned = '+54${cleaned.substring(1)}';
      } else if (defaultCountryCode.toUpperCase() == 'AR') {
        // Asumir que es número argentino
        if (cleaned.startsWith('9') && cleaned.length == 11) {
          // Ya tiene el 9 de móvil
          cleaned = '+54$cleaned';
        } else if (cleaned.length == 10) {
          // Es un móvil sin el 9
          cleaned = '+549$cleaned';
        } else {
          cleaned = '+54$cleaned';
        }
      }
    }

    // 3. Normalizar formato argentino - AGREGAR el 9 si no existe
    if (cleaned.startsWith('+54')) {
      String withoutCountryCode = cleaned.substring(3);

      // Si NO empieza con 9, agregarlo (asumiendo que es móvil)
      if (!withoutCountryCode.startsWith('9')) {
        // Solo si tiene 10 dígitos (longitud estándar de móviles argentinos sin el 9)
        if (withoutCountryCode.length == 10) {
          ReleaseLogger.log(
            '📱 [PhoneNormalization] Agregando 9 a número AR: +54$withoutCountryCode -> +549$withoutCountryCode',
            tag: 'PhoneNormalization',
          );
          return '+549$withoutCountryCode';
        }
      }

      return '+54$withoutCountryCode';
    }

    // 4. Si empieza con 54 sin +, agregar el + y normalizar
    if (cleaned.startsWith('54') && !cleaned.startsWith('+')) {
      return normalizePhone('+$cleaned', defaultCountryCode: defaultCountryCode);
    }

    return cleaned;
  }

  /// Genera múltiples variaciones posibles de un número para búsqueda.
  ///
  /// Útil para buscar contactos que podrían estar guardados en
  /// diferentes formatos en la base de datos o en contactos del dispositivo.
  ///
  /// Ejemplo para +5493875433442:
  /// - +5493875433442 (canónico con 9)
  /// - +543875433442 (sin 9)
  /// - 5493875433442 (sin +, con 9)
  /// - 543875433442 (sin +, sin 9)
  /// - 93875433442 (solo 9 + local)
  /// - 3875433442 (solo local)
  /// - 03875433442 (formato local con 0)
  List<String> generateVariations(String phone) {
    final normalized = normalizePhone(phone);
    final variations = <String>{normalized};

    if (normalized.isEmpty) return [];

    // Si es argentino con 9 (formato canónico)
    if (normalized.startsWith('+549')) {
      final localNumber = normalized.substring(4); // Sin +549

      // Variación SIN el 9 (formato alternativo)
      variations.add('+54$localNumber');

      // Variaciones sin +
      variations.add('549$localNumber'); // Con 9
      variations.add('54$localNumber'); // Sin 9

      // Variación solo número local
      variations.add('9$localNumber'); // Con 9
      variations.add(localNumber); // Solo local
      variations.add('0$localNumber'); // Formato local con 0
    }
    // Si es argentino sin 9 (lo normalizamos y generamos variaciones)
    else if (normalized.startsWith('+54')) {
      final localNumber = normalized.substring(3); // Sin +54

      // Variación CON el 9 (formato canónico)
      variations.add('+549$localNumber');

      // Variaciones sin +
      variations.add('54$localNumber');
      variations.add('549$localNumber');

      // Variación solo número local
      variations.add(localNumber);
      variations.add('9$localNumber');
      variations.add('0$localNumber');
    }
    // Otros países
    else if (normalized.startsWith('+')) {
      variations.add(normalized.substring(1)); // Sin +
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
