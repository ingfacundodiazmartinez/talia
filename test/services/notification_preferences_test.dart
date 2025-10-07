import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:talia/services/notification_preferences_service.dart';

@GenerateMocks([FirebaseFirestore, FirebaseAuth])
import 'notification_preferences_test.mocks.dart';

void main() {
  late NotificationPreferencesService service;
  late MockFirebaseFirestore mockFirestore;
  late MockFirebaseAuth mockAuth;

  setUp(() {
    mockFirestore = MockFirebaseFirestore();
    mockAuth = MockFirebaseAuth();
    service = NotificationPreferencesService(
      firestore: mockFirestore,
      auth: mockAuth,
    );
  });

  group('NotificationPreferencesService - Do Not Disturb Logic', () {
    test('Debe detectar período DND en mismo día (10:00 - 12:00)', () {
      // Arrange
      final current = TimeOfDay(hour: 11, minute: 0);
      final start = TimeOfDay(hour: 10, minute: 0);
      final end = TimeOfDay(hour: 12, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, true);
    });

    test('Debe detectar fuera de período DND en mismo día', () {
      // Arrange
      final current = TimeOfDay(hour: 13, minute: 0);
      final start = TimeOfDay(hour: 10, minute: 0);
      final end = TimeOfDay(hour: 12, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, false);
    });

    test('Debe detectar período DND que cruza medianoche (22:00 - 07:00) - noche', () {
      // Arrange
      final current = TimeOfDay(hour: 23, minute: 30);
      final start = TimeOfDay(hour: 22, minute: 0);
      final end = TimeOfDay(hour: 7, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, true);
    });

    test('Debe detectar período DND que cruza medianoche (22:00 - 07:00) - madrugada', () {
      // Arrange
      final current = TimeOfDay(hour: 5, minute: 30);
      final start = TimeOfDay(hour: 22, minute: 0);
      final end = TimeOfDay(hour: 7, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, true);
    });

    test('Debe detectar fuera de período DND que cruza medianoche', () {
      // Arrange
      final current = TimeOfDay(hour: 15, minute: 0);
      final start = TimeOfDay(hour: 22, minute: 0);
      final end = TimeOfDay(hour: 7, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, false);
    });

    test('Debe manejar hora exacta de inicio', () {
      // Arrange
      final current = TimeOfDay(hour: 22, minute: 0);
      final start = TimeOfDay(hour: 22, minute: 0);
      final end = TimeOfDay(hour: 7, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, true);
    });

    test('Debe manejar hora exacta de fin (no incluida)', () {
      // Arrange
      final current = TimeOfDay(hour: 7, minute: 0);
      final start = TimeOfDay(hour: 22, minute: 0);
      final end = TimeOfDay(hour: 7, minute: 0);

      // Act
      final isInPeriod = service.isInDoNotDisturbPeriod(current, start, end);

      // Assert
      expect(isInPeriod, false); // Fin es exclusivo
    });
  });

  group('NotificationPreferencesService - Parse Time', () {
    test('Debe parsear correctamente formato HH:mm', () {
      // Act
      final time = service.parseTime('14:30');

      // Assert
      expect(time.hour, 14);
      expect(time.minute, 30);
    });

    test('Debe parsear correctamente con ceros a la izquierda', () {
      // Act
      final time = service.parseTime('09:05');

      // Assert
      expect(time.hour, 9);
      expect(time.minute, 5);
    });
  });

  group('NotificationPreferencesService - Default Preferences', () {
    test('Debe retornar preferencias por defecto correctas', () {
      // Act
      final defaults = service.defaultPreferences();

      // Assert
      expect(defaults['messagesEnabled'], true);
      expect(defaults['contactRequestsEnabled'], true);
      expect(defaults['soundEnabled'], true);
      expect(defaults['vibrationEnabled'], true);
      expect(defaults['doNotDisturbEnabled'], false);
      expect(defaults['dndExceptions'], []);
    });
  });
}
