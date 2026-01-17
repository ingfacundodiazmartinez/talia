# TaliaShareExtension - Setup Guide

Share Extension que permite compartir contenido desde otras apps a Talia.

## Estado Actual

Los archivos ya estan configurados:
- `ShareViewController.swift` - Logica de la extension
- `Info.plist` - Configuracion de tipos soportados
- `TaliaShareExtension.entitlements` - App Group configurado
- `Podfile` - Target agregado

## Pasos Restantes en Xcode

### 1. Verificar/Configurar Build Settings

1. Abre `Runner.xcworkspace` en Xcode
2. Selecciona el target `TaliaShareExtension`
3. Ve a `Build Settings`:
   - Busca `Info.plist File` y verifica que apunte a `TaliaShareExtension/Info.plist`
   - Busca `Code Signing Entitlements` y verifica que apunte a `TaliaShareExtension/TaliaShareExtension.entitlements`

### 2. Habilitar App Groups (MUY IMPORTANTE)

1. Selecciona el target `TaliaShareExtension`
2. Ve a `Signing & Capabilities`
3. Click en `+ Capability`
4. Selecciona `App Groups`
5. Marca la casilla `group.com.talia.chat`

Si no aparece el grupo, agregalo manualmente con el boton `+`.

### 3. Verificar Embed en Runner

1. Selecciona el target `Runner`
2. Ve a `Build Phases`
3. Expande `Embed Foundation Extensions` (o `Embed App Extensions`)
4. Verifica que `TaliaShareExtension.appex` este en la lista
5. Si no esta, click `+` y agregalo

### 4. Configurar Deployment Target

1. Selecciona el target `TaliaShareExtension`
2. Ve a `General`
3. En `Minimum Deployments`, selecciona iOS 15.5

### 5. Eliminar Referencia al Storyboard (si existe)

Si Xcode creo un storyboard por defecto:
1. En el navegador, busca `MainInterface.storyboard` dentro de TaliaShareExtension
2. Click derecho > Delete > Move to Trash

El Info.plist ya esta configurado para usar `NSExtensionPrincipalClass` en lugar del storyboard.

## Build y Test

```bash
# Limpiar y reconstruir
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ios
```

## Como Funciona

1. Usuario comparte desde otra app y selecciona "Talia"
2. ShareViewController recibe el contenido
3. Copia archivos al App Group container
4. Guarda metadata en UserDefaults compartido
5. Abre la app principal via `talia://share`
6. ShareTargetService lee los datos del App Group
7. ShareTargetSelectionScreen muestra opciones
8. Usuario elige chat o historia

## Tipos Soportados

- Imagenes: hasta 10
- Videos: hasta 5
- Texto: si
- URLs: hasta 1
- Archivos: hasta 10

## Troubleshooting

### Extension no aparece en Share Sheet
- Verifica que el Bundle ID sea `com.talia.chat.TaliaShareExtension`
- Verifica que este embebida en Runner
- Limpia build folder (Cmd+Shift+K) y reconstruye

### App Group no funciona
- Verifica que ambos targets (Runner y TaliaShareExtension) tengan App Groups habilitado
- Verifica que `group.com.talia.chat` este marcado en ambos
- Revisa los entitlements files

### Error de firma
- Verifica que tengas un perfil de provision que incluya el App Group
- Puede que necesites regenerar los perfiles en el Apple Developer Portal
