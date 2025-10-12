# 🔐 Gestión de Permisos - Talia

## 📋 Resumen

Guía completa para el manejo de permisos en Talia, incluyendo implementación, mejores prácticas y troubleshooting.

---

## 🎯 Permisos Utilizados

### Permisos Críticos

Estos permisos son esenciales para el funcionamiento básico de la app:

| Permiso | iOS | Android | ¿Por qué? | Crítico |
|---------|-----|---------|-----------|---------|
| **Notificaciones** | ✅ | ✅ | Recibir mensajes y alertas de emergencia | ✅ Sí |
| **Ubicación** | ✅ | ✅ | Compartir ubicación y funciones de emergencia | ✅ Sí |
| **Cámara** | ✅ | ✅ | Tomar fotos de perfil y enviar imágenes | ⚠️ Alta |
| **Fotos/Galería** | ✅ | ✅ | Seleccionar fotos existentes | ⚠️ Alta |
| **Micrófono** | ✅ | ✅ | Llamadas de voz y video | ⚠️ Alta |

### Permisos Opcionales

Estos permisos mejoran la experiencia pero no son esenciales:

| Permiso | iOS | Android | ¿Por qué? | Crítico |
|---------|-----|---------|-----------|---------|
| **Contactos** | ✅ | ✅ | Facilitar agregar familiares | ❌ No |
| **Ubicación Always** | ✅ | ✅ | Emergencias en background | ⚠️ Media |

---

## 🔧 Implementación

### PermissionService

Servicio centralizado para gestionar todos los permisos:

```dart
import 'package:talia/services/permission_service.dart';

// Solicitar un permiso
final result = await permissions.request(
  AppPermission.camera,
  context: context,
  showRationale: true,
);

if (result == PermissionResult.granted) {
  // Permiso concedido, proceder
  takePhoto();
} else if (result == PermissionResult.permanentlyDenied) {
  // Permiso denegado permanentemente, mostrar instrucciones
  showSettingsDialog();
} else {
  // Permiso denegado, degradación gradual
  showFallbackOption();
}
```

### Tipos de Permisos

```dart
enum AppPermission {
  camera,           // Cámara
  photos,           // Galería
  microphone,       // Micrófono
  location,         // Ubicación
  locationAlways,   // Ubicación en background
  contacts,         // Contactos
  notifications,    // Notificaciones push
}
```

### Resultados de Permisos

```dart
enum PermissionResult {
  granted,            // Permiso concedido
  denied,             // Denegado (puede volver a solicitar)
  permanentlyDenied,  // Denegado permanentemente (ir a settings)
  restricted,         // Restringido (control parental)
  limited,            // Limitado (iOS photos)
}
```

---

## 📱 Configuración por Plataforma

### iOS (Info.plist)

Archivo: `ios/Runner/Info.plist`

```xml
<key>NSCameraUsageDescription</key>
<string>Talia necesita acceso a tu cámara para tomar fotos de perfil y enviar imágenes en chats.</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>Talia necesita acceso a tus fotos para seleccionar imágenes de perfil y compartir en chats.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>Talia necesita permiso para guardar fotos en tu galería.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Talia necesita acceso a tu micrófono para llamadas de voz y video con tu familia.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>Talia necesita tu ubicación para compartirla con contactos aprobados y funciones de emergencia.</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Talia necesita acceso a tu ubicación en segundo plano para funciones de emergencia que funcionan cuando la app está cerrada.</string>

<key>NSLocationAlwaysUsageDescription</key>
<string>Talia necesita acceso a tu ubicación en segundo plano para funciones de emergencia.</string>

<key>NSContactsUsageDescription</key>
<string>Talia puede acceder a tus contactos para ayudarte a agregar familiares fácilmente.</string>

<key>NSUserNotificationsUsageDescription</key>
<string>Talia necesita enviar notificaciones para alertarte de mensajes nuevos y emergencias.</string>
```

### Android (AndroidManifest.xml)

Archivo: `android/app/src/main/AndroidManifest.xml`

```xml
<!-- Permisos de red (siempre requeridos) -->
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>

<!-- Cámara -->
<uses-permission android:name="android.permission.CAMERA"/>
<uses-feature android:name="android.hardware.camera" android:required="false"/>
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false"/>

<!-- Fotos/Storage -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="29"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>

<!-- Micrófono -->
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>

<!-- Ubicación -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>

<!-- Contactos -->
<uses-permission android:name="android.permission.READ_CONTACTS"/>

<!-- Notificaciones (Android 13+) -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

<!-- Servicios en background -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
```

---

## 🎨 Flujo de UX para Permisos

### 1. Just-in-Time (Mejor Práctica)

Solicitar permisos justo cuando se necesitan, no al inicio:

