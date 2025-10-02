# 🗺️ Configuración de Google Maps API

Para que la funcionalidad de mapas funcione correctamente, necesitas configurar las Google Maps API keys.

## 📋 Pasos para obtener las API Keys

### 1. Ir a Google Cloud Console
- Visita: https://console.cloud.google.com/
- Inicia sesión con tu cuenta de Google

### 2. Crear un proyecto (si no tienes uno)
- Haz clic en "Seleccionar proyecto" → "Nuevo proyecto"
- Nombra tu proyecto (ej: "Talia App")
- Haz clic en "Crear"

### 3. Habilitar las APIs necesarias
Ve a "APIs y servicios" → "Biblioteca" y habilita:
- **Maps SDK for Android** 
- **Maps SDK for iOS**
- **Geocoding API** (opcional, para convertir direcciones)

### 4. Crear las API Keys

#### Para Android:
1. Ve a "APIs y servicios" → "Credenciales"
2. Haz clic en "Crear credenciales" → "Clave de API"
3. Copia la clave generada
4. Haz clic en "Restringir clave"
5. En "Restricciones de aplicación", selecciona "Aplicaciones de Android"
6. Agrega el nombre del paquete: `com.talia.chat`
7. Agrega la huella digital SHA-1 de tu certificado de depuración

#### Para iOS:
1. Crea otra clave de API (repite pasos 1-3)
2. En "Restricciones de aplicación", selecciona "Aplicaciones de iOS"
3. Agrega el Bundle ID: `com.talia.chat`

## 🔧 Configurar las API Keys en la app

### Android
Edita el archivo `android/app/src/main/AndroidManifest.xml`:
```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="TU_API_KEY_DE_ANDROID_AQUI" />
```

### iOS
Edita el archivo `ios/Runner/AppDelegate.swift`:
```swift
GMSServices.provideAPIKey("TU_API_KEY_DE_IOS_AQUI")
```

## 🚨 Importante
- **NO** subas las API keys al control de versiones (Git)
- Mantén las claves seguras y no las compartas
- Configura restricciones adecuadas en Google Cloud Console
- Considera usar variables de entorno para las claves en producción

## 🛡️ Seguridad adicional
- Habilita restricciones por IP si es necesario
- Monitorea el uso de las APIs en Google Cloud Console
- Configura alertas de facturación

---
✅ Una vez configuradas las API keys, la funcionalidad de mapas funcionará correctamente.