# 🔔 Sistema de Notificaciones - Guía Completa

## 📋 Resumen

Sistema completo de notificaciones push con prioridades, preferencias personalizables y control granular.

### ✨ Características

1. **Preferencias Personalizables** - Control total sobre qué notificar
2. **Modo No Molestar** - Silenciar notificaciones por horario
3. **Silenciar Chats** - Mutear conversaciones individuales
4. **Prioridades** - Crítico, Alta, Normal, Baja
5. **Sonidos y Vibración** - Configurables por tipo
6. **Pantalla de Configuración** - UI completa para ajustes

---

## 🎯 1. NotificationPreferencesService

### Descripción
Servicio que gestiona preferencias de notificaciones almacenadas en Firestore.

### Preferencias Disponibles

```dart
// Tipos de notificaciones
messagesEnabled: bool          // Mensajes de texto
contactRequestsEnabled: bool   // Solicitudes de contacto
activityAlertsEnabled: bool    // Alertas de actividad
missedCallsEnabled: bool       // Llamadas perdidas
locationAlertsEnabled: bool    // Alertas de ubicación
whitelistChangesEnabled: bool  // Cambios en whitelist

// Sonido y Vibración
soundEnabled: bool             // Sonido general
vibrationEnabled: bool         // Vibración
inAppSoundEnabled: bool       // Sonidos dentro de la app
notificationTone: String      // Tono de notificación

// No Molestar
doNotDisturbEnabled: bool      // Activar DND
dndStartTime: String          // Hora inicio (ej: "22:00")
dndEndTime: String            // Hora fin (ej: "07:00")
dndExceptions: List<String>   // IDs de contactos excluidos
```

### Uso Básico

```dart
import 'package:talia/services/notification_preferences_service.dart';

final service = NotificationPreferencesService();

// Obtener preferencias
final prefs = await service.getPreferences();
print('Mensajes habilitados: ${prefs['messagesEnabled']}');

// Actualizar una preferencia
await service.updatePreference('soundEnabled', true);

// Actualizar múltiples
await service.updateMultiplePreferences({
  'soundEnabled': true,
  'vibrationEnabled': false,
  'doNotDisturbEnabled': true,
});

// Stream de cambios
service.preferencesStream().listen((prefs) {
  print('Preferencias actualizadas: $prefs');
});

// Verificar si mostrar notificación
final shouldShow = await service.shouldShowNotification(contactId);
if (shouldShow) {
  // Mostrar notificación
}
```

---

## 🚫 2. Modo No Molestar

### Configuración de Horario

```dart
// Activar No Molestar
await service.updatePreference('doNotDisturbEnabled', true);

// Configurar horario (22:00 - 07:00)
await service.updateMultiplePreferences({
  'dndStartTime': '22:00',
  'dndEndTime': '07:00',
});
```

### Verificar si Está en Horario DND

```dart
// El servicio verifica automáticamente
final shouldShow = await service.shouldShowNotification(contactId);

// También puedes verificar manualmente
final now = TimeOfDay.now();
final start = service.parseTime('22:00');
final end = service.parseTime('07:00');

final isInDnd = service.isInDoNotDisturbPeriod(now, start, end);
```

### Excepciones de DND

```dart
// Agregar contacto a excepciones (siempre notifica)
final prefs = await service.getPreferences();
final exceptions = List<String>.from(prefs['dndExceptions'] ?? []);
exceptions.add(contactId);

await service.updatePreference('dndExceptions', exceptions);
```

---

## 🔇 3. Silenciar Chats Individuales

### Usar el Dialog

```dart
import 'package:talia/widgets/mute_chat_dialog.dart';

// Mostrar dialog de mutear
final muted = await MuteChatDialog.show(
  context,
  chatId: 'chat123',
  chatName: 'Juan Pérez',
);

if (muted == true) {
  print('Chat silenciado');
}
```

### Opciones de Duración

El dialog ofrece:
- 15 minutos
- 1 hora
- 8 horas
- 1 día
- 1 semana
- Siempre (indefinido)

### Implementación Manual

```dart
// Silenciar chat por 1 hora
final mutedUntil = DateTime.now().add(Duration(hours: 1));

await FirebaseFirestore.instance
    .collection('users')
    .doc(userId)
    .collection('muted_chats')
    .doc(chatId)
    .set({
  'chatId': chatId,
  'mutedAt': FieldValue.serverTimestamp(),
  'mutedUntil': mutedUntil.toIso8601String(),
});

// Silenciar indefinidamente (no incluir mutedUntil)
await FirebaseFirestore.instance
    .collection('users')
    .doc(userId)
    .collection('muted_chats')
    .doc(chatId)
    .set({
  'chatId': chatId,
  'mutedAt': FieldValue.serverTimestamp(),
});

// Desmutear
await FirebaseFirestore.instance
    .collection('users')
    .doc(userId)
    .collection('muted_chats')
    .doc(chatId)
    .delete();
```

