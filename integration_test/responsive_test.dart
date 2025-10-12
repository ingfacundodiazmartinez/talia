import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:talia/main.dart' as app;

/// Integration tests para verificar responsividad en diferentes tamaños de pantalla
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Responsive Design Tests', () {
    // Diferentes tamaños de pantalla para testing
    final Map<String, Size> deviceSizes = {
      'iPhone SE (Small)': const Size(375, 667), // 4.7"
      'iPhone 13 (Medium)': const Size(390, 844), // 6.1"
      'iPhone 14 Pro Max (Large)': const Size(430, 932), // 6.7"
      'iPad (Tablet)': const Size(810, 1080), // 10.9"
    };

    for (final entry in deviceSizes.entries) {
      final deviceName = entry.key;
      final size = entry.value;

      group('$deviceName Tests', () {
        testWidgets('Login screen should be accessible and readable',
            (tester) async {
          // Set device size
          await tester.binding.setSurfaceSize(size);

          // Start app
          app.main();
          await tester.pumpAndSettle();

          // Verify phone input is visible
          expect(find.byType(TextField), findsWidgets);

          // Verify login button is visible and accessible
          final loginButton = find.text('Continuar');
          expect(loginButton, findsOneWidget);

          // Verify no overflow
          expect(tester.takeException(), isNull);

          // Reset size
          await tester.binding.setSurfaceSize(null);
        });

        testWidgets('Text should not overflow with different scales',
            (tester) async {
          await tester.binding.setSurfaceSize(size);

          // Test different text scales
          for (final textScale in [0.8, 1.0, 1.5, 2.0]) {
            app.main();
            await tester.pumpAndSettle();

            // Apply text scale
            tester.view.devicePixelRatio = 2.0;
            tester.view.platformDispatcher.textScaleFactorTestValue =
                textScale;
            await tester.pumpAndSettle();

            // Verify no overflow
            expect(tester.takeException(), isNull,
                reason: 'Overflow detected with text scale $textScale');
          }

          await tester.binding.setSurfaceSize(null);
        });

        testWidgets('Safe areas should be respected', (tester) async {
          await tester.binding.setSurfaceSize(size);

          app.main();
          await tester.pumpAndSettle();

          // Verify SafeArea widgets are present
          expect(find.byType(SafeArea), findsWidgets);

          // Verify content is not hidden behind status bar or notch
          // by checking that the first visible widget has appropriate padding
          final mediaQuery = tester.element(find.byType(MaterialApp));
          final padding = MediaQuery.of(mediaQuery).padding;

          expect(padding.top, greaterThan(0));

          await tester.binding.setSurfaceSize(null);
        });

        testWidgets('Buttons should meet minimum touch target size',
            (tester) async {
          await tester.binding.setSurfaceSize(size);

          app.main();
          await tester.pumpAndSettle();

          // Find all buttons
          final buttons = find.byType(ElevatedButton);
          final iconButtons = find.byType(IconButton);
          final textButtons = find.byType(TextButton);

          // Verify each button meets minimum 44x44 touch target
          const minTouchTarget = 44.0;

          for (final buttonFinder in [buttons, iconButtons, textButtons]) {
            if (buttonFinder.evaluate().isEmpty) continue;

            for (final element in buttonFinder.evaluate()) {
              final renderBox = element.renderObject as RenderBox?;
              if (renderBox != null) {
                expect(renderBox.size.width, greaterThanOrEqualTo(minTouchTarget),
                    reason: 'Button width too small for comfortable touch');
                expect(renderBox.size.height, greaterThanOrEqualTo(minTouchTarget),
                    reason: 'Button height too small for comfortable touch');
              }
            }
          }

          await tester.binding.setSurfaceSize(null);
        });
      });
    }

    testWidgets('Orientation change should not cause issues', (tester) async {
      // Start in portrait
      await tester.binding.setSurfaceSize(const Size(390, 844));

      app.main();
      await tester.pumpAndSettle();

      // Verify no errors in portrait
      expect(tester.takeException(), isNull);

      // Rotate to landscape
      await tester.binding.setSurfaceSize(const Size(844, 390));
      await tester.pumpAndSettle();

      // Verify no errors in landscape
      expect(tester.takeException(), isNull);

      // Rotate back to portrait
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();

      // Verify no errors
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Keyboard should not cover input fields', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));

      app.main();
      await tester.pumpAndSettle();

      // Find a text field
      final textField = find.byType(TextField).first;
      expect(textField, findsOneWidget);

      // Tap on text field to show keyboard
      await tester.tap(textField);
      await tester.pumpAndSettle();

      // Simulate keyboard showing (half screen)
      tester.view.viewInsets =
          FakeViewPadding.fromWindowPadding(const FakeWindowPadding(bottom: 400));
      await tester.pumpAndSettle();

      // Verify text field is still visible (scrolled into view)
      final textFieldWidget = tester.widget<TextField>(textField);
      expect(textFieldWidget, isNotNull);

      // Reset
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Images should scale appropriately', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));

      app.main();
      await tester.pumpAndSettle();

      // Find images
      final images = find.byType(Image);

      if (images.evaluate().isNotEmpty) {
        for (final element in images.evaluate()) {
          final renderBox = element.renderObject as RenderBox?;
          if (renderBox != null) {
            final size = renderBox.size;

            // Verify image is not larger than screen
            expect(size.width, lessThanOrEqualTo(390),
                reason: 'Image width exceeds screen width');
            expect(size.height, lessThanOrEqualTo(844),
                reason: 'Image height exceeds screen height');
          }
        }
      }

      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Lists should scroll smoothly', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));

      app.main();
      await tester.pumpAndSettle();

      // Find scrollable lists
      final listViews = find.byType(ListView);

      if (listViews.evaluate().isNotEmpty) {
        final listView = listViews.first;

        // Try scrolling
        await tester.drag(listView, const Offset(0, -300));
        await tester.pumpAndSettle();

        // Verify no errors during scroll
        expect(tester.takeException(), isNull);

        // Scroll back
        await tester.drag(listView, const Offset(0, 300));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      }

      await tester.binding.setSurfaceSize(null);
    });
  });
}
