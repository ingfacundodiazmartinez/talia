# MessageBubble - Arquitectura Modular

Este directorio contiene la implementación modular del widget `MessageBubble`, refactorizado desde un archivo monolítico de 995 líneas a una arquitectura basada en componentes.

## Estructura de Archivos

### Archivo Principal
- **message_bubble.dart** (351 líneas) - Widget principal que orquesta todos los componentes

### Componentes de Contenido
- **blocked_message_content.dart** (93 líneas) - UI para mensajes bloqueados por moderación
- **reply_preview_widget.dart** (124 líneas) - Vista previa de mensajes respondidos
- **image_message_content.dart** (167 líneas) - Renderizado de mensajes con imágenes
- **video_message_content.dart** (115 líneas) - Renderizado de mensajes con videos
- **audio_message_content.dart** (70 líneas) - Renderizado de mensajes con audios
- **text_message_content.dart** (29 líneas) - Renderizado de mensajes de texto

### Componentes de Metadatos
- **message_timestamp.dart** (31 líneas) - Timestamp de mensajes
- **message_reactions.dart** (82 líneas) - Sistema de reacciones a mensajes
- **group_chat_avatar.dart** (36 líneas) - Avatares para chats grupales

### Servicios y Lógica
- **media_gallery_service.dart** (64 líneas) - Servicio para construir galerías de medios
- **message_options_dialog.dart** (101 líneas) - Diálogos de opciones (reaccionar, eliminar)

## Métricas de Refactorización

### Antes
- **1 archivo**: 995 líneas
- Responsabilidades mezcladas
- Dificultad para mantener y testear
- Lógica de negocio mezclada con UI

### Después
- **12 archivos**: 1,263 líneas totales (351 líneas en archivo principal)
- **Reducción de 64.7%** en archivo principal (995 → 351 líneas)
- Separación de responsabilidades clara
- Componentes reutilizables
- Fácil de testear individualmente
- Lógica de negocio separada (servicio de galería)

## Beneficios de la Arquitectura

### 1. Mantenibilidad
- Cada componente tiene una responsabilidad única
- Fácil localizar y modificar funcionalidad específica
- Reducción de conflictos en control de versiones

### 2. Reusabilidad
- Componentes pueden usarse en otros contextos
- `GroupChatAvatar` es reutilizable en otras pantallas
- `MediaGalleryService` puede usarse fuera de mensajes

### 3. Testabilidad
- Cada componente puede testearse aisladamente
- Mocks más simples para testing unitario
- Tests más focalizados y rápidos

### 4. Escalabilidad
- Fácil agregar nuevos tipos de contenido (ej: polls, ubicaciones)
- Nuevos componentes no afectan a los existentes
- Arquitectura preparada para crecimiento

## Flujo de Datos

```
MessageBubble (Principal)
    ├── GroupChatAvatar
    ├── BlockedMessageContent
    ├── ReplyPreviewWidget
    ├── ImageMessageContent
    │   └── MediaGalleryService
    ├── VideoMessageContent
    │   └── MediaGalleryService
    ├── AudioMessageContent
    ├── TextMessageContent
    ├── MessageTimestamp
    ├── MessageReactions
    └── MessageOptionsDialog
```

## Uso

### Importar el widget principal
```dart
import 'package:talia/screens/chat/widgets/message_bubble.dart';
```

### Uso básico
```dart
MessageBubble(
  messageId: 'msg_123',
  chatId: 'chat_456',
  text: 'Hola mundo',
  isMe: true,
  time: '10:30 AM',
  senderId: 'user_789',
  senderName: 'John Doe',
)
```

## Consideraciones de Performance

- **RepaintBoundary**: El widget principal usa `RepaintBoundary` para optimizar repaints
- **Lazy Loading**: Los componentes de media solo se cargan cuando son necesarios
- **Cache**: Uso de `CachedNetworkImage` para imágenes
- **Animaciones**: Animaciones suaves y performantes (150ms)

## Próximas Mejoras Sugeridas

1. Extraer lógica de animación a un mixin reutilizable
2. Crear tests unitarios para cada componente
3. Implementar localización (i18n) para textos hardcodeados
4. Considerar usar Provider/Riverpod para gestión de estado
5. Añadir analytics para medir interacciones