```dart
// ❌ MAL: Solicitar todos los permisos al inicio
void initApp() async {
  await permissions.request(AppPermission.camera, context: context);
  await permissions.request(AppPermission.photos, context: context);
  await permissions.request(AppPermission.microphone, context: context);
  // ...
}

// ✅ BIEN: Solicitar cuando el usuario intenta usar la función
void onTakePhotoPressed() async {
  final hasPermission = await permissions.isGranted(AppPermission.camera);

  if (!hasPermission) {
    final result = await permissions.request(
      AppPermission.camera,
      context: context,
    );

    if (result != PermissionResult.granted) {
      showSnackbar('Se necesita acceso a la cámara');
      return;
    }
  }

  // Proceder a tomar foto
  takePhoto();
}
```

### 2. Rationale Dialog (Explicación)

En Android, mostrar por qué necesitamos el permiso antes de solicitarlo:

```dart
// El PermissionService maneja esto automáticamente
final result = await permissions.request(
  AppPermission.location,
  context: context,
  showRationale: true, // Mostrar diálogo explicativo
);
```

El diálogo muestra:
- **Título**: "Acceso a Ubicación"
- **Descripción**: Por qué necesitamos el permiso
- **Importancia**: Por qué es necesario para esta función
- **Acciones**: Permitir / Cancelar

### 3. Manejo de Denegación

Si el usuario niega el permiso, mostrar alternativas:

```dart
if (result == PermissionResult.denied) {
  // Primera denegación: ofrecer alternativa
  showDialog(
    title: 'Sin Acceso a Cámara',
    message: permissions.getGracefulDegradationMessage(AppPermission.camera),
    actions: [
      'Usar Galería', // Alternativa
      'Cancelar',
    ],
  );
}
```

### 4. Manejo de Denegación Permanente

Si el usuario niega permanentemente, guiarlo a settings:

```dart
if (result == PermissionResult.permanentlyDenied) {
  final openSettings = await showDialog<bool>(
    title: 'Permiso Requerido',
    message: 'Para usar esta función, necesitas habilitar el permiso en Configuración',
    actions: [
      'Ir a Configuración',
      'Cancelar',
    ],
  );

  if (openSettings == true) {
    await permissions.openSettings();
  }
}
```

---

## 🧪 Testing de Permisos

### Escenarios de Test

1. **Primera solicitud**: Usuario ve permiso por primera vez
2. **Concedido**: Usuario concede el permiso
3. **Denegado**: Usuario niega el permiso
4. **Denegado permanentemente**: Usuario niega 2+ veces o marca "No preguntar de nuevo"
5. **Revocado**: Usuario concede y luego revoca en settings
6. **Restringido**: Control parental o MDM
7. **Limited (iOS photos)**: Usuario selecciona "Seleccionar Fotos" en vez de "Permitir Acceso a Todas las Fotos"

### Test Manual

```markdown
## Checklist de Testing de Permisos

### Cámara
- [ ] Primera solicitud muestra diálogo del sistema
- [ ] Conceder permite tomar fotos
- [ ] Denegar muestra mensaje de error y alternativa (galería)
- [ ] Denegar permanentemente muestra diálogo para ir a settings
- [ ] Abrir settings desde el diálogo funciona

### Fotos/Galería
- [ ] Primera solicitud muestra diálogo del sistema
- [ ] Conceder permite seleccionar fotos
- [ ] Denegar muestra mensaje de error y alternativa (cámara)
- [ ] iOS: "Seleccionar Fotos" funciona (limited)
- [ ] Android 13+: Permission.photos funciona
- [ ] Android < 13: Permission.storage funciona

### Ubicación
- [ ] Primera solicitud muestra diálogo del sistema
- [ ] Conceder permite compartir ubicación
- [ ] Denegar muestra que no se puede usar función
- [ ] "Permitir Solo Mientras Uso App" funciona
- [ ] "Permitir Siempre" (Android) funciona
- [ ] Emergencias piden "Siempre" si solo tienen "While Using"

### Notificaciones
- [ ] Primera solicitud muestra diálogo del sistema
- [ ] Conceder permite recibir notificaciones
- [ ] Denegar muestra advertencia de que no recibirá alertas
- [ ] iOS: Provisional funciona
- [ ] Android 13+: POST_NOTIFICATIONS funciona
```

### Test Automatizado

```dart
// test/services/permission_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:talia/services/permission_service.dart';

void main() {
  group('PermissionService', () {
    late PermissionService service;

    setUp(() {
      service = PermissionService();
    });

    test('isGranted returns true for granted permission', () async {
      // Mock permission status
      // Test implementation
    });

    test('request shows rationale on Android before first request', () async {
      // Test implementation
    });

    test('getGracefulDegradationMessage provides alternatives', () {
      final message = service.getGracefulDegradationMessage(
        AppPermission.camera,
      );
      expect(message, contains('galería'));
    });

    test('isCritical returns true for notifications and location', () {
      expect(service.isCritical(AppPermission.notifications), true);
      expect(service.isCritical(AppPermission.location), true);
      expect(service.isCritical(AppPermission.contacts), false);
    });
  });
}
```

---

## 🚨 Troubleshooting

### Problema: Permiso siempre denegado

**Síntomas**: El permiso se niega automáticamente sin mostrar el diálogo del sistema.

**Causas**:
1. El usuario denegó permanentemente el permiso
2. El permiso está restringido (control parental, MDM)
3. Missing entry en Info.plist (iOS)
4. Missing permission en AndroidManifest.xml

