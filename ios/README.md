# Talia - Chat App con Control Parental

Una aplicación de mensajería Flutter con control parental avanzado, videollamadas y características de seguridad para familias.

## Descripción

Talia es una aplicación de chat diseñada para permitir que niños se comuniquen de manera segura bajo la supervisión de sus padres. Los padres pueden monitorear actividades, aprobar contactos, recibir alertas y establecer controles de seguridad.

## Características Principales

### Para Niños
- Chat individual y grupal
- Videollamadas con filtros AR (DeepAR)
- Historias temporales (24 horas)
- Botón de emergencia
- Compartir ubicación en tiempo real

### Para Padres
- Panel de control parental
- Aprobación de contactos (whitelist)
- Monitoreo de actividades
- Análisis de mensajes con IA (Gemini)
- Reportes semanales automáticos
- Alertas de actividad sospechosa
- Gestión de múltiples hijos

### Seguridad
- Firebase App Check (App Attest/Play Integrity)
- Autenticación con teléfono (Firebase Auth)
- Firestore Security Rules completas
- Rate Limiting en Cloud Functions
- Validación de inputs
- Crashlytics para monitoreo de errores
- Variables de entorno protegidas

## Requisitos Previos

- **Flutter SDK**: ^3.9.2
- **Node.js**: 20+ (para Cloud Functions)
- **Firebase CLI**: Instalado y configurado
- **Xcode**: 15+ (para iOS)
- **Android Studio**: (para Android)
- **CocoaPods**: (para dependencias iOS)

### Cuentas Necesarias
- Cuenta de Firebase con proyecto configurado
- Cuenta de Agora (para videollamadas)
- Google Cloud Platform (habilitado para el proyecto)
- Apple Developer Account (para iOS)
- Google Play Console (para Android)

## Instalación