### Verificar si Chat Está Muteado

```dart
final snapshot = await FirebaseFirestore.instance
    .collection('users')
    .doc(userId)
    .collection('muted_chats')
    .doc(chatId)
    .get();

if (snapshot.exists) {
  final data = snapshot.data()!;
  final mutedUntilStr = data['mutedUntil'] as String?;

  if (mutedUntilStr != null) {
    final mutedUntil = DateTime.parse(mutedUntilStr);
    if (DateTime.now().isBefore(mutedUntil)) {
      print('Chat silenciado hasta $mutedUntil');
    }
  } else {
    print('Chat silenciado indefinidamente');
  }
}
```

---

## 🎨 4. Indicador de Chat Muteado

### Widget

```dart
import 'package:talia/widgets/mute_chat_dialog.dart';

// En el ListTile del chat
ListTile(
  title: Text(chatName),
  trailing: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      MutedChatIndicator(chatId: chatId),
      // Otros widgets
    ],
  ),
)
```

El indicador:
- Muestra ícono 🔕 si el chat está muteado
- Tooltip con tiempo restante
- Se actualiza en tiempo real
- Se oculta automáticamente cuando expira

---

## 🔔 5. Prioridades de Notificaciones

### Niveles

```dart
enum NotificationPriority {
  critical,  // Emergencias - Siempre notifica
  high,      // Llamadas - Alta prioridad
  normal,    // Mensajes - Prioridad normal
  low,       // Actualizaciones - Baja prioridad
}
```

### Uso

```dart
NotificationPriority getPriority(String messageType, bool isEmergency) {
  if (isEmergency) return NotificationPriority.critical;

  switch (messageType) {
    case 'call':
    case 'video_call':
      return NotificationPriority.high;
    case 'message':
      return NotificationPriority.normal;
    default:
      return NotificationPriority.low;
  }
}
```

### Valores Nativos

```dart
// Android
final priority = NotificationPriority.high;
final androidPriority = priority.androidPriority; // 4 (HIGH_PRIORITY)

// iOS
final iosLevel = priority.iosInterruptionLevel; // "time-sensitive"
```

Mapeo:
- **Critical** → Android MAX (5), iOS critical
- **High** → Android HIGH (4), iOS time-sensitive
- **Normal** → Android DEFAULT (3), iOS active
- **Low** → Android LOW (2), iOS passive

---

## ⚙️ 6. Pantalla de Configuración

### Navegación

```dart
import 'package:talia/screens/common/notification_settings_screen.dart';

// Navegar a configuración
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => NotificationSettingsScreen(),
  ),
);
```

### Secciones

1. **Tipos de Notificaciones**
   - Mensajes
   - Llamadas perdidas
   - Solicitudes de contacto
   - Alertas de actividad
   - Alertas de ubicación

2. **Sonido y Vibración**
   - Sonido general
   - Vibración
   - Sonidos en la app

3. **No Molestar**
   - Activar/desactivar
   - Configurar horario

4. **Información**
   - Guía de prioridades
   - Tips de uso

---

## 📝 Ejemplo de Integración Completa

### En el Chat Screen

```dart
class ChatScreen extends StatelessWidget {
  final String chatId;
  final String chatName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(chatName),
            SizedBox(width: 8),
            MutedChatIndicator(chatId: chatId),
          ],
        ),
        actions: [
          PopupMenuButton(
            itemBuilder: (context) => [
              PopupMenuItem(
                child: Text('Silenciar notificaciones'),
                onTap: () {
                  Future.delayed(Duration.zero, () {
                    MuteChatDialog.show(
                      context,
                      chatId: chatId,
                      chatName: chatName,
                    );
                  });
                },
              ),
              PopupMenuItem(
                child: Text('Configuración de notificaciones'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => NotificationSettingsScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
      body: MessageList(),
    );
  }
}
```

### Al Enviar Notificación

```dart
Future<void> sendNotification({
  required String userId,
  required String title,
  required String body,
  required String chatId,
  String messageType = 'message',
  bool isEmergency = false,
}) async {
  final service = NotificationPreferencesService();

  // 1. Verificar preferencias
  final prefs = await service.getPreferences();

  if (!prefs['messagesEnabled'] && messageType == 'message') {
    print('Notificaciones de mensajes deshabilitadas');
    return;
  }

  // 2. Verificar DND y chat muteado
  final shouldShow = await service.shouldShowNotification(userId);

  // Emergencias siempre se muestran
  if (!shouldShow && !isEmergency) {
    print('Notificación bloqueada por DND o chat muteado');
    return;
  }

  // Verificar si chat está muteado
  final mutedDoc = await FirebaseFirestore.instance
      .collection('users')
      .doc(userId)
      .collection('muted_chats')
      .doc(chatId)
      .get();

  if (mutedDoc.exists && !isEmergency) {
    print('Chat muteado');
    return;
  }

  // 3. Obtener prioridad
  final priority = getPriority(messageType, isEmergency);

  // 4. Enviar notificación con prioridad
  await sendPushNotification(
    userId: userId,
    title: title,
    body: body,
    priority: priority,
    sound: prefs['soundEnabled'],
    vibration: prefs['vibrationEnabled'],
  );
}
```