**Solución**:
```dart
final status = await permissions.checkStatus(AppPermission.camera);

if (status == PermissionResult.permanentlyDenied) {
  // Guiar al usuario a settings
  await permissions.openSettings();
} else if (status == PermissionResult.restricted) {
  // Mostrar mensaje que el permiso está restringido
  showDialog('Este permiso está restringido por control parental');
}
```

### Problema: iOS muestra "Limited Access"

**Síntomas**: En iOS, al pedir acceso a fotos, el usuario selecciona "Seleccionar Fotos" y la app solo puede acceder a fotos específicas.

**Solución**: Esto es normal y esperado. El PermissionService maneja `PermissionResult.limited` como válido para fotos.

```dart
if (result == PermissionResult.granted || result == PermissionResult.limited) {
  // Ambos son válidos para acceder a fotos
  pickPhoto();
}
```

### Problema: Android 13+ no pide permiso de notificaciones

**Síntomas**: En Android 13+, las notificaciones no funcionan.

**Causa**: Falta el permiso `POST_NOTIFICATIONS` en AndroidManifest.xml

**Solución**:
```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

```dart
// Solicitar el permiso
await permissions.request(AppPermission.notifications, context: context);
```

### Problema: Ubicación en background no funciona

**Síntomas**: La app no puede obtener ubicación cuando está en background.

**Causa**:
1. Falta permiso `ACCESS_BACKGROUND_LOCATION` (Android 10+)
2. Falta `NSLocationAlwaysAndWhenInUseUsageDescription` (iOS)
3. No se solicitó el permiso "Always" después de "When In Use"

**Solución**:

iOS: Solicitar en dos pasos
```dart
// Primero solicitar "When In Use"
await permissions.request(AppPermission.location, context: context);

// Luego solicitar "Always"
await permissions.request(AppPermission.locationAlways, context: context);
```

Android 10+: Solicitar "While Using" primero, luego "All the time"
```dart
// Primero location normal
await permissions.request(AppPermission.location, context: context);

// Luego background (solo si es crítico)
await permissions.request(AppPermission.locationAlways, context: context);
```

---

## 📊 Mejores Prácticas

### ✅ Hacer

1. **Just-in-Time**: Solicitar permisos cuando se necesitan
2. **Explicar el Por Qué**: Mostrar rationale antes de solicitar
3. **Degradación Gradual**: Ofrecer alternativas si el permiso es denegado
4. **Minimal Permissions**: Solo pedir permisos realmente necesarios
5. **Clear Descriptions**: Info.plist y AndroidManifest con descripciones claras
6. **Handle All States**: Manejar granted, denied, permanentlyDenied, restricted, limited
7. **Settings Fallback**: Guiar a settings cuando sea permanentemente denegado

### ❌ No Hacer

1. **No pedir todos los permisos al inicio**: Mala UX y baja tasa de aceptación
2. **No asumir que un permiso concedido siempre lo estará**: El usuario puede revocarlo
3. **No bloquear la app si un permiso opcional es denegado**: Degradación gradual
4. **No solicitar permisos en loop**: Si el usuario niega, respetar la decisión
5. **No usar permisos para funciones no relacionadas**: Cumplir con políticas de stores

---

## 🔍 Debug

### Ver estado de todos los permisos

```dart
final debugInfo = await permissions.getPermissionsDebugInfo();
print(debugInfo);

/* Output:
{
  'AppPermission.camera': {
    'status': 'PermissionResult.granted',
    'raw_status': 'PermissionStatus.granted',
    'is_granted': true,
  },
  'AppPermission.photos': {
    'status': 'PermissionResult.limited',
    'raw_status': 'PermissionStatus.limited',
    'is_granted': true,
  },
  ...
  'platform': 'iOS',
}
*/
```

### Logs de permisos

El PermissionService ya incluye logs detallados:

```
📱 [PermissionService] Requesting camera permission
🍎 Platform: iOS
✅ Permission granted
```

```
📱 [PermissionService] Requesting photos permission
🤖 Platform: Android (API 33)
⚠️ Permission denied
📋 Showing rationale dialog
```

---

## 📚 Recursos

### iOS

- [Apple - Requesting Authorization for Media Capture](https://developer.apple.com/documentation/avfoundation/cameras_and_media_capture/requesting_authorization_for_media_capture_on_ios)
- [App Store Review Guidelines - Data Collection and Storage](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)

### Android

- [Android - Request Runtime Permissions](https://developer.android.com/training/permissions/requesting)
- [Android 13 - Notification Runtime Permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)
- [Android - Background Location](https://developer.android.com/training/location/permissions#request-background-location)

### Flutter

- [permission_handler package](https://pub.dev/packages/permission_handler)
- [Flutter - Platform Channel](https://docs.flutter.dev/development/platform-integration/platform-channels)

---

## 📧 Soporte

Para problemas con permisos:
- **GitHub Issues**: Reportar bugs con permisos
- **Email**: support@talia-app.com
- **Incluir**: Plataforma, versión OS, logs relevantes

---

**Última actualización:** Enero 2025
