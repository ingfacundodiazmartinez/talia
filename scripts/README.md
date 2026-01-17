# Scripts de Demostración

Scripts para generar y limpiar datos de demostración para screenshots de las tiendas de aplicaciones.

## 📋 Requisitos previos

1. **Node.js** (versión 14 o superior)
   ```bash
   node --version
   ```

2. **Firebase Admin SDK**
   ```bash
   npm install firebase-admin
   ```

3. **Service Account Key**
   - Ve a [Firebase Console](https://console.firebase.google.com)
   - Selecciona tu proyecto (talia-chat-app-v2)
   - Ve a **Project Settings** (⚙️) → **Service Accounts**
   - Click en **Generate New Private Key**
   - Descarga el archivo JSON
   - Renómbralo a: `talia-chat-app-v2-firebase-adminsdk.json`
   - Colócalo en la **raíz del proyecto** (mismo nivel que `pubspec.yaml`)

## 🚀 Uso

### Generar datos de demostración

```bash
# Desde la raíz del proyecto
node scripts/seed_demo_data.js
```

Este script creará:
- ✅ 3 familias completas (padres e hijos)
- ✅ 3 contactos amigos adicionales
- ✅ Conversaciones realistas entre padres e hijos
- ✅ Conversaciones entre amigos
- ✅ Grupos familiares
- ✅ Historias/Stories
- ✅ Ubicaciones en tiempo real
- ✅ Reportes semanales con IA

**Tiempo estimado:** 2-3 minutos

### Limpiar datos de demostración

```bash
# Desde la raíz del proyecto
node scripts/clean_demo_data.js
```

⚠️ **ADVERTENCIA:** Este script eliminará permanentemente:
- Todos los usuarios con email `*.demo@talia.app`
- Todos los documentos marcados con `isDemo: true`
- Chats, grupos y mensajes relacionados

El script pedirá confirmación antes de proceder.

## 👥 Cuentas Creadas

### Familias

**Familia González**
- 👩 María González (Madre)
  - Email: `maria.demo@talia.app`
  - Teléfono: `+5491155510011`
- 👧 Sofía González (12 años)
  - Email: `sofia.demo@talia.app`
  - Teléfono: `+5491155510022`
- 👦 Lucas González (9 años)
  - Email: `lucas.demo@talia.app`
  - Teléfono: `+5491155510033`

**Familia Martínez**
- 👨 Roberto Martínez (Padre)
  - Email: `roberto.demo@talia.app`
  - Teléfono: `+5491155510044`
- 👧 Emma Martínez (14 años)
  - Email: `emma.demo@talia.app`
  - Teléfono: `+5491155510055`

**Familia Fernández**
- 👩 Laura Fernández (Madre)
  - Email: `laura.demo@talia.app`
  - Teléfono: `+5491155510066`
- 👦 Mateo Fernández (10 años)
  - Email: `mateo.demo@talia.app`
  - Teléfono: `+5491155510077`
- 👧 Valentina Fernández (13 años)
  - Email: `valentina.demo@talia.app`
  - Teléfono: `+5491155510088`

### Amigos

- 👧 Camila Rodríguez (12 años)
  - Email: `camila.demo@talia.app`
  - Teléfono: `+5491155510099`
- 👦 Benjamín López (13 años)
  - Email: `benjamin.demo@talia.app`
  - Teléfono: `+5491155511100`
- 👧 Martina Silva (11 años)
  - Email: `martina.demo@talia.app`
  - Teléfono: `+5491155511111`

**Autenticación:** OTP por SMS (ver configuración de números de prueba abajo)

## 📸 Tomar Screenshots

### Configurar números de prueba en Firebase (una sola vez)

Para poder iniciar sesión sin recibir SMS reales:

1. Ve a [Firebase Console - Authentication](https://console.firebase.google.com/project/talia-chat-app-v2/authentication/providers)
2. Click en **Phone** → **Phone numbers for testing**
3. Agrega cada número con el código **123456**:
   ```
   +5491155510011 → 123456
   +5491155510022 → 123456
   +5491155510033 → 123456
   ... (el script te mostrará todos los números)
   ```

### Tomar capturas

Una vez configurados los números de prueba:

1. **Compila la app en modo release:**
   ```bash
   flutter build apk --release
   # o para iOS
   flutter build ios --release
   ```

2. **Instala en dispositivo/emulador:**
   ```bash
   flutter install
   ```

3. **Inicia sesión:**
   - Ingresa número: `+5491155510011` (María - Madre)
   - Código OTP: `123456`
   - O usa cualquier otro número de los creados

4. **Sigue la guía:** Ver `SCREENSHOT_GUIDE.md` en la raíz del proyecto

## 🛠️ Troubleshooting

### Error: "Cannot find module 'firebase-admin'"

```bash
npm install firebase-admin
```

### Error: "Cannot find module '../talia-chat-app-v2-firebase-adminsdk.json'"

El archivo del service account debe estar en la **raíz del proyecto**, no en la carpeta `scripts/`.

Estructura correcta:
```
/talia/
  ├── scripts/
  │   ├── seed_demo_data.js
  │   └── clean_demo_data.js
  ├── talia-chat-app-v2-firebase-adminsdk.json  ← Aquí
  └── pubspec.yaml
```

### Error: "auth/email-already-exists"

Las cuentas ya existen. Opciones:
1. Ejecutar `clean_demo_data.js` primero
2. Cambiar los emails en el script

### Error de permisos en Firestore

Verifica que el service account tenga permisos de **Editor** o **Owner** en el proyecto Firebase.

## 🔒 Seguridad

⚠️ **IMPORTANTE:**

1. **NO subas el service account a Git**
   - Ya está en `.gitignore` como `*firebase*adminsdk*.json`
   - Verifica con: `git status`

2. **NO uses estas cuentas en producción**
   - Son solo para demos y screenshots
   - Usa `clean_demo_data.js` antes de lanzar

3. **Revoca el service account después**
   - Ve a Firebase Console → Service Accounts
   - Elimina la key cuando termines los screenshots

## 📚 Referencias

- [SCREENSHOT_GUIDE.md](../SCREENSHOT_GUIDE.md) - Guía completa de screenshots
- [Firebase Admin SDK](https://firebase.google.com/docs/admin/setup)
- [Play Store Assets](https://support.google.com/googleplay/android-developer/answer/9866151)
- [App Store Screenshots](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)
