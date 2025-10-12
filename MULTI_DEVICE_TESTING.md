# 📱 Testing Multi-Dispositivo - Talia

## 📋 Resumen

Guía completa para testing en múltiples dispositivos, plataformas y tamaños de pantalla.

---

## 🎯 Objetivos

- ✅ Verificar funcionamiento en iOS y Android
- ✅ Probar en diferentes tamaños de pantalla
- ✅ Validar diseño responsivo
- ✅ Detectar problemas específicos de plataforma
- ✅ Asegurar consistencia de UX

---

## 📱 Matriz de Dispositivos

### iOS Devices

| Dispositivo | Tamaño | Resolución | Aspect Ratio | Prioridad |
|------------|---------|-----------|--------------|-----------|
| iPhone SE (3rd gen) | 4.7" | 750x1334 | 9:16 | Alta |
| iPhone 13 mini | 5.4" | 1080x2340 | 9:19.5 | Media |
| iPhone 13/14 | 6.1" | 1170x2532 | 9:19.5 | Alta |
| iPhone 14 Pro Max | 6.7" | 1290x2796 | 9:19.5 | Alta |
| iPhone 15 Pro Max | 6.7" | 1290x2796 | 9:19.5 | Media |
| iPad (10th gen) | 10.9" | 1640x2360 | Tablet | Baja |
| iPad Pro 12.9" | 12.9" | 2048x2732 | Tablet | Baja |

### Android Devices

| Dispositivo | Tamaño | Resolución | Aspect Ratio | Prioridad |
|------------|---------|-----------|--------------|-----------|
| Samsung Galaxy S23 | 6.1" | 1080x2340 | 9:19.5 | Alta |
| Samsung Galaxy S23 Ultra | 6.8" | 1440x3088 | 9:19.3 | Alta |
| Google Pixel 7 | 6.3" | 1080x2400 | 9:20 | Alta |
| Google Pixel 8 Pro | 6.7" | 1344x2992 | 9:20 | Media |
| Xiaomi Redmi Note 12 | 6.67" | 1080x2400 | 9:20 | Media |
| OnePlus 11 | 6.7" | 1440x3216 | 9:20 | Media |
| Samsung Galaxy A54 | 6.4" | 1080x2340 | 9:19.5 | Baja |

### Categorías de Tamaño

- **Pequeño**: < 5.5" (iPhone SE, dispositivos compactos)
- **Medio**: 5.5" - 6.3" (iPhone 13, Galaxy S23)
- **Grande**: 6.4" - 6.9" (iPhone Pro Max, Galaxy Ultra)
- **Tablet**: > 7" (iPad)

---

## 🧪 Checklist de Testing

### 1. Testing Visual

#### Pantallas Principales

- [ ] **Login/Autenticación**
  - [ ] Campos de entrada visibles
  - [ ] Botones accesibles
  - [ ] Código de verificación legible
  - [ ] Sin overflow de texto

- [ ] **Lista de Chats**
  - [ ] Avatares correctamente dimensionados
  - [ ] Previews de mensajes completos
  - [ ] Timestamps visibles
  - [ ] Badges de unread messages
  - [ ] Pull to refresh funciona

- [ ] **Chat Individual**
  - [ ] Burbujas de mensaje correctamente alineadas
  - [ ] Input de texto accesible
  - [ ] Botones de media visibles
  - [ ] Media (imágenes/videos) se escalan bien
  - [ ] Emoji picker no se corta

- [ ] **Llamadas de Video**
  - [ ] Video local/remoto se muestra correctamente
  - [ ] Controles accesibles
  - [ ] No distorsión en diferentes orientaciones

- [ ] **Ubicación**
  - [ ] Mapa se renderiza correctamente
  - [ ] Marcadores visibles
  - [ ] Controles de zoom accesibles

- [ ] **Perfil**
  - [ ] Foto de perfil correctamente dimensionada
  - [ ] Campos de edición completos
  - [ ] Botones de acción visibles

- [ ] **Configuración**
  - [ ] Todos los switches visibles
  - [ ] Listas no cortadas
  - [ ] Navegación fluida

#### Diseño Responsivo

- [ ] **Text Scaling**
  - [ ] Probar con 80% text scale
  - [ ] Probar con 100% (default)
  - [ ] Probar con 150% text scale
  - [ ] Probar con 200% text scale
  - [ ] Sin overflow en ningún caso

- [ ] **Orientación**
  - [ ] Portrait mode funciona
  - [ ] Landscape mode funciona (donde aplica)
  - [ ] Rotación fluida sin crashes

- [ ] **Safe Areas**
  - [ ] Respeta notch en iPhone X+
  - [ ] Respeta status bar
  - [ ] Respeta navigation bar
  - [ ] Respeta teclado en pantalla

### 2. Testing Funcional

#### Features Core

- [ ] **Autenticación**
  - [ ] Phone auth funciona
  - [ ] SMS recibido en ambas plataformas
  - [ ] Verificación exitosa
  - [ ] Logout funciona

