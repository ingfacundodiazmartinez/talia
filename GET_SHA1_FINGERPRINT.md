# 🔑 Cómo obtener la huella SHA-1

## **Método 1: Usando Android Studio (Más fácil)**

### 📱 Si tienes Android Studio:
1. Abre Android Studio
2. Ve a **View** → **Tool Windows** → **Gradle**
3. Navega a: `app` → `Tasks` → `android` → `signingReport`
4. Haz doble clic en `signingReport`
5. En la pestaña **Run** verás algo como:
```
Variant: debug
Config: debug
Store: /Users/tu_usuario/.android/debug.keystore
Alias: AndroidDebugKey
MD5: XX:XX:XX...
SHA1: AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE
SHA-256: ...
```

**La línea SHA1 es lo que necesitas** ☝️

---

## **Método 2: Instalar Java y usar keytool**

### 🔧 Instalar Java:
```bash
# En macOS con Homebrew:
brew install openjdk@11

# O descargar desde: https://www.oracle.com/java/technologies/downloads/
```

### 🔑 Obtener SHA-1:
```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

---

## **Método 3: Usando Flutter/Gradle**

### 📱 Con Gradle (necesita Java):
```bash
cd android
./gradlew signingReport
```

### 🔍 Buscar en el output:
Busca la sección que dice **"Variant: debug"** y copia el SHA1.

---

## **Método 4: Usando VS Code con extensión Flutter**

### 📝 Si usas VS Code:
1. Instala la extensión **"Flutter"**
2. Abre la paleta de comandos (`Cmd+Shift+P`)
3. Busca **"Flutter: Get App Signing Information"**
4. Ejecuta el comando
5. Te mostrará la información incluyendo SHA-1

---

## **Método 5: Desde Firebase Console (Automático)**

### 🔥 Si ya tienes Firebase configurado:
1. Ve a [Firebase Console](https://console.firebase.google.com/)
2. Selecciona tu proyecto
3. Ve a **Project Settings** (⚙️)
4. Pestaña **"General"**
5. Baja hasta **"Your apps"**
6. Haz clic en el ícono de Android
7. Verás la opción **"Add fingerprint"**
8. Firebase puede detectar automáticamente tu SHA-1

---

## **¿Qué hacer con la huella SHA-1?**

### 📋 Una vez que tengas tu SHA-1:
1. Ve a [Google Cloud Console](https://console.cloud.google.com/)
2. Selecciona tu proyecto
3. Ve a **"APIs y servicios"** → **"Credenciales"**
4. Haz clic en tu API key de Android
5. En **"Restricciones de aplicación"**:
   - Selecciona **"Aplicaciones de Android"**
   - **Nombre del paquete**: `com.talia.chat`
   - **Huella digital del certificado SHA-1**: `TU_SHA1_AQUI`
6. Guarda los cambios

---

## **💡 Consejos importantes:**

- ✅ La huella SHA-1 para **depuración** es diferente a la de **producción**
- ✅ Puedes agregar **múltiples huellas** (depuración + producción)
- ✅ El formato típico es: `AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE`
- ⚠️ **No compartas** tu huella SHA-1 públicamente

---

## **🚨 Si nada funciona:**

Puedes crear la API key **sin restricciones** temporalmente para probar:
1. En Google Cloud Console, crea la API key
2. **NO** pongas restricciones
3. Prueba que funcione en tu app
4. **Después** agrega las restricciones cuando tengas la SHA-1

**⚠️ Recuerda agregar restricciones antes de publicar en producción**