import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Helpers comunes para tests

/// Inicializa mocks necesarios para tests
Future<void> initializeTestEnvironment() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
}

/// Crea un MaterialApp de prueba con configuración básica
Widget createTestApp(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: child,
    ),
  );
}

/// Crea un MaterialApp con navegación
Widget createTestAppWithNavigation({
  required Widget home,
  Map<String, WidgetBuilder>? routes,
}) {
  return MaterialApp(
    home: home,
    routes: routes ?? {},
  );
}

/// Espera a que se complete una animación
Future<void> waitForAnimation(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

/// Encuentra un widget por su semantics label
Finder findBySemanticsLabel(String label) {
  return find.bySemanticsLabel(label);
}

/// Verifica que un widget tenga buena accesibilidad
void verifyAccessibility(WidgetTester tester) {
  // Verificar que todos los botones tengan labels
  final buttons = find.byType(IconButton);
  for (final button in tester.widgetList(buttons)) {
    final semantics = tester.getSemantics(find.byWidget(button as Widget));
    expect(semantics.label, isNotNull, reason: 'Button should have a label');
  }
}

/// Mock de usuario de Firebase Auth
class MockUser {
  final String uid;
  final String? email;
  final String? phoneNumber;

  MockUser({
    required this.uid,
    this.email,
    this.phoneNumber,
  });
}

/// Mock de documento de Firestore
class MockFirestoreDoc {
  final String id;
  final Map<String, dynamic> data;

  MockFirestoreDoc({
    required this.id,
    required this.data,
  });
}

/// Helper para crear datos de prueba
class TestDataFactory {
  static Map<String, dynamic> createUserProfile({
    String? displayName,
    String? email,
    String? photoURL,
  }) {
    return {
      'displayName': displayName ?? 'Test User',
      'email': email ?? 'test@example.com',
      'photoURL': photoURL ?? 'https://example.com/photo.jpg',
      'role': 'child',
      'createdAt': DateTime.now().toIso8601String(),
    };
  }

  static Map<String, dynamic> createMessage({
    String? text,
    String? senderId,
    bool? read,
  }) {
    return {
      'text': text ?? 'Test message',
      'senderId': senderId ?? 'user123',
      'timestamp': DateTime.now().toIso8601String(),
      'read': read ?? false,
    };
  }

  static Map<String, dynamic> createChat({
    String? chatId,
    List<String>? participants,
  }) {
    return {
      'id': chatId ?? 'chat123',
      'participants': participants ?? ['user1', 'user2'],
      'lastMessage': 'Hello',
      'lastMessageTime': DateTime.now().toIso8601String(),
      'unreadCount': 0,
    };
  }
}

/// Matchers personalizados

/// Verifica que un color tenga buen contraste con otro
class HasGoodContrast extends Matcher {
  final Color background;

  const HasGoodContrast(this.background);

  @override
  bool matches(dynamic item, Map matchState) {
    if (item is! Color) return false;

    final luminance1 = item.computeLuminance();
    final luminance2 = background.computeLuminance();

    final lighter = luminance1 > luminance2 ? luminance1 : luminance2;
    final darker = luminance1 > luminance2 ? luminance2 : luminance1;

    final contrastRatio = (lighter + 0.05) / (darker + 0.05);

    return contrastRatio >= 4.5; // WCAG AA
  }

  @override
  Description describe(Description description) {
    return description.add('has good contrast with background');
  }
}

/// Crea un matcher para verificar contraste
Matcher hasGoodContrastWith(Color background) {
  return HasGoodContrast(background);
}

/// Extension para WidgetTester con helpers adicionales
extension WidgetTesterExtensions on WidgetTester {
  /// Tap y espera a que termine la animación
  Future<void> tapAndSettle(Finder finder) async {
    await tap(finder);
    await pumpAndSettle();
  }

  /// Enter text y espera
  Future<void> enterTextAndSettle(Finder finder, String text) async {
    await enterText(finder, text);
    await pumpAndSettle();
  }
}
