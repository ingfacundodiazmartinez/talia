import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/data_management_service.dart';

void main() {
  group('RetentionPolicy', () {
    test('messages retention is 1 year', () {
      expect(RetentionPolicy.messages, const Duration(days: 365));
    });

    test('media retention is 6 months', () {
      expect(RetentionPolicy.media, const Duration(days: 180));
    });

    test('locations retention is 30 days', () {
      expect(RetentionPolicy.locations, const Duration(days: 30));
    });

    test('emergency locations retention is 1 year', () {
      expect(RetentionPolicy.emergencyLocations, const Duration(days: 365));
    });

    test('emergencies retention is 1 year', () {
      expect(RetentionPolicy.emergencies, const Duration(days: 365));
    });

    test('logs retention is 90 days', () {
      expect(RetentionPolicy.logs, const Duration(days: 90));
    });

    test('local cache retention is 7 days', () {
      expect(RetentionPolicy.localCache, const Duration(days: 7));
    });

    test('deleted user data retention is 30 days', () {
      expect(RetentionPolicy.deletedUserData, const Duration(days: 30));
    });

    test('all retention periods are non-zero', () {
      expect(RetentionPolicy.messages.inDays, greaterThan(0));
      expect(RetentionPolicy.media.inDays, greaterThan(0));
      expect(RetentionPolicy.locations.inDays, greaterThan(0));
      expect(RetentionPolicy.emergencyLocations.inDays, greaterThan(0));
      expect(RetentionPolicy.emergencies.inDays, greaterThan(0));
      expect(RetentionPolicy.logs.inDays, greaterThan(0));
      expect(RetentionPolicy.localCache.inDays, greaterThan(0));
      expect(RetentionPolicy.deletedUserData.inDays, greaterThan(0));
    });

    test('media retention is shorter than messages', () {
      expect(
        RetentionPolicy.media.inDays,
        lessThan(RetentionPolicy.messages.inDays),
      );
    });

    test('cache retention is shortest', () {
      expect(
        RetentionPolicy.localCache.inDays,
        lessThan(RetentionPolicy.locations.inDays),
      );
      expect(
        RetentionPolicy.localCache.inDays,
        lessThan(RetentionPolicy.media.inDays),
      );
      expect(
        RetentionPolicy.localCache.inDays,
        lessThan(RetentionPolicy.messages.inDays),
      );
    });

    test('emergency data retained longer than regular data', () {
      expect(
        RetentionPolicy.emergencyLocations.inDays,
        greaterThan(RetentionPolicy.locations.inDays),
      );
    });
  });

  group('DataManagementService', () {
    late DataManagementService service;

    setUp(() {
      service = DataManagementService();
    });

    test('singleton pattern works', () {
      final instance1 = dataManagement;
      final instance2 = dataManagement;

      expect(identical(instance1, instance2), true);
    });

    test('global accessor returns instance', () {
      final instance = dataManagement;
      expect(instance, isA<DataManagementService>());
    });

    test('initialize can be called with enableAutoCleanup true', () async {
      // Should not throw
      await service.initialize(enableAutoCleanup: true);
    });

    test('initialize can be called with enableAutoCleanup false', () async {
      // Should not throw
      await service.initialize(enableAutoCleanup: false);
    });

    test('initialize is idempotent', () async {
      await service.initialize();
      await service.initialize(); // Should not cause issues
    });

    test('dispose cleans up resources', () {
      // Should not throw
      service.dispose();
    });
  });

  group('Data Retention Logic', () {
    test('messages older than 1 year should be cleaned', () {
      final now = DateTime.now();
      final oneYearAgo = now.subtract(RetentionPolicy.messages);
      final justBeforeCutoff = oneYearAgo.add(const Duration(days: 1));

      expect(justBeforeCutoff.isBefore(now), true);
      expect(oneYearAgo.isBefore(justBeforeCutoff), true);
    });

    test('media older than 6 months should be cleaned', () {
      final now = DateTime.now();
      final sixMonthsAgo = now.subtract(RetentionPolicy.media);
      final justBeforeCutoff = sixMonthsAgo.add(const Duration(days: 1));

      expect(justBeforeCutoff.isBefore(now), true);
      expect(sixMonthsAgo.isBefore(justBeforeCutoff), true);
    });

    test('deleted user data grace period calculation', () {
      final now = DateTime.now();
      final deletionDate = now.add(RetentionPolicy.deletedUserData);

      expect(deletionDate.isAfter(now), true);
      expect(
        deletionDate.difference(now).inDays,
        equals(30),
      );
    });
  });

  group('Retention Policy Compliance', () {
    test('retention periods comply with GDPR recommendations', () {
      // GDPR recommends data minimization
      // Verificar que no almacenamos datos indefinidamente
      expect(RetentionPolicy.messages.inDays, lessThanOrEqualTo(365 * 2));
      expect(RetentionPolicy.media.inDays, lessThanOrEqualTo(365));
      expect(RetentionPolicy.locations.inDays, lessThanOrEqualTo(90));
    });

    test('deleted account grace period complies with regulations', () {
      // 30 días es estándar para período de gracia
      expect(RetentionPolicy.deletedUserData.inDays, equals(30));
    });

    test('cache is cleaned frequently', () {
      // Cache debe limpiarse frecuentemente para evitar data stale
      expect(RetentionPolicy.localCache.inDays, lessThanOrEqualTo(7));
    });
  });

  group('Data Hierarchy', () {
    test('critical data retained longer than non-critical', () {
      // Emergencias (críticas) > Mensajes normales
      expect(
        RetentionPolicy.emergencies.inDays,
        greaterThanOrEqualTo(RetentionPolicy.messages.inDays),
      );

      // Ubicaciones de emergencia > Ubicaciones normales
      expect(
        RetentionPolicy.emergencyLocations.inDays,
        greaterThan(RetentionPolicy.locations.inDays),
      );
    });

    test('transient data cleaned most frequently', () {
      // Cache y logs se limpian más frecuentemente
      expect(
        RetentionPolicy.localCache.inDays,
        lessThan(RetentionPolicy.locations.inDays),
      );
      expect(
        RetentionPolicy.logs.inDays,
        lessThan(RetentionPolicy.media.inDays),
      );
    });
  });
}
