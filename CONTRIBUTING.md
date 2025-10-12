# 🤝 Guía de Contribución - Talia

¡Gracias por tu interés en contribuir a Talia! Esta guía te ayudará a empezar.

---

## 📋 Tabla de Contenidos

1. [Código de Conducta](#código-de-conducta)
2. [Cómo Puedo Contribuir](#cómo-puedo-contribuir)
3. [Setup del Entorno](#setup-del-entorno)
4. [Proceso de Desarrollo](#proceso-de-desarrollo)
5. [Guías de Estilo](#guías-de-estilo)
6. [Testing](#testing)
7. [Pull Requests](#pull-requests)
8. [Revisión de Código](#revisión-de-código)

---

## 📜 Código de Conducta

### Nuestro Compromiso

Nos comprometemos a mantener un ambiente acogedor e inclusivo para todos, sin importar:
- Edad, tamaño corporal, discapacidad
- Etnia, identidad y expresión de género
- Nivel de experiencia, educación, estatus socioeconómico
- Nacionalidad, apariencia personal, raza, religión
- Identidad y orientación sexual

### Comportamiento Esperado

✅ **SÍ:**
- Usar lenguaje acogedor e inclusivo
- Respetar puntos de vista y experiencias diferentes
- Aceptar críticas constructivas con gracia
- Enfocarse en lo mejor para la comunidad
- Mostrar empatía hacia otros miembros

❌ **NO:**
- Lenguaje o imágenes sexualizadas
- Trolling, comentarios insultantes o ataques personales/políticos
- Acoso público o privado
- Publicar información privada sin permiso
- Conducta poco profesional

### Aplicación

Instancias de comportamiento inaceptable pueden reportarse a:
- **Email**: conduct@talia-app.com
- Se tomarán acciones apropiadas

---

## 🎯 Cómo Puedo Contribuir

### Reportar Bugs

Ver [BUG_REPORT.md](./BUG_REPORT.md) para el proceso completo.

**Resumen:**
1. Verifica que no esté ya reportado
2. Usa el template de issue
3. Incluye pasos para reproducir
4. Adjunta logs/screenshots

### Sugerir Features

```markdown
## Feature Request

### Problema que Resuelve
[Qué problema tiene el usuario]

### Solución Propuesta
[Cómo esta feature lo resuelve]

### Alternativas Consideradas
[Otras formas de resolverlo]

### Contexto Adicional
[Screenshots, ejemplos, etc.]
```

### Mejorar Documentación

- Corregir typos
- Aclarar instrucciones confusas
- Agregar ejemplos
- Traducir a otros idiomas

### Escribir Código

Ver [Proceso de Desarrollo](#proceso-de-desarrollo) abajo.

---

## 🛠️ Setup del Entorno

### Prerequisitos

```bash
# Flutter SDK
flutter --version  # 3.19.0 o superior

# Editor recomendado
- VS Code con extensión Flutter
- Android Studio
- IntelliJ IDEA

# Herramientas
- Git
- Firebase CLI: npm install -g firebase-tools
- FlutterFire CLI: dart pub global activate flutterfire_cli
```

### Clonar el Repositorio

```bash
git clone https://github.com/tuusuario/talia.git
cd talia
```

### Instalar Dependencias

```bash
# Flutter dependencies
flutter pub get

# iOS dependencies (macOS only)
cd ios && pod install && cd ..
```

### Configurar Firebase

```bash
# Usar tu propio proyecto Firebase para desarrollo

1. Crear proyecto en Firebase Console
2. Configurar apps (iOS y Android)
3. Ejecutar: flutterfire configure
4. Seleccionar tu proyecto
```

### Ejecutar en Emulador/Dispositivo

```bash
# Listar dispositivos disponibles
flutter devices

# Ejecutar
flutter run -d <device_id>

# Hot reload durante desarrollo: r
# Hot restart: R
# Quit: q
```

---

## 🔄 Proceso de Desarrollo

### 1. Crear un Issue

- Para features nuevos
- Para bugs que vas a arreglar
- Discutir enfoque antes de codear

### 2. Fork y Branch

```bash
# Fork en GitHub

# Clonar tu fork
git clone https://github.com/TU_USUARIO/talia.git

# Crear branch
git checkout -b feature/nombre-descriptivo
# o
git checkout -b fix/descripcion-del-bug
```

### 3. Hacer Cambios

- Commits pequeños y frecuentes
- Mensajes de commit descriptivos
- Seguir guías de estilo

### 4. Probar

```bash
# Run tests
flutter test

# Code analysis
flutter analyze

# Format code
dart format lib/

# Integration tests
flutter test integration_test/
```

### 5. Commit

```bash
git add .
git commit -m "feat: descripción del feature"

# O
git commit -m "fix: descripción del fix"
```

### 6. Push

```bash
git push origin feature/nombre-descriptivo
```

### 7. Abrir Pull Request

- En GitHub, crear PR desde tu fork
- Llenar el template de PR
- Vincular issues relacionados

---

## 📝 Guías de Estilo

### Código Dart

Seguimos [Effective Dart](https://dart.dev/guides/language/effective-dart):

```dart
// ✅ BIEN
class UserProfile {
  final String displayName;
  final String? photoURL;

  const UserProfile({
    required this.displayName,
    this.photoURL,
  });

  // Documentar métodos públicos
  /// Actualiza el nombre de usuario
  Future<void> updateName(String newName) async {
    // Implementación
  }
}

// ❌ MAL
class userProfile {  // Nombre incorrecto
  String DisplayName;  // Public field sin final
  String? photo_URL;  // Snake case en lugar de camelCase

  // Sin documentación
  Future updateName(n) async {  // Tipo y nombre de parámetro no claros
    // ...
  }
}
```

### Estructura de Archivos

```
lib/
├── models/           # Data models
├── screens/          # UI screens
│   ├── common/      # Shared screens
│   ├── parent/      # Parent-specific
│   └── child/       # Child-specific
├── services/         # Business logic
├── widgets/          # Reusable widgets
└── utils/           # Helper functions
```

### Naming Conventions

- **Files**: `snake_case.dart`
- **Classes**: `PascalCase`
- **Variables**: `camelCase`
- **Constants**: `lowerCamelCase` o `SCREAMING_SNAKE_CASE`
- **Private**: `_leadingUnderscore`

### Comentarios

```dart
// ✅ Comentar el POR QUÉ, no el QUÉ

// Usar cache para reducir queries a Firestore en 80%
final cachedProfile = await cache.getProfile(userId);

// ❌ Comentarios obvios
// Obtener perfil del cache
final cachedProfile = await cache.getProfile(userId);
```

### Documentación

```dart
/// Servicio para gestionar preferencias de notificaciones.
///
/// Proporciona métodos para:
/// - Configurar tipos de notificaciones
/// - Modo No Molestar
/// - Silenciar chats individuales
///
/// Ejemplo:
/// ```dart
/// final service = NotificationPreferencesService();
/// await service.updatePreference('soundEnabled', true);
/// ```
class NotificationPreferencesService {
  // ...
}
```

---

## 🧪 Testing

### Tests Unitarios

```dart
// test/services/my_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/my_service.dart';

void main() {
  group('MyService', () {
    late MyService service;

    setUp(() {
      service = MyService();
    });

    test('should do something', () {
      final result = service.doSomething();
      expect(result, expectedValue);
    });
  });
}
```

### Tests de Widgets

```dart
testWidgets('should display user name', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: UserProfileWidget(userName: 'John'),
    ),
  );

  expect(find.text('John'), findsOneWidget);
});
```

### Coverage Mínimo

- **Servicios críticos**: 80%
- **Widgets**: 70%
- **Screens**: 50%
- **Total**: 60%

### Ejecutar Tests

```bash
# Todos los tests
flutter test

# Con coverage
flutter test --coverage

# Test específico
flutter test test/services/my_service_test.dart

# Ver coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

---

## 📬 Pull Requests

### Template de PR

```markdown
## Descripción
[Descripción clara de los cambios]

## Tipo de Cambio
- [ ] Bug fix (cambio que arregla un issue)
- [ ] New feature (cambio que agrega funcionalidad)
- [ ] Breaking change (fix o feature que causa que funcionalidad existente no funcione como esperado)
- [ ] Documentation update

## ¿Cómo se ha Testeado?
[Describe tests realizados]

## Checklist
- [ ] Mi código sigue las guías de estilo
- [ ] He realizado self-review de mi código
- [ ] He comentado mi código, especialmente en áreas difíciles
- [ ] He actualizado la documentación
- [ ] Mis cambios no generan nuevos warnings
- [ ] He agregado tests que prueban mi fix/feature
- [ ] Tests unitarios nuevos y existentes pasan
- [ ] Cambios dependientes han sido merged y publicados

## Screenshots (si aplica)
[Adjuntar screenshots]

## Issues Relacionados
Fixes #123
Closes #456
```

### Proceso de Revisión

1. **CI/CD Checks**
   - Tests pasan ✅
   - Análisis de código pasa ✅
   - Coverage > 60% ✅

2. **Code Review**
   - Al menos 1 aprobación requerida
   - Cambios solicitados deben resolverse

3. **Merge**
   - Squash and merge (preferido)
   - Merge commit (para features grandes)
   - Rebase (para mantener historia limpia)

---

## 👀 Revisión de Código

### Para Reviewers

**Qué Revisar:**
- ✅ Código claro y mantenible
- ✅ Tests adecuados
- ✅ Documentación actualizada
- ✅ Sin código comentado o debug
- ✅ Manejo de errores apropiado
- ✅ Performance considerations
- ✅ Seguridad (no exponer secrets, validación)
- ✅ Accesibilidad (labels, contrast)

**Cómo Comentar:**
- Ser constructivo y amable
- Explicar el "por qué" de sugerencias
- Distinguir entre bloqueantes y nice-to-have
- Hacer preguntas, no demandas
- Aprobar cuando está listo

**Ejemplo:**
```
# ✅ BIEN
Sugerencia: Considera usar `const` aquí para mejorar performance.
Esto haría que el widget se reconstruya menos veces.

# ❌ MAL
esto está mal, usa const
```

### Para Contributors

**Al Recibir Feedback:**
- No tomar como algo personal
- Hacer preguntas si no entiendes
- Estar abierto a aprender
- Agradecer el tiempo del reviewer
- Resolver comentarios o explicar por qué no

---

## 🎨 Accesibilidad

Talia debe ser accesible para todos:

- **Semantics**: Labels descriptivos
- **Contraste**: WCAG AA mínimo (4.5:1)
- **Text Scale**: Soportar 80% - 200%
- **Screen Readers**: Compatible con TalkBack/VoiceOver
- **Keyboard**: Navegación completa

```dart
// ✅ BIEN
AccessibleIconButton(
  icon: Icons.send,
  semanticsLabel: 'Enviar mensaje',
  tooltip: 'Enviar mensaje al chat',
  onPressed: sendMessage,
)

// ❌ MAL
IconButton(
  icon: Icon(Icons.send),
  onPressed: sendMessage,
) // Sin label para screen readers
```

Ver [ACCESSIBILITY.md](./ACCESSIBILITY.md) para más detalles.

---

## 🚀 Release Process

### Versionado

Seguimos [Semantic Versioning](https://semver.org/):

- **MAJOR** (1.0.0): Cambios incompatibles de API
- **MINOR** (0.1.0): Nueva funcionalidad compatible hacia atrás
- **PATCH** (0.0.1): Bug fixes compatibles hacia atrás

### Changelog

Mantener `CHANGELOG.md` actualizado:

```markdown
## [1.1.0] - 2025-01-20

### Added
- Modo No Molestar con horario configurable
- Silenciar chats individuales

### Changed
- Mejorado rendimiento de lista de chats en 40%

### Fixed
- Bug de notificaciones duplicadas
- Crash al compartir ubicación sin permisos

### Security
- Actualizado rate limiting en Cloud Functions
```

---

## 📞 Contacto

### Preguntas Generales
- **Email**: dev@talia-app.com
- **Discord**: [Link al servidor]
- **GitHub Discussions**: [Link]

### Coordinación
- **Project Lead**: [Nombre] - lead@talia-app.com
- **Technical Lead**: [Nombre] - tech@talia-app.com

---

## 🏆 Reconocimientos

Contributors destacados serán mencionados en:
- Release notes
- README.md
- About screen en la app

---

## 📚 Recursos Adicionales

- [Flutter Documentation](https://docs.flutter.dev/)
- [Firebase Documentation](https://firebase.google.com/docs)
- [Material Design Guidelines](https://material.io/design)
- [Effective Dart](https://dart.dev/guides/language/effective-dart)
- [Testing Documentation](./TESTING.md)
- [Bug Report Guide](./BUG_REPORT.md)

---

## ❤️ Agradecimientos

¡Gracias por contribuir a Talia! Cada contribución, sin importar el tamaño, hace la diferencia.

**Happy Coding!** 🚀

---

**Última actualización:** Enero 2025
