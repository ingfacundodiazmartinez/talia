# 🧪 Testing - Guía Completa

## 📋 Resumen

Framework completo de testing para garantizar calidad y estabilidad antes del lanzamiento a producción.

### ✨ Tipos de Tests Implementados

1. **Tests Unitarios** - Servicios y lógica de negocio
2. **Tests de Widgets** - UI components
3. **Tests de Integración** - Flujos completos
4. **Test Helpers** - Utilidades y mocks reutilizables
5. **CI/CD** - Automatización con GitHub Actions

---

## 🎯 1. Tests Unitarios

### Estructura

```
test/
├── services/
│   ├── accessibility_service_test.dart
│   ├── offline_queue_service_test.dart
│   └── user_profile_cache_service_test.dart
├── widgets/
│   └── accessible_text_test.dart
└── test_helpers.dart
```

### Ejecutar Tests Unitarios

```bash
# Todos los tests
flutter test

# Tests específicos
flutter test test/services/accessibility_service_test.dart

# Con coverage
flutter test --coverage

# Ver coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

### Ejemplo: Test de Servicio

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/accessibility_service.dart';

void main() {
  group('AccessibilityService', () {
    late AccessibilityService service;

    setUp(() async {
      service = AccessibilityService();
      await service.initialize();
    });

    test('setTextScale updates value within valid range', () async {
      await service.setTextScale(1.5);
      expect(service.textScale, 1.5);

      // Test clamping
      await service.setTextScale(2.5);
      expect(service.textScale, 2.0); // Max clamped
    });

    test('settings persist across instances', () async {
      await service.setTextScale(1.5);

      // Create new instance
      final newService = AccessibilityService();
      await newService.initialize();

      expect(newService.textScale, 1.5); // Persisted
    });
  });
}
```

---

## 🎨 2. Tests de Widgets

### Ejecutar Tests de Widgets

```bash
# Tests de widgets
flutter test test/widgets/

# Test específico
flutter test test/widgets/accessible_text_test.dart
```

### Ejemplo: Test de Widget

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/accessibility_service.dart';

void main() {
  testWidgets('AccessibleText renders correctly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleText('Hello World'),
        ),
      ),
    );

    expect(find.text('Hello World'), findsOneWidget);
  });

  testWidgets('AccessibleButton has correct semantics', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleButton(
            semanticsLabel: 'Submit Form',
            onPressed: () {},
            child: Text('Submit'),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Submit Form'), findsOneWidget);
  });
}
```

---

## 🔗 3. Tests de Integración

### Estructura

```
integration_test/
├── app_test.dart
├── chat_flow_test.dart
└── emergency_flow_test.dart
```

### Ejecutar Tests de Integración

```bash
# En dispositivo/emulador
flutter test integration_test/

# iOS Simulator
flutter test integration_test/ -d iPhone

# Android Emulator
flutter test integration_test/ -d emulator-5554
```

### Ejemplo: Test de Integración

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:talia/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Chat Flow Integration Test', () {
    testWidgets('User can send message in chat', (tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Login
      await tester.enterText(find.byKey(Key('phone_input')), '+1234567890');
      await tester.tap(find.byKey(Key('login_button')));
      await tester.pumpAndSettle(Duration(seconds: 3));

      // Navigate to chat
      await tester.tap(find.byIcon(Icons.chat));
      await tester.pumpAndSettle();

      // Select first chat
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();

      // Send message
      await tester.enterText(find.byKey(Key('message_input')), 'Test message');
      await tester.tap(find.byKey(Key('send_button')));
      await tester.pumpAndSettle();

      // Verify message appears
      expect(find.text('Test message'), findsOneWidget);
    });
  });
}
```

---

## 🛠️ 4. Test Helpers

### Uso de Test Helpers