- [ ] **Mensajería**
  - [ ] Enviar texto
  - [ ] Enviar imagen (cámara)
  - [ ] Enviar imagen (galería)
  - [ ] Enviar video
  - [ ] Enviar audio
  - [ ] Recibir mensajes en tiempo real
  - [ ] Notificaciones push

- [ ] **Llamadas**
  - [ ] Audio call funciona
  - [ ] Video call funciona
  - [ ] Calidad aceptable
  - [ ] No dropouts frecuentes

- [ ] **Ubicación**
  - [ ] Compartir ubicación funciona
  - [ ] Ver ubicación de contactos
  - [ ] Actualización en tiempo real

- [ ] **Emergencias**
  - [ ] SOS funciona
  - [ ] Notificaciones enviadas
  - [ ] Ubicación compartida

#### Permisos

- [ ] **iOS**
  - [ ] Camera permission
  - [ ] Photo library permission
  - [ ] Microphone permission
  - [ ] Location permission (when in use)
  - [ ] Notifications permission
  - [ ] Contacts permission

- [ ] **Android**
  - [ ] Camera permission
  - [ ] Read external storage
  - [ ] Write external storage
  - [ ] Record audio
  - [ ] Access fine location
  - [ ] Post notifications (Android 13+)
  - [ ] Read contacts

### 3. Testing de Performance

- [ ] **Startup Time**
  - [ ] Cold start < 3s
  - [ ] Warm start < 1s

- [ ] **Scrolling**
  - [ ] Lista de chats suave (60fps)
  - [ ] Chat messages suave
  - [ ] No lag al scrollear rápido

- [ ] **Memoria**
  - [ ] Uso < 200MB en idle
  - [ ] Uso < 500MB durante video call
  - [ ] No memory leaks

- [ ] **Batería**
  - [ ] Consumo razonable en background
  - [ ] No drain excesivo durante llamadas

- [ ] **Network**
  - [ ] Funciona en WiFi
  - [ ] Funciona en 4G
  - [ ] Funciona en 5G
  - [ ] Maneja offline correctamente
  - [ ] Sincroniza al volver online

### 4. Testing de Plataforma

#### iOS Específico

- [ ] **Widgets**
  - [ ] Ninguno implementado (futuro)

- [ ] **Integración Sistema**
  - [ ] Comparte a través de iOS Share Sheet
  - [ ] Maneja llamadas entrantes correctamente
  - [ ] Soporta Picture in Picture (si aplica)
  - [ ] Dark mode funciona

- [ ] **Notifications**
  - [ ] Badge count correcto
  - [ ] Push notifications llegan
  - [ ] Rich notifications (con imagen)
  - [ ] Notification actions funcionan

- [ ] **Certificaciones**
  - [ ] No warnings en App Store Connect
  - [ ] Pasa App Review guidelines

#### Android Específico

- [ ] **Widgets**
  - [ ] Ninguno implementado (futuro)

- [ ] **Integración Sistema**
  - [ ] Comparte a través de Android Share
  - [ ] Maneja llamadas entrantes
  - [ ] Soporta split screen
  - [ ] Dark mode funciona

- [ ] **Notifications**
  - [ ] Notification channels configurados
  - [ ] Push notifications llegan
  - [ ] Rich notifications
  - [ ] Notification actions funcionan

- [ ] **Fragmentación**
  - [ ] Funciona en Android 6.0 (minSdk)
  - [ ] Funciona en Android 14 (targetSdk)
  - [ ] Diferentes fabricantes (Samsung, Pixel, Xiaomi)

### 5. Testing de Accesibilidad

- [ ] **Screen Readers**
  - [ ] VoiceOver (iOS) lee correctamente
  - [ ] TalkBack (Android) lee correctamente
  - [ ] Todos los botones tienen labels
  - [ ] Orden de navegación lógico

- [ ] **Contraste**
  - [ ] High contrast mode funciona
  - [ ] Cumple WCAG AA (4.5:1)

- [ ] **Texto**
  - [ ] Text scaling funciona
  - [ ] No overflow en 200%
  - [ ] Bold text option funciona

- [ ] **Animaciones**
  - [ ] Reduce animations funciona
  - [ ] No motion sickness

### 6. Testing de Seguridad

- [ ] **Datos**
  - [ ] No logs sensibles en producción
  - [ ] Crashlytics no expone PII
  - [ ] Storage cifrado

- [ ] **Comunicación**
  - [ ] HTTPS en todas las requests
  - [ ] Certificados válidos
  - [ ] App Check habilitado

- [ ] **Permisos**
  - [ ] Solo pide permisos necesarios
  - [ ] Explica por qué necesita permisos
  - [ ] Funciona si permisos denegados (graceful degradation)

---

## 🔧 Herramientas de Testing

### Emuladores y Simuladores

```bash
# iOS Simulators
xcrun simctl list devices available

# Crear simuladores útiles
xcrun simctl create "iPhone SE 3" com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation
xcrun simctl create "iPhone 14 Pro Max" com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro-Max

# Android Emulators
flutter emulators

# Crear emuladores
avdmanager create avd -n Pixel_7 -k "system-images;android-33;google_apis;x86_64"
avdmanager create avd -n Galaxy_S23 -k "system-images;android-33;google_apis;x86_64"
```

