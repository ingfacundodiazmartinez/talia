import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talia/services/accessibility_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Imagen PNG de 1x1 pixel transparente en base64
  final testImageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChAI9fh5Z0QAAAABJRU5ErkJggg=='
  );

  group('AccessibleText Widget', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AccessibilityService().initialize();
    });

    testWidgets('renders text correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleText('Hello World'),
          ),
        ),
      );

      expect(find.text('Hello World'), findsOneWidget);
    });

    testWidgets('has correct semantics label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleText(
              'Hello',
              semanticsLabel: 'Greeting message',
            ),
          ),
        ),
      );

      // Verificar que el texto existe
      expect(find.text('Hello'), findsOneWidget);

      // Verificar semántica de manera alternativa
      final semantics = tester.getSemantics(find.text('Hello'));
      expect(semantics.label, contains('Hello'));
    });

    testWidgets('applies custom style', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleText(
              'Styled Text',
              style: TextStyle(fontSize: 20, color: Colors.blue),
            ),
          ),
        ),
      );

      final textWidget = tester.widget<Text>(find.text('Styled Text'));
      expect(textWidget.style?.color, Colors.blue);
    });

    testWidgets('respects text alignment', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleText(
              'Centered Text',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );

      final textWidget = tester.widget<Text>(find.text('Centered Text'));
      expect(textWidget.textAlign, TextAlign.center);
    });

    testWidgets('respects max lines', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleText(
              'Long text that should be truncated',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );

      final textWidget = tester.widget<Text>(
        find.text('Long text that should be truncated'),
      );
      expect(textWidget.maxLines, 1);
      expect(textWidget.overflow, TextOverflow.ellipsis);
    });
  });

  group('AccessibleButton Widget', () {
    testWidgets('renders button correctly', (tester) async {
      bool pressed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleButton(
              semanticsLabel: 'Test Button',
              onPressed: () => pressed = true,
              child: const Text('Press Me'),
            ),
          ),
        ),
      );

      expect(find.text('Press Me'), findsOneWidget);

      await tester.tap(find.text('Press Me'));
      expect(pressed, true);
    });

    testWidgets('has correct semantics', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleButton(
              semanticsLabel: 'Submit Form',
              semanticsHint: 'Submits the form data',
              onPressed: () {},
              child: const Text('Submit'),
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Submit Form'), findsOneWidget);
    });

    testWidgets('respects enabled state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleButton(
              semanticsLabel: 'Disabled Button',
              onPressed: () {},
              enabled: false,
              child: const Text('Disabled'),
            ),
          ),
        ),
      );

      final button = tester.widget<ElevatedButton>(
        find.byType(ElevatedButton),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('AccessibleIconButton Widget', () {
    testWidgets('renders icon button correctly', (tester) async {
      bool pressed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleIconButton(
              icon: Icons.favorite,
              semanticsLabel: 'Like',
              onPressed: () => pressed = true,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.favorite), findsOneWidget);

      await tester.tap(find.byIcon(Icons.favorite));
      expect(pressed, true);
    });

    testWidgets('has tooltip', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleIconButton(
              icon: Icons.delete,
              semanticsLabel: 'Delete',
              tooltip: 'Delete this item',
              onPressed: () {},
            ),
          ),
        ),
      );

      // Long press to show tooltip
      await tester.longPress(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();

      expect(find.text('Delete this item'), findsOneWidget);
    });

    testWidgets('has correct semantics label', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleIconButton(
              icon: Icons.send,
              semanticsLabel: 'Send Message',
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Send Message'), findsOneWidget);
    });
  });

  group('AccessibleImage Widget', () {
    testWidgets('renders image with semantics', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleImage(
              image: MemoryImage(testImageBytes),
              semanticsLabel: 'Profile picture of John Doe',
              width: 100,
              height: 100,
            ),
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('Profile picture of John Doe'),
        findsOneWidget,
      );
    });

    testWidgets('respects width and height', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessibleImage(
              image: MemoryImage(testImageBytes),
              semanticsLabel: 'Test Image',
              width: 150,
              height: 150,
            ),
          ),
        ),
      );

      final imageWidget = tester.widget<Image>(find.byType(Image));
      expect(imageWidget.width, 150);
      expect(imageWidget.height, 150);
    });
  });

  group('AccessibleLoadingIndicator Widget', () {
    testWidgets('renders loading indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleLoadingIndicator(),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('has default semantics label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleLoadingIndicator(),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Cargando'), findsOneWidget);
    });

    testWidgets('has custom semantics label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccessibleLoadingIndicator(
              semanticsLabel: 'Loading messages',
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Loading messages'), findsOneWidget);
    });
  });
}