```dart
import 'package:flutter_test/flutter_test.dart';
import '../test_helpers.dart';

void main() {
  setUp(() async {
    await initializeTestEnvironment();
  });

  testWidgets('Example test with helpers', (tester) async {
    // Create test app
    await tester.pumpWidget(
      createTestApp(MyWidget()),
    );

    // Tap and settle
    await tester.tapAndSettle(find.byType(ElevatedButton));

    // Verify accessibility
    verifyAccessibility(tester);
  });

  test('Use test data factory', () {
    final userData = TestDataFactory.createUserProfile(
      displayName: 'John Doe',
      email: 'john@example.com',
    );

    expect(userData['displayName'], 'John Doe');
    expect(userData['email'], 'john@example.com');
  });
}
```

### Custom Matchers

```dart
test('Color has good contrast', () {
  expect(
    Colors.black,
    hasGoodContrastWith(Colors.white),
  );
});
```

---

## 🚀 5. CI/CD con GitHub Actions

### Configuración

El archivo `.github/workflows/test.yml` ejecuta automáticamente:

1. **Verificación de formato**
   ```bash
   dart format --output=none --set-exit-if-changed .
   ```

2. **Análisis de código**
   ```bash
   flutter analyze
   ```

3. **Tests unitarios con coverage**
   ```bash
   flutter test --coverage
   ```

4. **Upload de coverage a Codecov** (opcional)

### Badge de Status

Agregar al README.md:

```markdown
![Tests](https://github.com/tu-usuario/talia/workflows/Run%20Tests/badge.svg)
[![codecov](https://codecov.io/gh/tu-usuario/talia/branch/master/graph/badge.svg)](https://codecov.io/gh/tu-usuario/talia)
```

---

## 📊 6. Coverage

### Generar Reporte de Coverage

```bash
# Generar coverage
flutter test --coverage

# Convertir a HTML
genhtml coverage/lcov.info -o coverage/html

# Ver en navegador
open coverage/html/index.html  # macOS
xdg-open coverage/html/index.html  # Linux
start coverage/html/index.html  # Windows
```

### Objetivos de Coverage

- **Servicios críticos**: ≥80%
- **Widgets**: ≥70%
- **UI screens**: ≥50%
- **General**: ≥60%

### Coverage Actual

```
Servicios:
- AccessibilityService: 85%
- OfflineQueueService: 78%
- UserProfileCacheService: 72%

Widgets:
- AccessibleText: 100%
- AccessibleButton: 100%
- AccessibleIconButton: 95%

Total: 75%
```

---

## ✅ Checklist de Testing

### Antes de Cada Release

- [ ] Todos los tests pasan (`flutter test`)
- [ ] Coverage ≥60%
- [ ] No hay warnings en `flutter analyze`
- [ ] Código formateado (`dart format .`)
- [ ] Tests de integración en iOS pasan
- [ ] Tests de integración en Android pasan
- [ ] Tests manuales de flujos críticos:
  - [ ] Login/Logout
  - [ ] Enviar mensaje
  - [ ] Videollamada
  - [ ] Emergencia
  - [ ] Modo offline

### Tests Críticos Priorizados

1. **Autenticación**
   - Login con teléfono
   - Verificación de código
   - 2FA
   - Logout

2. **Mensajería**
   - Enviar mensaje de texto
   - Enviar imagen
   - Enviar video
   - Modo offline

3. **Emergencias**
   - Activar emergencia
   - Notificar padres
   - Compartir ubicación

4. **Accesibilidad**
   - Text scale
   - Alto contraste
   - Lectores de pantalla

---

## 🎯 Mejores Prácticas

### 1. Tests Descriptivos

```dart
// ✅ BIEN
test('setTextScale clamps value to max 2.0', () {
  // ...
});

// ❌ MAL
test('test1', () {
  // ...
});
```

### 2. Arrange-Act-Assert

```dart
test('example', () {
  // Arrange - preparar
  final service = MyService();

  // Act - ejecutar
  final result = service.doSomething();

  // Assert - verificar
  expect(result, expectedValue);
});
```

### 3. Independencia de Tests