### Flutter DevTools

```bash
# Abrir DevTools
flutter pub global activate devtools
flutter pub global run devtools

# Performance profiling
flutter run --profile

# Memory profiling
# En DevTools → Memory → Profile Memory
```

### Testing Automatizado

```bash
# Unit tests
flutter test

# Widget tests
flutter test test/widgets/

# Integration tests
flutter test integration_test/

# Con coverage
flutter test --coverage

# Específico para plataforma
flutter test --platform chrome
```

### Firebase Test Lab (Android)

```bash
# Configurar gcloud
gcloud auth login

# Ejecutar tests en devices reales
gcloud firebase test android run \
  --type instrumentation \
  --app build/app/outputs/apk/debug/app-debug.apk \
  --test build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk \
  --device model=Pixel2,version=28,locale=en,orientation=portrait \
  --device model=GalaxyS9,version=28,locale=en,orientation=portrait
```

### App Center Test (iOS y Android)

```bash
# Instalar CLI
npm install -g appcenter-cli

# Login
appcenter login

# Run tests
appcenter test run appium \
  --app "YourOrg/YourApp" \
  --devices "YourOrg/your-device-set" \
  --app-path path/to/app.apk \
  --test-series "master" \
  --locale "en_US"
```

---

## 📊 Reporte de Testing

### Template de Reporte

```markdown
# Test Report - [Fecha]

## Dispositivo
- **Modelo**: iPhone 14 Pro
- **OS**: iOS 17.2
- **App Version**: 1.0.8 (22)

## Tests Ejecutados
- [x] Visual testing
- [x] Functional testing
- [x] Performance testing
- [ ] Security testing

## Resultados

### ✅ Passed (15)
- Login funciona correctamente
- Mensajes se envían y reciben
- ...

### ❌ Failed (2)
- Overflow en chat con text scale 200%
- Video call se congela en 4G

### ⚠️ Warnings (1)
- Startup time 3.2s (objetivo: < 3s)

## Screenshots
[Adjuntar screenshots de issues]

## Logs
```
[Adjuntar logs relevantes]
```

## Siguiente Paso
- Fix overflow issue
- Optimizar video codec para 4G
```

---

## 🎯 Priorización de Tests

### P0 - Crítico (Debe pasar)

- Login/autenticación funciona
- Enviar/recibir mensajes funciona
- Notificaciones funcionan
- No crashes al usar features básicos
- Permisos se solicitan correctamente

### P1 - Alto (Debe pasar en release)

- Diseño responsivo correcto
- Performance aceptable (60fps scroll)
- Llamadas de audio/video funcionan
- Ubicación se comparte correctamente
- Accesibilidad básica funciona

### P2 - Medio (Nice to have)

- Animaciones suaves
- Dark mode perfecto
- Todos los edge cases manejados
- Testing en todos los dispositivos
- 100% cobertura de tests

### P3 - Bajo (Futuro)

- Widgets funcionan
- Soporta todos los Android vendors
- Optimización extrema de batería

---

## 📝 Bugs Conocidos por Dispositivo

### iPhone SE (Pantalla pequeña)

- ⚠️ **Issue**: Emoji picker puede cubrir parte del input
- **Workaround**: Scroll para ver input
- **Fix**: Ajustar altura de emoji picker

### Android < 8.0

- ⚠️ **Issue**: Notificaciones no soportan reply directo
- **Workaround**: Abrir app para responder
- **Fix**: Feature no disponible en API < 24

### Tablets

- ℹ️ **Nota**: UI diseñada para phones, funciona pero no optimizada
- **Futuro**: Diseño específico para tablets

---

## 🚀 Automation Strategy

### CI/CD Tests

```yaml
# .github/workflows/device-tests.yml

name: Multi-Device Tests

on:
  push:
    branches: [ master, develop ]
  pull_request:
    branches: [ master, develop ]

jobs:
  android-test:
    runs-on: macos-latest
    strategy:
      matrix:
        api-level: [24, 28, 33]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
      - uses: subosito/flutter-action@v2
      - name: Run Android Tests
        uses: reactivecircus/android-emulator-runner@v2
        with:
          api-level: ${{ matrix.api-level }}
          script: flutter test integration_test/

  ios-test:
    runs-on: macos-latest
    strategy:
      matrix:
        device: ['iPhone SE (3rd generation)', 'iPhone 14 Pro Max']
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
      - name: Run iOS Tests
        run: |
          xcrun simctl boot "${{ matrix.device }}"
          flutter test integration_test/
```

### Regression Testing

- Ejecutar suite completa antes de cada release
- Automatizar P0 y P1 tests
- Manual testing para P2
- Mantener device farm actualizado

---

## 📧 Soporte

Para reportar problemas encontrados durante testing:
- **GitHub Issues**: Método preferido
- **Email**: qa@talia-app.com

---

**Última actualización:** Enero 2025
