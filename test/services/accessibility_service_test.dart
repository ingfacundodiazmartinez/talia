import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talia/services/accessibility_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AccessibilityService', () {
    late AccessibilityService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      service = AccessibilityService();
      await service.initialize();
    });

    test('initializes with default values', () {
      expect(service.textScale, 1.0);
      expect(service.highContrast, false);
      expect(service.reduceAnimations, false);
      expect(service.boldText, false);
    });

    test('setTextScale updates value within valid range', () async {
      await service.setTextScale(1.5);
      expect(service.textScale, 1.5);

      // Test clamping
      await service.setTextScale(2.5); // Above max
      expect(service.textScale, 2.0);

      await service.setTextScale(0.5); // Below min
      expect(service.textScale, 0.8);
    });

    test('setHighContrast updates value', () async {
      await service.setHighContrast(true);
      expect(service.highContrast, true);

      await service.setHighContrast(false);
      expect(service.highContrast, false);
    });

    test('setReduceAnimations updates value', () async {
      await service.setReduceAnimations(true);
      expect(service.reduceAnimations, true);
    });

    test('setBoldText updates value', () async {
      await service.setBoldText(true);
      expect(service.boldText, true);
    });

    test('getAnimationDuration returns zero when animations reduced', () async {
      await service.setReduceAnimations(true);
      final duration = service.getAnimationDuration(
        const Duration(milliseconds: 300),
      );
      expect(duration, Duration.zero);
    });

    test('getAnimationDuration returns normal duration when animations enabled', () async {
      await service.setReduceAnimations(false);
      final duration = service.getAnimationDuration(
        const Duration(milliseconds: 300),
      );
      expect(duration, const Duration(milliseconds: 300));
    });

    test('applyAccessibility applies text scale', () async {
      await service.setTextScale(1.5);
      final baseStyle = const TextStyle(fontSize: 16);
      final accessibleStyle = service.applyAccessibility(baseStyle);

      expect(accessibleStyle.fontSize, 16 * 1.5);
    });

    test('applyAccessibility applies bold text', () async {
      await service.setBoldText(true);
      final baseStyle = const TextStyle(fontSize: 16);
      final accessibleStyle = service.applyAccessibility(baseStyle);

      expect(accessibleStyle.fontWeight, FontWeight.bold);
    });

    test('hasGoodContrast detects good contrast', () {
      final hasGood = AccessibilityService.hasGoodContrast(
        Colors.black,
        Colors.white,
      );
      expect(hasGood, true);
    });

    test('hasGoodContrast detects poor contrast', () {
      final hasGood = AccessibilityService.hasGoodContrast(
        Colors.grey.shade400,
        Colors.grey.shade500,
      );
      expect(hasGood, false);
    });

    test('getHighContrastColors returns high contrast scheme', () async {
      await service.setHighContrast(true);
      final baseScheme = ColorScheme.light();
      final highContrastScheme = service.getHighContrastColors(baseScheme);

      // High contrast should have darker primary in light mode
      expect(
        highContrastScheme.primary.computeLuminance() <
            baseScheme.primary.computeLuminance(),
        true,
      );
    });

    test('resetToDefaults restores all values', () async {
      await service.setTextScale(1.8);
      await service.setHighContrast(true);
      await service.setReduceAnimations(true);
      await service.setBoldText(true);

      await service.resetToDefaults();

      expect(service.textScale, 1.0);
      expect(service.highContrast, false);
      expect(service.reduceAnimations, false);
      expect(service.boldText, false);
    });

    test('settings persist across instances', () async {
      await service.setTextScale(1.5);
      await service.setHighContrast(true);

      // Create new instance
      final newService = AccessibilityService();
      await newService.initialize();

      expect(newService.textScale, 1.5);
      expect(newService.highContrast, true);
    });
  });
}
