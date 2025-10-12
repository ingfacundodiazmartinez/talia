import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/permission_service.dart';

void main() {
  group('PermissionService', () {
    late PermissionService service;

    setUp(() {
      service = PermissionService();
    });

    group('getGracefulDegradationMessage', () {
      test('provides alternative for camera permission', () {
        final message = service.getGracefulDegradationMessage(
          AppPermission.camera,
        );

        expect(message, isNotEmpty);
        expect(message, contains('galería'));
      });

      test('provides alternative for photos permission', () {
        final message = service.getGracefulDegradationMessage(
          AppPermission.photos,
        );

        expect(message, isNotEmpty);
        expect(message, contains('cámara'));
      });

      test('explains limitations for microphone permission', () {
        final message = service.getGracefulDegradationMessage(
          AppPermission.microphone,
        );

        expect(message, isNotEmpty);
        expect(message, contains('llamadas'));
      });

      test('explains limitations for location permission', () {
        final message = service.getGracefulDegradationMessage(
          AppPermission.location,
        );

        expect(message, isNotEmpty);
        expect(message, contains('ubicación'));
      });

      test('explains limitations for notifications permission', () {
        final message = service.getGracefulDegradationMessage(
          AppPermission.notifications,
        );

        expect(message, isNotEmpty);
        expect(message, contains('notificaciones'));
      });
    });

    group('isCritical', () {
      test('returns true for notifications permission', () {
        expect(service.isCritical(AppPermission.notifications), true);
      });

      test('returns true for location permission', () {
        expect(service.isCritical(AppPermission.location), true);
      });

      test('returns false for camera permission', () {
        expect(service.isCritical(AppPermission.camera), false);
      });

      test('returns false for photos permission', () {
        expect(service.isCritical(AppPermission.photos), false);
      });

      test('returns false for microphone permission', () {
        expect(service.isCritical(AppPermission.microphone), false);
      });

      test('returns false for contacts permission', () {
        expect(service.isCritical(AppPermission.contacts), false);
      });
    });

    group('isOptional', () {
      test('returns true for contacts permission', () {
        expect(service.isOptional(AppPermission.contacts), true);
      });

      test('returns false for camera permission', () {
        expect(service.isOptional(AppPermission.camera), false);
      });

      test('returns false for notifications permission', () {
        expect(service.isOptional(AppPermission.notifications), false);
      });

      test('returns false for location permission', () {
        expect(service.isOptional(AppPermission.location), false);
      });
    });

    group('AppPermission enum', () {
      test('has all expected permissions', () {
        expect(AppPermission.values.length, 7);
        expect(AppPermission.values, contains(AppPermission.camera));
        expect(AppPermission.values, contains(AppPermission.photos));
        expect(AppPermission.values, contains(AppPermission.microphone));
        expect(AppPermission.values, contains(AppPermission.location));
        expect(AppPermission.values, contains(AppPermission.locationAlways));
        expect(AppPermission.values, contains(AppPermission.contacts));
        expect(AppPermission.values, contains(AppPermission.notifications));
      });
    });

    group('PermissionResult enum', () {
      test('has all expected results', () {
        expect(PermissionResult.values.length, 5);
        expect(PermissionResult.values, contains(PermissionResult.granted));
        expect(PermissionResult.values, contains(PermissionResult.denied));
        expect(
            PermissionResult.values, contains(PermissionResult.permanentlyDenied));
        expect(PermissionResult.values, contains(PermissionResult.restricted));
        expect(PermissionResult.values, contains(PermissionResult.limited));
      });
    });

    group('Global accessor', () {
      test('returns singleton instance', () {
        final instance1 = permissions;
        final instance2 = permissions;

        expect(identical(instance1, instance2), true);
      });
    });
  });

  group('Permission Messages', () {
    test('camera permission has clear description', () {
      final service = PermissionService();
      final message = service.getGracefulDegradationMessage(
        AppPermission.camera,
      );

      // Verificar que el mensaje explica la alternativa
      expect(message.toLowerCase(), contains('galería'));
      expect(message.length, greaterThan(20)); // Mensaje sustancial
    });

    test('all permissions have degradation messages', () {
      final service = PermissionService();

      for (final permission in AppPermission.values) {
        final message = service.getGracefulDegradationMessage(permission);

        expect(message, isNotEmpty,
            reason: 'Permission $permission should have a degradation message');
        expect(message.length, greaterThan(15),
            reason:
                'Permission $permission degradation message should be substantial');
      }
    });
  });

  group('Permission Criticality', () {
    test('only notifications and location are critical', () {
      final service = PermissionService();
      final criticalPermissions = AppPermission.values
          .where((p) => service.isCritical(p))
          .toList();

      expect(criticalPermissions.length, 2);
      expect(criticalPermissions, contains(AppPermission.notifications));
      expect(criticalPermissions, contains(AppPermission.location));
    });

    test('only contacts is optional', () {
      final service = PermissionService();
      final optionalPermissions = AppPermission.values
          .where((p) => service.isOptional(p))
          .toList();

      expect(optionalPermissions.length, 1);
      expect(optionalPermissions, contains(AppPermission.contacts));
    });
  });
}
