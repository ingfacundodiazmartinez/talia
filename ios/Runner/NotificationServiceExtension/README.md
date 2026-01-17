# Notification Service Extension

NSE minimalista que descarga la foto del sender para mostrarla en notificaciones push.

## Funcionalidad
- Intercepta notificaciones push con `mutable-content: 1`
- Descarga la foto del sender desde `senderPhotoUrl`
- Adjunta la foto a la notificación antes de mostrarla

## Sin logica compleja
- NO hace deduplicacion
- NO sincroniza con App Groups
- Solo descarga fotos