### 1. Clonar el Repositorio
\`\`\`bash
git clone <repository-url>
cd talia
\`\`\`

### 2. Instalar Dependencias de Flutter
\`\`\`bash
flutter pub get
\`\`\`

### 3. Configurar Firebase

#### Inicializar FlutterFire
\`\`\`bash
flutterfire configure
\`\`\`

#### Configurar App Check Debug Tokens
\`\`\`bash
# iOS
firebase appcheck:debug:create --ios-bundle-id com.talia.chat

# Android
firebase appcheck:debug:create --android-package-name com.talia.chat
\`\`\`

Registra los tokens generados en Firebase Console > App Check.

### 4. Configurar Cloud Functions

\`\`\`bash
cd functions
npm install
\`\`\`

Crea el archivo \`.env\` en \`functions/\`:
\`\`\`bash
# Agora Credentials
AGORA_APP_ID=tu_agora_app_id
AGORA_APP_CERTIFICATE=tu_agora_certificate
\`\`\`

### 5. Configurar iOS

\`\`\`bash
cd ios
pod install
cd ..
\`\`\`

**Configuración de APNs** (para Phone Auth):
1. Crea un APNs Authentication Key en Apple Developer
2. Sube el archivo \`.p8\` a Firebase Console > Project Settings > Cloud Messaging

### 6. Configurar Android

**Keystore para Release** (opcional, para producción):
\`\`\`bash
cd android
# El archivo key.properties ya existe, actualiza las credenciales si es necesario
\`\`\`

## Estructura del Proyecto

\`\`\`
talia/
├── lib/                      # Código Flutter
│   ├── screens/             # Pantallas de la app
│   ├── widgets/             # Widgets reutilizables
│   ├── services/            # Servicios (Firebase, notificaciones, etc.)
│   └── main.dart           # Punto de entrada
├── functions/               # Cloud Functions (Node.js)
│   ├── index.js            # Funciones principales
│   ├── .env                # Variables de entorno (NO en git)
│   └── package.json        # Dependencias
├── firestore.rules         # Reglas de seguridad de Firestore
├── firestore.indexes.json  # Índices de Firestore
├── test/                   # Tests
│   └── firestore_rules/    # Tests de reglas de seguridad
├── ios/                    # Configuración iOS
├── android/                # Configuración Android
└── README.md               # Este archivo
\`\`\`

## Cloud Functions

### Funciones Callable
- \`generateAgoraToken\`: Genera tokens de Agora para videollamadas
- \`generateChildReport\`: Genera reportes de actividad de un niño
- \`createParentChildLink\`: Vincula un padre con un hijo

### Funciones Programadas
- \`cleanupExpiredStories\`: Limpia historias expiradas (diario, 2 AM)
- \`autoResolveEmergencies\`: Resuelve emergencias antiguas (cada hora)
- \`cleanupOldRateLimits\`: Limpia rate limits viejos (semanal, domingos 3 AM)

### Funciones Trigger
- \`sendNotificationOnCreate\`: Envía notificaciones push automáticas

## Testing

### Ejecutar Tests de Firestore Rules
\`\`\`bash
npm test
\`\`\`

Corre 17 tests que validan:
- Protección de roles de usuario
- Prevención de spam en notificaciones
- Validación de permisos en chats
- Límites de caracteres en mensajes
- Rate limits de solo lectura

### Ejecutar Tests de Cloud Functions (Emulador)
\`\`\`bash
firebase emulators:start
\`\`\`

## Despliegue

### Deploy Completo
\`\`\`bash
firebase deploy
\`\`\`

### Deploy Específico

**Solo Cloud Functions:**
\`\`\`bash
firebase deploy --only functions
\`\`\`

**Solo Firestore Rules:**
\`\`\`bash
firebase deploy --only firestore:rules
\`\`\`

**Solo Indexes:**
\`\`\`bash
firebase deploy --only firestore:indexes
\`\`\`

## Seguridad Implementada

### ✅ App Check - Modo Estricto
- Verificación de instancias legítimas de la app
- Rechazo automático de solicitudes sin token válido
- Modo debug para desarrollo

### ✅ Rate Limiting
- \`generateAgoraToken\`: 20 solicitudes/minuto
- \`generateChildReport\`: 10 solicitudes/hora
- \`createParentChildLink\`: 5 solicitudes/hora
- Sistema basado en transacciones de Firestore (thread-safe)

### ✅ Firestore Security Rules
- **users**: Protección de campos críticos (role, email, parentId)
- **notifications**: Solo Cloud Functions pueden crear
- **chats/messages**: Máximo 5000 caracteres, validación de participantes
- **activities/alerts**: Solo padres vinculados
- **parent_child_links**: Solo Cloud Functions pueden modificar
- **rate_limits**: Solo lectura para usuarios

### ✅ Validación de Inputs
- Validación de channelName (alfanumérico, máx 64 chars)
- Validación de UIDs de Agora (0-4,294,967,295)
- Prevención de inyecciones SQL/NoSQL
- Sanitización de strings

### ✅ Crashlytics
- Reportes automáticos de crashes
- Captura de errores de Flutter y Dart
- Deshabilitado en modo debug
- Símbolos de debug cargados automáticamente

**Para más detalles, consulta:** [SECURITY_AUDIT.md](SECURITY_AUDIT.md)

## Configuración de Producción

### iOS

1. **App Store Connect**
   - Configura el app en App Store Connect
   - Sube capturas de pantalla y descripción
   - Configura App Attest en Firebase Console

2. **Build de Release**
   \`\`\`bash
   flutter build ios --release
   \`\`\`

3. **Archive y Upload**
   - Abre Xcode, selecciona "Product > Archive"
   - Sube a App Store Connect

### Android

1. **Google Play Console**
   - Crea la app en Play Console
   - Configura Play Integrity en Firebase Console
   - Registra el SHA-256 del keystore en Firebase

2. **Build de Release**
   \`\`\`bash
   flutter build appbundle --release
   \`\`\`

3. **Upload**
   - Sube el \`.aab\` a Play Console
   - Configura internal/alpha testing antes de producción

## Monitoreo en Producción

### Firebase Console
- **Cloud Functions Logs**: Monitorea ejecuciones y errores
- **Crashlytics**: Analiza crashes y ANRs
- **Performance**: Revisa métricas de rendimiento
- **Analytics**: Analiza comportamiento de usuarios

### Comandos Útiles

**Ver logs de Cloud Functions:**
\`\`\`bash
firebase functions:log
\`\`\`

**Limpiar rate limit de un usuario:**
\`\`\`bash
firebase firestore:delete rate_limits/{userId}_{action}
\`\`\`

**Iniciar emulador local:**
\`\`\`bash
firebase emulators:start
\`\`\`

## Troubleshooting

### Error: "App Check token verification failed"
**Solución**: Registra el debug token en Firebase Console > App Check

### Error: "Rate limit exceeded"
**Solución**: Espera el tiempo indicado o limpia manualmente el rate limit

### Error: "Permission denied" en Firestore
**Solución**: Verifica que las reglas de seguridad estén desplegadas

### Error: APNs token no disponible (iOS)
**Solución**:
1. Verifica que el archivo .p8 esté cargado en Firebase
2. Configura los capabilities en Xcode (Push Notifications)
3. Espera unos segundos tras abrir la app

## Contribuir

1. Fork el proyecto
2. Crea una rama para tu feature (\`git checkout -b feature/AmazingFeature\`)
3. Commit tus cambios (\`git commit -m 'Add some AmazingFeature'\`)
4. Push a la rama (\`git push origin feature/AmazingFeature\`)
5. Abre un Pull Request

## Licencia

Este proyecto es privado y está bajo licencia propietaria.

## Contacto

Para soporte o consultas sobre el proyecto, contacta al equipo de desarrollo.

---

**Última actualización**: Octubre 2025
**Versión**: 1.0.0
