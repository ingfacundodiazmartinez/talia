# 🔥 Firebase Setup - Guía Completa

## 📋 Resumen

Guía paso a paso para configurar Firebase en el proyecto Talia.

---

## 🚀 1. Creación del Proyecto Firebase

### Paso 1: Crear Proyecto

1. Ve a [Firebase Console](https://console.firebase.google.com/)
2. Click en "Agregar proyecto"
3. Nombre: `talia-production` (o el que prefieras)
4. Habilitar Google Analytics: **Sí** (recomendado)
5. Cuenta de Analytics: Crear nueva o usar existente

### Paso 2: Configurar Apps

#### iOS App

1. En Project Settings, click en "Agregar app" → iOS
2. Bundle ID: `com.tuempresa.talia` (debe coincidir con el de Xcode)
3. App nickname: `Talia iOS`
4. Descargar `GoogleService-Info.plist`
5. Mover a `ios/Runner/GoogleService-Info.plist`

#### Android App

1. En Project Settings, click en "Agregar app" → Android
2. Package name: `com.tuempresa.talia` (debe coincidir con el de Android)
3. App nickname: `Talia Android`
4. Descargar `google-services.json`
5. Mover a `android/app/google-services.json`

---

## 🔧 2. Configuración de Servicios

### Authentication

```bash
# Habilitar métodos de autenticación

1. Firebase Console → Authentication → Sign-in method
2. Habilitar:
   - Phone (para login principal)
   - Email/Password (backup)

3. Para Phone Auth:
   - Ir a "Phone numbers for testing" (opcional para desarrollo)
   - Agregar números de prueba con códigos fijos

4. Configurar reCAPTCHA Enterprise:
   - Ir a GCP Console
   - Habilitar reCAPTCHA Enterprise API
   - Crear key de tipo "Android" y "iOS"
   - En Firebase Console → App Check → Configurar reCAPTCHA
```

### Firestore Database

```bash
# Crear base de datos

1. Firebase Console → Firestore Database → Crear base de datos
2. Modo: Producción (reglas restrictivas)
3. Ubicación: us-central (o la más cercana)

4. Reglas de seguridad:
   - Copiar desde firestore.rules
   - Implementar en Firebase Console

5. Índices:
   - Copiar desde firestore.indexes.json
   - Firebase CLI: firebase deploy --only firestore:indexes
```

### Storage

```bash
# Configurar almacenamiento

1. Firebase Console → Storage → Get started
2. Ubicación: Same as Firestore
3. Reglas de seguridad:
   - Copiar desde storage.rules
   - Solo permitir uploads autenticados
   - Límites de tamaño
```

### Cloud Functions

```bash
# Desplegar funciones

1. Instalar Firebase CLI:
   npm install -g firebase-tools

2. Inicializar funciones (si no está hecho):
   firebase init functions

3. Instalar dependencias:
   cd functions
   npm install

4. Desplegar:
   firebase deploy --only functions

5. Configurar secretos (si necesario):
   firebase functions:secrets:set SECRET_NAME
```

### Crashlytics

```bash
# Configurar Crashlytics

1. Firebase Console → Crashlytics → Habilitar
2. iOS: Agregar Run Script en Xcode Build Phases
3. Android: Ya configurado en build.gradle
4. Probar con test crash:
   await FirebaseCrashlytics.instance.crash();
```

### Analytics

```bash
# Ya está configurado automáticamente

1. Firebase Console → Analytics
2. Verificar que eventos se están recibiendo
3. Crear audiencias personalizadas (opcional)
4. Configurar conversiones (opcional)
```

### Performance Monitoring

```bash
# Ya está configurado

1. Firebase Console → Performance
2. Esperar 12-24h para primeros datos
3. Configurar alertas (opcional)
```

### Remote Config

```bash
# Configurar valores remotos

1. Firebase Console → Remote Config
2. Agregar parámetros:
   - maintenance_mode: false
   - min_app_version: "1.0.0"
   - force_update: false
   - feature_flags: {}

3. Publicar cambios
```

### App Check

```bash
# Configurar App Check

1. Firebase Console → App Check
2. iOS:
   - Provider: App Attest (production)
   - Provider: DeviceCheck (fallback)
3. Android:
   - Provider: Play Integrity
   - Safety Net (deprecated, no usar)

4. Enforce en servicios:
   - Firestore: ✅
   - Storage: ✅
   - Functions: ✅
   - Realtime DB: N/A

5. Debug tokens (desarrollo):
   - Ver tokens en logs de la app
   - Registrar en Firebase Console
```

---

## 📱 3. Configuración por Plataforma

### iOS Específico

```bash
# Xcode Configuration

1. Abrir ios/Runner.xcworkspace
2. Capabilities:
   - Push Notifications: ON
   - Background Modes: ON
     - Remote notifications
     - Background fetch
   - Associated Domains: ON (para links dinámicos)

3. Info.plist:
   - NSCameraUsageDescription
   - NSMicrophoneUsageDescription
   - NSPhotoLibraryUsageDescription
   - NSLocationWhenInUseUsageDescription

4. Signing:
   - Automatic signing
   - Team: Tu equipo de desarrollo
```

### Android Específico

```bash
# Android Configuration

1. android/app/build.gradle:
   - minSdkVersion 21
   - compileSdkVersion 34
   - Plugins de Firebase ya configurados

2. android/app/src/main/AndroidManifest.xml:
   - Permisos ya configurados
   - <uses-permission android:name="android.permission.INTERNET"/>
   - <uses-permission android:name="android.permission.CAMERA"/>
   - etc.

3. Signing (para release):
   - Crear keystore
   - Configurar en android/key.properties
   - Agregar a .gitignore
```

---

## 🔐 4. Reglas de Seguridad

### Firestore Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Función helper para verificar autenticación
    function isSignedIn() {
      return request.auth != null;
    }

    // Función helper para verificar propiedad
    function isOwner(userId) {
      return isSignedIn() && request.auth.uid == userId;
    }

    // Usuarios
    match /users/{userId} {
      allow read: if isSignedIn();
      allow write: if isOwner(userId);
    }

    // Chats
    match /chats/{chatId} {
      allow read: if isSignedIn() &&
        request.auth.uid in resource.data.participants;
      allow create: if isSignedIn();
      allow update: if isSignedIn() &&
        request.auth.uid in resource.data.participants;

      // Mensajes
      match /messages/{messageId} {
        allow read: if isSignedIn() &&
          request.auth.uid in get(/databases/$(database)/documents/chats/$(chatId)).data.participants;
        allow create: if isSignedIn() &&
          request.auth.uid in get(/databases/$(database)/documents/chats/$(chatId)).data.participants;
      }
    }

    // Emergencias
    match /emergencies/{emergencyId} {
      allow read: if isSignedIn();
      allow create: if isSignedIn();
    }

    // Blocked contacts
    match /blocked_contacts/{blockId} {
      allow read: if isSignedIn() && request.auth.uid == resource.data.userId;
      allow create: if isSignedIn() && request.auth.uid == request.resource.data.userId;
      allow delete: if isSignedIn() && request.auth.uid == resource.data.userId;
    }

    // Notification preferences
    match /notification_preferences/{userId} {
      allow read, write: if isOwner(userId);
    }

    // Muted chats
    match /users/{userId}/muted_chats/{chatId} {
      allow read, write: if isOwner(userId);
    }
  }
}
```

### Storage Rules

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    // Helper function
    function isSignedIn() {
      return request.auth != null;
    }

    // Avatares de usuario
    match /avatars/{userId}/{fileName} {
      allow read: if isSignedIn();
      allow write: if isSignedIn() &&
                     request.auth.uid == userId &&
                     request.resource.size < 5 * 1024 * 1024 && // 5MB
                     request.resource.contentType.matches('image/.*');
    }

    // Media de chats
    match /chat_media/{chatId}/{fileName} {
      allow read: if isSignedIn();
      allow write: if isSignedIn() &&
                     request.resource.size < 100 * 1024 * 1024 && // 100MB
                     (request.resource.contentType.matches('image/.*') ||
                      request.resource.contentType.matches('video/.*') ||
                      request.resource.contentType.matches('audio/.*'));
    }
  }
}
```

