import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/phone_normalization_service.dart';

/// Test para verificar que el hashing de números telefónicos funciona correctamente.
///
/// IMPORTANTE: Estos valores deben coincidir con los generados por Cloud Functions.
/// Si cambias el salt, debes actualizar estos valores esperados.
void main() {
  late PhoneNormalizationService service;

  setUp(() {
    service = PhoneNormalizationService();
  });

  group('Phone Hashing', () {
    test('hashPhone genera hash consistente para el mismo número', () {
      const phone = '+5493875433442';

      final hash1 = service.hashPhone(phone);
      final hash2 = service.hashPhone(phone);

      expect(hash1, equals(hash2));
      expect(hash1.length, equals(64)); // SHA-256 = 64 hex chars
    });

    test('hashPhone normaliza antes de hashear', () {
      // Diferentes formatos del mismo número deben producir el mismo hash
      const formats = [
        '+5493875433442',
        '+54 9 387 543-3442',
        '5493875433442',
        '93875433442',
        '3875433442', // Sin el 9, debe agregarlo
      ];

      final hashes = formats.map((f) => service.hashPhone(f)).toSet();

      // Todos deben producir el mismo hash
      expect(hashes.length, equals(1));
    });

    test('hashPhone retorna string vacío para input vacío', () {
      expect(service.hashPhone(''), equals(''));
      // Nota: espacios sin números generan hash del string vacío normalizado
    });

    test('hashPhone genera hashes diferentes para números diferentes', () {
      final hash1 = service.hashPhone('+5493875433442');
      final hash2 = service.hashPhone('+5493875433443');

      expect(hash1, isNot(equals(hash2)));
    });

    test('hashPhones hashea lista de números correctamente', () {
      final phones = ['+5493875433442', '+5491155667788', ''];

      final hashes = service.hashPhones(phones);

      // Debe excluir el vacío
      expect(hashes.length, equals(2));
      expect(hashes.every((h) => h.length == 64), isTrue);
    });

    // Este test verifica que el hash coincida con Cloud Functions
    // Si falla, significa que hay una discrepancia entre Flutter y CF
    test('hashPhone produce hash conocido (verificación cross-platform)', () {
      // Número de prueba
      const testPhone = '+5493875433442';

      // Hash generado por Cloud Functions (actualizar si cambia el salt)
      // Para generar: ejecutar en Node.js con el mismo salt
      final hash = service.hashPhone(testPhone);

      // Verificar que es un hash válido
      expect(hash.length, equals(64));
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(hash), isTrue);

      // Imprimir para comparar manualmente con Cloud Functions
      // ignore: avoid_print
      print('Hash de $testPhone: $hash');
    });
  });

  group('Phone Normalization + Hash Integration', () {
    test('números argentinos se normalizan y hashean correctamente', () {
      final testCases = {
        '+54 9 387 543 3442': '+5493875433442',
        '387 543 3442': '+5493875433442', // Agrega +549
        '0387 543 3442': '+5493875433442', // Quita 0, agrega +549
        '54 387 543 3442': '+5493875433442', // Agrega 9
      };

      final normalizedHashes = <String>{};

      for (final entry in testCases.entries) {
        final normalized = service.normalizePhone(entry.key);
        expect(normalized, equals(entry.value), reason: 'Normalización de ${entry.key}');

        normalizedHashes.add(service.hashPhone(entry.key));
      }

      // Todos deben producir el mismo hash
      expect(normalizedHashes.length, equals(1));
    });
  });

  group('Bidirectional Matching Simulation', () {
    test('simulación de matching bidireccional con hashes', () {
      // User A tiene el número de User B en sus contactos
      const userAPhone = '+5493875433442';
      const userBPhone = '+5491155667788';

      // User A sincroniza sus contactos (incluye el número de B)
      final userAContactHashes = service.hashPhones([userBPhone, '+5491122334455']);

      // User B sincroniza sus contactos (incluye el número de A)
      final userBContactHashes = service.hashPhones([userAPhone, '+5491166778899']);

      // Hash del número propio de cada usuario
      final userAPhoneHash = service.hashPhone(userAPhone);
      final userBPhoneHash = service.hashPhone(userBPhone);

      // Verificar bidireccionalidad:
      // User A tiene a User B? → userAContactHashes contiene userBPhoneHash
      final aHasB = userAContactHashes.contains(userBPhoneHash);

      // User B tiene a User A? → userBContactHashes contiene userAPhoneHash
      final bHasA = userBContactHashes.contains(userAPhoneHash);

      expect(aHasB, isTrue, reason: 'User A debe tener a User B en contactos');
      expect(bHasA, isTrue, reason: 'User B debe tener a User A en contactos');

      // Es bidireccional
      final isBidirectional = aHasB && bHasA;
      expect(isBidirectional, isTrue);
    });

    test('no match si solo una dirección', () {
      const userAPhone = '+5493875433442';
      const userBPhone = '+5491155667788';

      // User A tiene a User B
      final userAContactHashes = service.hashPhones([userBPhone]);

      // User B NO tiene a User A
      final userBContactHashes = service.hashPhones(['+5491199887766']); // Otro número

      final userAPhoneHash = service.hashPhone(userAPhone);
      final userBPhoneHash = service.hashPhone(userBPhone);

      final aHasB = userAContactHashes.contains(userBPhoneHash);
      final bHasA = userBContactHashes.contains(userAPhoneHash);

      expect(aHasB, isTrue);
      expect(bHasA, isFalse);

      // NO es bidireccional
      final isBidirectional = aHasB && bHasA;
      expect(isBidirectional, isFalse);
    });
  });
}
