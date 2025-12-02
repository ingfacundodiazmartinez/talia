import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/phone_normalization_service.dart';

/// Test para verificar que PhoneNormalizationService maneja correctamente
/// el "9" de Argentina para números móviles.
///
/// El objetivo es que tanto +5493875433442 como +543875433442
/// se normalicen al MISMO formato canónico E.164: +5493875433442
void main() {
  late PhoneNormalizationService service;

  setUp(() {
    service = PhoneNormalizationService();
  });

  group('Argentina Phone Number Normalization - Mobile "9" prefix', () {
    test('Números con y sin "9" deben normalizarse al mismo formato', () {
      // Tu número con el 9
      const phoneWith9 = '+5493875433442';
      // Tu número sin el 9
      const phoneWithout9 = '+543875433442';

      final normalizedWith9 = service.normalizePhone(phoneWith9);
      final normalizedWithout9 = service.normalizePhone(phoneWithout9);

      print('=== PRUEBA DE NORMALIZACIÓN ARGENTINA ===');
      print('');
      print('Input con 9:    $phoneWith9');
      print('Input sin 9:    $phoneWithout9');
      print('');
      print('Normalizado con 9:    $normalizedWith9');
      print('Normalizado sin 9:    $normalizedWithout9');
      print('¿Son iguales?: ${normalizedWith9 == normalizedWithout9}');

      // Este es el test crítico - AMBOS deben ser iguales
      expect(
        normalizedWith9,
        equals(normalizedWithout9),
        reason: 'Ambos números deberían normalizarse al mismo formato E.164 canónico',
      );

      // El formato canónico DEBE ser con el 9
      expect(
        normalizedWith9,
        equals('+5493875433442'),
        reason: 'El formato canónico para móviles AR debe incluir el 9',
      );
    });

    test('Verificar normalización de múltiples formatos argentinos', () {
      // Todos estos formatos deberían normalizarse a +5493875433442
      final testCases = {
        '+5493875433442': '+5493875433442', // Ya tiene el 9
        '+543875433442': '+5493875433442', // Sin 9, se agrega
        '5493875433442': '+5493875433442', // Sin +, con 9
        '543875433442': '+5493875433442', // Sin +, sin 9
        '03875433442': '+5493875433442', // Formato local con 0
        '3875433442': '+5493875433442', // Solo número local
        '93875433442': '+5493875433442', // Con 9 pero sin código país
        '+54 9 387 5433442': '+5493875433442', // Con espacios
        '+54-9-387-5433442': '+5493875433442', // Con guiones
      };

      print('\n=== PRUEBA DE MÚLTIPLES FORMATOS ===\n');

      for (final entry in testCases.entries) {
        final input = entry.key;
        final expected = entry.value;
        final normalized = service.normalizePhone(input);

        print('Input: "$input"');
        print('  -> Normalizado: $normalized');
        print('  -> Esperado: $expected');
        print('  -> ¿Correcto?: ${normalized == expected}');
        print('');

        expect(
          normalized,
          equals(expected),
          reason: 'El formato "$input" debería normalizarse a "$expected"',
        );
      }
    });

    test('arePhoneNumbersEqual debe detectar números equivalentes', () {
      const phoneWith9 = '+5493875433442';
      const phoneWithout9 = '+543875433442';
      const localFormat = '3875433442';
      const withSpaces = '+54 9 387 543-3442';

      // Todas las combinaciones deben ser iguales
      expect(service.arePhoneNumbersEqual(phoneWith9, phoneWithout9), isTrue);
      expect(service.arePhoneNumbersEqual(phoneWith9, localFormat), isTrue);
      expect(service.arePhoneNumbersEqual(phoneWithout9, localFormat), isTrue);
      expect(service.arePhoneNumbersEqual(phoneWith9, withSpaces), isTrue);

      // Números diferentes deben ser diferentes
      expect(service.arePhoneNumbersEqual(phoneWith9, '+5491155551234'), isFalse);
    });

    test('generateVariations debe incluir todas las variaciones posibles', () {
      const phone = '+5493875433442';
      final variations = service.generateVariations(phone);

      print('\n=== VARIACIONES GENERADAS ===');
      print('Input: $phone');
      print('Variaciones:');
      for (final v in variations) {
        print('  - $v');
      }

      // Debe incluir las variaciones más comunes
      expect(variations, contains('+5493875433442')); // Con 9
      expect(variations, contains('+543875433442')); // Sin 9
      expect(variations, contains('5493875433442')); // Sin +, con 9
      expect(variations, contains('543875433442')); // Sin +, sin 9
      expect(variations, contains('3875433442')); // Solo local
      expect(variations, contains('03875433442')); // Formato local con 0
    });

    test('Números de otros países no deben modificarse', () {
      // USA
      expect(
        service.normalizePhone('+14155551234', defaultCountryCode: 'US'),
        equals('+14155551234'),
      );

      // México
      expect(
        service.normalizePhone('+525512345678', defaultCountryCode: 'MX'),
        equals('+525512345678'),
      );

      // España
      expect(
        service.normalizePhone('+34612345678', defaultCountryCode: 'ES'),
        equals('+34612345678'),
      );
    });

    test('Números fijos argentinos (menos de 10 dígitos) no agregan el 9', () {
      // Los números fijos tienen menos de 10 dígitos en Argentina
      // Por ejemplo, número fijo de Buenos Aires: 11-4567-8901 (9 dígitos)
      const fixedLine = '+54114567890'; // 9 dígitos

      final normalized = service.normalizePhone(fixedLine);

      print('\n=== NÚMERO FIJO ===');
      print('Input: $fixedLine');
      print('Normalizado: $normalized');

      // No debería agregar el 9 porque no tiene 10 dígitos
      expect(normalized, equals('+54114567890'));
      expect(normalized, isNot(contains('+549')));
    });
  });
}