---

## 🎯 Mejores Prácticas

### 1. Siempre Respetar Preferencias del Usuario

```dart
// ✅ BIEN
final shouldShow = await service.shouldShowNotification(contactId);
if (shouldShow) {
  sendNotification();
}

// ❌ MAL
sendNotification(); // Ignora preferencias
```

### 2. Emergencias Siempre Notifican

```dart
// ✅ BIEN
if (isEmergency) {
  sendNotification(); // Bypass DND y mute
} else {
  if (shouldShow) sendNotification();
}

// ❌ MAL
if (shouldShow) sendNotification(); // Bloquea emergencias
```

### 3. Limpiar Mutes Expirados

```dart
// Background job que limpia chats muteados expirados
Future<void> cleanupExpiredMutes() async {
  final snapshot = await FirebaseFirestore.instance
      .collection('users')
      .doc(userId)
      .collection('muted_chats')
      .get();

  final now = DateTime.now();

  for (final doc in snapshot.docs) {
    final mutedUntilStr = doc.data()['mutedUntil'] as String?;
    if (mutedUntilStr != null) {
      final mutedUntil = DateTime.parse(mutedUntilStr);
      if (now.isAfter(mutedUntil)) {
        await doc.reference.delete();
      }
    }
  }
}
```

### 4. Feedback Claro

```dart
// ✅ BIEN
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text('Chat silenciado por 1 hora'),
    action: SnackBarAction(
      label: 'Deshacer',
      onPressed: unmute,
    ),
  ),
);

// ❌ MAL
// Sin feedback, usuario no sabe qué pasó
```

---

## 📊 Estructura de Datos en Firestore

### notification_preferences/{userId}

```json
{
  "messagesEnabled": true,
  "contactRequestsEnabled": true,
  "activityAlertsEnabled": true,
  "missedCallsEnabled": true,
  "locationAlertsEnabled": false,
  "soundEnabled": true,
  "vibrationEnabled": true,
  "inAppSoundEnabled": true,
  "notificationTone": "default",
  "doNotDisturbEnabled": false,
  "dndStartTime": "22:00",
  "dndEndTime": "07:00",
  "dndExceptions": [],
  "updatedAt": "2024-01-15T10:30:00Z"
}
```

### users/{userId}/muted_chats/{chatId}

```json
{
  "chatId": "chat123",
  "chatName": "Juan Pérez",
  "mutedAt": "2024-01-15T10:00:00Z",
  "mutedUntil": "2024-01-15T11:00:00Z"  // null si es indefinido
}
```

---

## ✅ Checklist de Implementación

### Servicios Implementados
- [x] NotificationPreferencesService
- [x] Preferencias en Firestore
- [x] Modo No Molestar con horario
- [x] Silenciar chats con duración

### UI Implementada
- [x] NotificationSettingsScreen
- [x] MuteChatDialog con opciones de tiempo
- [x] MutedChatIndicator en chats

### Pendiente de Integrar
- [ ] Agregar a menu de settings
- [ ] Integrar en notification_service.dart existente
- [ ] Limpiar mutes expirados (background job)
- [ ] Tests unitarios
- [ ] Sonidos personalizados por contacto

---

## 🚀 Próximos Pasos

1. **Integrar en NotificationService Existente**
   - Usar NotificationPreferencesService antes de enviar notificaciones
   - Verificar prioridades
   - Respetar mutes y DND

2. **Agregar a Settings**
   - Link en pantalla principal de configuración
   - Badge si hay novedades

3. **Sonidos Personalizados**
   - Permitir elegir tono por contacto
   - Subir sonidos custom

4. **Background Jobs**
   - Limpiar mutes expirados diariamente
   - Sincronizar preferencias

5. **Analytics**
   - Track cambios de preferencias
   - Medir uso de DND y mutes

---

## 📝 Notas de Implementación

- Preferencias en Firestore para sync multi-dispositivo
- Chats muteados en subcollection para escalabilidad
- Modo DND respeta excepciones de contactos importantes
- Emergencias siempre bypasean todas las restricciones
- UI intuitiva con feedback inmediato
- Compatible con iOS y Android