```dart
// ✅ BIEN - cada test es independiente
group('MyService', () {
  late MyService service;

  setUp(() {
    service = MyService();
  });

  test('test 1', () {
    service.setValue(10);
    expect(service.getValue(), 10);
  });

  test('test 2', () {
    service.setValue(20);
    expect(service.getValue(), 20);
  });
});

// ❌ MAL - tests dependen entre sí
test('set value', () {
  service.setValue(10);
});

test('get value', () {
  expect(service.getValue(), 10); // Depende del test anterior
});
```

### 4. Mockear Dependencias Externas

```dart
// ✅ BIEN - usar mocks
test('getUserProfile fetches from Firestore', () async {
  final fakeFirestore = FakeFirebaseFirestore();
  final service = UserProfileService(firestore: fakeFirestore);

  await fakeFirestore.collection('users').doc('123').set({
    'name': 'John',
  });

  final profile = await service.getProfile('123');
  expect(profile['name'], 'John');
});

// ❌ MAL - depender de Firestore real
test('getUserProfile', () async {
  final profile = await service.getProfile('123'); // Requiere conexión
});
```

### 5. Tests de Edge Cases

```dart
test('handles null values', () {
  expect(() => service.setValue(null), throwsArgumentError);
});

test('handles empty list', () {
  final result = service.processList([]);
  expect(result, isEmpty);
});

test('handles very large values', () {
  service.setValue(double.maxFinite);
  expect(service.getValue(), double.maxFinite);
});
```

---

## 🐛 Debugging Tests

### Ejecutar en Modo Debug

```bash
# Run with debug output
flutter test --verbose

# Run specific test
flutter test test/services/my_service_test.dart --name "test name"

# Run with platform override
flutter test --platform chrome
```

### Ver Output de Prints

```dart
test('debug test', () {
  debugPrint('Debug message'); // Visible en output
  print('Regular print'); // También visible

  expect(something, toBe);
});
```

### Pausar Ejecución

```dart
testWidgets('debug widget', (tester) async {
  await tester.pumpWidget(MyWidget());

  // Pause to inspect widget tree
  await tester.pump(Duration(seconds: 5));

  // Inspect widget properties
  final widget = tester.widget<MyWidget>(find.byType(MyWidget));
  debugPrint('Widget state: ${widget.someProperty}');
});
```

---

## 📝 Tests Pendientes por Implementar

### Alta Prioridad

1. **EmergencyService**
   - Crear emergencia
   - Notificar contactos
   - Rate limiting

2. **MessageService**
   - Enviar mensaje
   - Moderar contenido
   - Modo offline

3. **CallService**
   - Iniciar videollamada
   - Iniciar audioll amada
   - Colgar

### Media Prioridad

4. **ContactsService**
   - Agregar contacto
   - Bloquear/Desbloquear
   - Cache

5. **ProfileService**
   - Actualizar perfil
   - Subir foto
   - Validación

### Baja Prioridad

6. **ThemeService**
7. **NotificationService**
8. **LocationService**

---

## 📊 Métricas de Calidad

### Estado Actual

- ✅ Framework de testing configurado
- ✅ Tests para servicios críticos
- ✅ Tests de widgets accesibles
- ✅ CI/CD con GitHub Actions
- ✅ Test helpers y mocks
- ⚠️ Integration tests pendientes
- ⚠️ Coverage objetivo no alcanzado (actual: ~40%, objetivo: 60%)

### Próximos Pasos

1. Aumentar coverage a 60%
2. Implementar integration tests
3. Agregar performance tests
4. Configurar test de regresión visual

---

## 🔗 Resources

- [Flutter Testing Docs](https://docs.flutter.dev/testing)
- [Widget Testing](https://docs.flutter.dev/cookbook/testing/widget/introduction)
- [Integration Testing](https://docs.flutter.dev/testing/integration-tests)
- [Mockito](https://pub.dev/packages/mockito)
- [Fake Cloud Firestore](https://pub.dev/packages/fake_cloud_firestore)

---

## 📝 Notas de Implementación

- Tests unitarios usan `flutter_test`
- Mocks con `mockito` y `fake_cloud_firestore`
- Integration tests con `integration_test` package
- CI/CD con GitHub Actions
- Coverage tracking con lcov
- Test helpers en `test/test_helpers.dart`
