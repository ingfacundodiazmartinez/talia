# Notification Service Extension - Instrucciones de Configuración

Este extension permite mostrar la foto del contacto en las notificaciones de iOS.

## Archivos Creados

1. `NotificationService.swift` - Código que descarga y adjunta la imagen
2. `Info.plist` - Configuración del extension

## Pasos para Agregar el Target en Xcode

### 1. Abrir el proyecto en Xcode

```bash
open ios/Runner.xcworkspace
```

### 2. Agregar el Notification Service Extension Target

1. En Xcode, selecciona el proyecto "Runner" en el navegador izquierdo
2. Click en el botón "+" en la parte inferior de la sección "TARGETS"
3. Busca "Notification Service Extension"
4. Click "Next"
5. Configura el extension:
   - **Product Name**: `NotificationServiceExtension`
   - **Team**: Selecciona tu equipo de desarrollo
   - **Bundle Identifier**: `com.talia.chat.NotificationServiceExtension`
   - **Language**: Swift
6. Click "Finish"
7. Cuando pregunte si deseas activar el esquema, selecciona "Cancel" (no es necesario)

### 3. Reemplazar los Archivos Generados

Xcode habrá creado automáticamente algunos archivos. Necesitas reemplazarlos con los que ya existen:

1. En el navegador de Xcode, encuentra la carpeta `NotificationServiceExtension` que se creó
2. Elimina el archivo `NotificationService.swift` que Xcode generó
3. Arrastra los archivos que ya existen desde Finder a Xcode:
   - `ios/NotificationServiceExtension/NotificationService.swift`
   - `ios/NotificationServiceExtension/Info.plist`
4. Asegúrate de marcar la casilla "Copy items if needed" y selecciona el target `NotificationServiceExtension`

### 4. Configurar el Bundle Identifier

1. Selecciona el target `NotificationServiceExtension` en Xcode
2. Ve a la pestaña "General"
3. Asegúrate de que el Bundle Identifier sea: `com.talia.chat.NotificationServiceExtension`

### 5. Configurar Signing & Capabilities

1. Selecciona el target `NotificationServiceExtension`
2. Ve a la pestaña "Signing & Capabilities"
3. Selecciona el mismo equipo de desarrollo que usas para el target principal "Runner"
4. Asegúrate de que "Automatically manage signing" esté habilitado

### 6. Verificar la Configuración

1. Construye el proyecto (Cmd+B)
2. Verifica que no haya errores de compilación

## ¿Qué hace este Extension?

Cuando llega una notificación push con un campo `imageUrl` en el payload:

1. El extension intercepta la notificación antes de que se muestre
2. Descarga la imagen desde la URL proporcionada
3. Adjunta la imagen a la notificación
4. La notificación se muestra con la foto del contacto como ícono principal

## Cambios en el Backend

El código de Firebase Functions ya fue modificado para:

1. Obtener el `photoURL` del usuario que envía el mensaje
2. Incluirlo en el payload de la notificación como `imageUrl`
3. Activar el flag `mutableContent` en APNS para que el extension pueda interceptar la notificación

## Testing

Para probar:

1. Asegúrate de que el usuario que envía mensajes tenga una foto de perfil (photoURL) en Firestore
2. Envía un mensaje desde ese usuario
3. La notificación debería aparecer con la foto del contacto

## Troubleshooting

Si las notificaciones no muestran la imagen:

1. Verifica que el target `NotificationServiceExtension` esté compilado correctamente
2. Revisa los logs de la consola en Xcode al recibir una notificación
3. Verifica que el `photoURL` del sender existe en Firestore
4. Asegúrate de que la URL de la imagen sea accesible públicamente