---

## 🧪 5. Testing

### Emuladores Locales

```bash
# Instalar y configurar emuladores

1. Instalar Firebase CLI:
   npm install -g firebase-tools

2. Inicializar emuladores:
   firebase init emulators

3. Seleccionar:
   - Authentication
   - Firestore
   - Functions
   - Storage

4. Ejecutar emuladores:
   firebase emulators:start

5. UI de emuladores:
   http://localhost:4000
```

### Testing con Emuladores

```dart
// En tu app Flutter, conectar a emuladores (desarrollo)

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  if (kDebugMode) {
    // Conectar a emuladores locales
    await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);

    FirebaseFirestore.instance.useFirestoreEmulator('localhost', 8080);

    await FirebaseStorage.instance.useStorageEmulator('localhost', 9199);
  }

  runApp(MyApp());
}
```

---

## 📊 6. Monitoreo y Mantenimiento

### Dashboard de Monitoreo

1. **Usage & Billing**
   - Firestore: Lecturas, Escrituras, Eliminaciones
   - Storage: GB almacenados, GB transferidos
   - Functions: Invocaciones, GB-segundos
   - Authentication: Usuarios activos

2. **Alertas**
   - Configurar alertas de uso
   - Notificar si se excede cuota
   - Alertar errores en Functions

3. **Crashlytics**
   - Revisar crashes diariamente
   - Priorizar por usuarios afectados
   - Versión y OS del crash

4. **Performance**
   - Tiempos de carga de pantallas
   - Latencia de red
   - Trazas personalizadas

---

## 💰 7. Costos y Límites

### Plan Spark (Gratis)

```
- Firestore:
  - 1 GB almacenamiento
  - 50,000 lecturas/día
  - 20,000 escrituras/día
  - 20,000 eliminaciones/día

- Storage:
  - 5 GB almacenamiento
  - 1 GB/día transferencia

- Functions:
  - 2M invocaciones/mes
  - 400,000 GB-segundos/mes
  - 200,000 CPU-segundos/mes

- Authentication:
  - 10K verificaciones/mes (Phone)
```

### Plan Blaze (Pay as you go)

```
- Sin límites duros
- Paga solo lo que usas
- Cuotas gratuitas generosas
- Configurar presupuesto para alertas
```

### Optimización de Costos

1. **Firestore**
   - Usar cache local
   - Minimizar lecturas innecesarias
   - Batch writes cuando sea posible

2. **Storage**
   - Comprimir imágenes antes de subir
   - Usar thumbnails
   - Limpiar archivos no usados

3. **Functions**
   - Optimizar cold starts
   - Usar mínima memoria necesaria
   - Cleanup de listeners

---

## 🔒 8. Seguridad

### Checklist de Seguridad

- [ ] Reglas de Firestore configuradas
- [ ] Reglas de Storage configuradas
- [ ] App Check habilitado
- [ ] reCAPTCHA Enterprise configurado
- [ ] Secrets no expuestos en código
- [ ] Rate limiting en Functions
- [ ] Validación en servidor
- [ ] HTTPS obligatorio
- [ ] API keys restringidas
- [ ] Crashlytics no expone datos sensibles

### API Keys Seguras

```bash
# Restricciones recomendadas en GCP Console

iOS API Key:
- iOS apps restriction
- Bundle ID: com.tuempresa.talia

Android API Key:
- Android apps restriction
- Package name: com.tuempresa.talia
- SHA-1 fingerprint: [tu fingerprint]

Web API Key:
- HTTP referrers
- Dominio específico
```

---

## 🚀 9. Deployment Checklist

### Pre-Deploy

- [ ] Tests pasando
- [ ] Firestore rules actualizadas
- [ ] Storage rules actualizadas
- [ ] Functions desplegadas
- [ ] Índices de Firestore creados
- [ ] App Check configurado
- [ ] Remote Config publicado
- [ ] Crashlytics habilitado

### Deploy

```bash
# Deploy completo

1. Deploy Firestore rules:
   firebase deploy --only firestore:rules

2. Deploy Firestore indexes:
   firebase deploy --only firestore:indexes

3. Deploy Storage rules:
   firebase deploy --only storage

4. Deploy Functions:
   firebase deploy --only functions

5. Deploy todo:
   firebase deploy
```

### Post-Deploy

- [ ] Verificar en Firebase Console
- [ ] Test en production
- [ ] Monitorear Crashlytics
- [ ] Verificar Analytics
- [ ] Check Performance Monitoring

---

## 📝 10. Troubleshooting

### Problemas Comunes

**App Check failures:**
```
Solución: Verificar debug tokens registrados
```

**Phone Auth no funciona:**
```
Solución:
- Verificar reCAPTCHA configurado
- Verificar APNs certificate (iOS)
- Verificar SHA-1 fingerprint (Android)
```

**Functions timeout:**
```
Solución:
- Aumentar timeout en deploy
- Optimizar código de función
- Verificar cold start
```

**Firestore permission denied:**
```
Solución:
- Verificar reglas de seguridad
- Verificar autenticación
- Check request.auth.uid
```

---

## 🔗 Recursos

- [Firebase Documentation](https://firebase.google.com/docs)
- [FlutterFire Documentation](https://firebase.flutter.dev/)
- [Firebase YouTube Channel](https://www.youtube.com/firebase)
- [Firebase Blog](https://firebase.googleblog.com/)
- [Stack Overflow - Firebase](https://stackoverflow.com/questions/tagged/firebase)

---

## 📧 Soporte

Para problemas específicos de Firebase:
- [Firebase Support](https://firebase.google.com/support)
- [Community Slack](https://firebase.community)
- GitHub Issues de FlutterFire
