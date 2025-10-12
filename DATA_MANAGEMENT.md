# 🗄️ Gestión de Datos - Talia

## 📋 Resumen

Guía completa sobre gestión, retención, limpieza y archivado de datos en Talia, con compliance GDPR/CCPA y mejores prácticas de privacidad.

---

## ⏳ Políticas de Retención

### Duración de Almacenamiento

| Tipo de Dato | Retención | Razón | Limpieza |
|--------------|-----------|-------|----------|
| **Mensajes** | 1 año | Balance entre utilidad e privacidad | Automática |
| **Media (fotos/videos)** | 6 meses | Reduce uso de storage | Automática |
| **Ubicaciones** | 30 días | Solo necesarias recientes | Automática |
| **Ubicaciones de emergencia** | 1 año | Evidencia legal | Automática |
| **Emergencias resueltas** | 1 año | Historial importante | Automática |
| **Logs y analytics** | 90 días | Debugging y análisis | Automática |
| **Cache local** | 7 días | Mejora performance | Automática |
| **Cuenta eliminada** | 30 días | Período de gracia | Manual |

### Datos Permanentes

Estos datos se mantienen mientras la cuenta esté activa:

- Perfil de usuario (nombre, foto, teléfono)
- Lista de contactos aprobados
- Configuraciones y preferencias
- Historial de emergency (última emergencia activa)
- Última ubicación conocida

---

## 🧹 Limpieza Automática

### DataManagementService

Servicio centralizado para gestión de datos:

```dart
import 'package:talia/services/data_management_service.dart';

// Inicializar con limpieza automática
await dataManagement.initialize(enableAutoCleanup: true);

// Ejecutar limpieza manual
await dataManagement.performAutomaticCleanup();
```

### Programación de Limpieza

- **Frecuencia**: Diaria a las 3:00 AM
- **Ámbito**: Solo producción (no debug)
- **Operaciones**:
  1. Limpiar mensajes > 1 año
  2. Limpiar media > 6 meses
  3. Limpiar ubicaciones > 30 días
  4. Limpiar emergencias resueltas > 1 año
  5. Limpiar cache local > 7 días

### Operaciones Individuales

```dart
// Limpiar mensajes antiguos
final messagesDeleted = await dataManagement.cleanOldMessages();
print('Deleted $messagesDeleted old messages');

// Limpiar media antiguo
final mediaDeleted = await dataManagement.cleanOldMedia();

// Limpiar ubicaciones antiguas
final locationsDeleted = await dataManagement.cleanOldLocations();

// Limpiar emergencias antiguas
final emergenciesDeleted = await dataManagement.cleanOldEmergencies();

// Limpiar cache local
final cacheDeleted = await dataManagement.cleanLocalCache();
```

---

## 📦 Archivado de Conversaciones

### Archivar

Usuarios pueden archivar conversaciones para ocultarlas sin eliminarlas:

```dart
// Archivar una conversación
await dataManagement.archiveConversation(chatId);

// Desarchivar
await dataManagement.unarchiveConversation(chatId);
```

### UI de Archivado

```dart
// En ChatListScreen
ListTile(
  leading: Icon(Icons.archive),
  title: Text('Archivar Chat'),
  onTap: () async {
    await dataManagement.archiveConversation(chat.id);
    showSnackbar('Chat archivado');
  },
),

// Ver chats archivados
final archivedChats = await _firestore
    .collection('chats')
    .where('archivedBy', arrayContains: currentUserId)
    .get();
```

---

## 🔒 Compliance GDPR/CCPA

### Derecho a Acceso (GDPR Art. 15)

Usuarios pueden solicitar una copia de sus datos:

```dart
// Exportar todos los datos del usuario
final userData = await dataManagement.exportUserData();

// userData contiene:
// - Perfil
// - Chats
// - Contactos
// - Emergencias
// - Ubicaciones
// - Preferencias de notificaciones

// Guardar como JSON
final jsonString = jsonEncode(userData);
await File('user_data.json').writeAsString(jsonString);
```

### Derecho al Olvido (GDPR Art. 17)

Usuarios pueden solicitar eliminación de su cuenta:

#### Paso 1: Solicitar Eliminación

```dart
// Solicitar eliminación (período de gracia de 30 días)
await dataManagement.requestAccountDeletion();

// La cuenta se marca como 'pending_deletion'
// Los datos se eliminarán automáticamente después de 30 días
```

#### Paso 2: Período de Gracia

Durante 30 días:
- Usuario recibe notificación de eliminación pendiente
- Puede cancelar la solicitud
- Puede acceder normalmente a la cuenta

```dart
// Cancelar solicitud de eliminación
await dataManagement.cancelAccountDeletion();
```

#### Paso 3: Eliminación Permanente

Después de 30 días o inmediatamente si el usuario confirma:

```dart
// ADVERTENCIA: Esta operación es IRREVERSIBLE
await dataManagement.deleteAccountPermanently();

// Elimina:
// - Perfil de usuario
// - Contactos
// - Ubicaciones
// - Preferencias
// - Marca chats como 'deletedBy' este usuario
// - Archivos en Storage (avatar)
// - Cuenta de Firebase Authentication
```

### UI para Eliminación de Cuenta

```dart
// En SettingsScreen
class _DeleteAccountSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.delete_forever, color: Colors.red),
          title: Text('Eliminar Cuenta'),
          subtitle: Text('Esta acción es irreversible'),
          onTap: () => _showDeleteAccountDialog(context),
        ),
      ],
    );
  }

  Future<void> _showDeleteAccountDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Eliminar Cuenta?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tu cuenta será eliminada después de 30 días. '
              'Durante este período, puedes cancelar la eliminación.',
            ),
            SizedBox(height: 16),
            Text(
              'Esta acción eliminará:\n'
              '• Tu perfil\n'
              '• Tus contactos\n'
              '• Tus ubicaciones\n'
              '• Tus preferencias',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await dataManagement.requestAccountDeletion();
      showSnackbar('Eliminación programada para 30 días');
    }
  }
}
```

### Derecho a Portabilidad (GDPR Art. 20)

Usuarios pueden exportar sus datos en formato legible:

```dart
// Exportar datos
final userData = await dataManagement.exportUserData();

// Convertir a JSON
final jsonData = jsonEncode(userData);

// Compartir o guardar
Share.share(jsonData, subject: 'Mis datos de Talia');
```

---

## 📊 Estadísticas de Uso

### Obtener Estadísticas

```dart
// Obtener estadísticas de uso de datos
final stats = await dataManagement.getDataUsageStats();

print(stats);
/* Output:
{
  'totalChats': 15,
  'totalMessages': 1234,
  'totalEmergencies': 3,
  'totalContacts': 8,
  'localCacheKeys': 42,
  'generatedAt': '2025-01-20T10:30:00.000Z',
}
*/
```

### UI de Estadísticas

```dart
// En SettingsScreen → Storage & Data
class StorageInfoScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: dataManagement.getDataUsageStats(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }

        final stats = snapshot.data!;

        return ListView(
          children: [
            _buildStatTile('Chats', stats['totalChats']),
            _buildStatTile('Mensajes', stats['totalMessages']),
            _buildStatTile('Emergencias', stats['totalEmergencies']),
            _buildStatTile('Contactos', stats['totalContacts']),
            _buildStatTile('Cache Local', stats['localCacheKeys']),

            SizedBox(height: 20),

            ElevatedButton(
              onPressed: () async {
                await dataManagement.performAutomaticCleanup();
                showSnackbar('Limpieza completada');
              },
              child: Text('Limpiar Datos Antiguos'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatTile(String label, dynamic value) {
    return ListTile(
      title: Text(label),
      trailing: Text(
        value.toString(),
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
```

---

## 🔧 Implementación Técnica

### Firestore Structure

#### Marcadores de Eliminación

```javascript
// En lugar de eliminar inmediatamente, marcar como eliminado
{
  accountStatus: 'pending_deletion',
  deletionRequestedAt: Timestamp,
  scheduledDeletionDate: Timestamp,
}
```

#### Archivado de Chats

```javascript
{
  chatId: 'chat123',
  participants: ['user1', 'user2'],
  archivedBy: ['user1'], // Array de usuarios que archivaron
  archivedAt: Timestamp,
}
```

### Cloud Functions para Limpieza

Para producción, se recomienda implementar limpieza con Cloud Functions:

```javascript
// functions/src/scheduledCleanup.ts

import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

export const scheduledCleanup = functions.pubsub
  .schedule('0 3 * * *') // Diariamente a las 3 AM
  .timeZone('America/New_York')
  .onRun(async (context) => {
    const firestore = admin.firestore();

    // Limpiar mensajes antiguos
    const oneYearAgo = new Date();
    oneYearAgo.setFullYear(oneYearAgo.getFullYear() - 1);

    const chats = await firestore.collection('chats').get();

    for (const chatDoc of chats.docs) {
      const oldMessages = await chatDoc.ref
        .collection('messages')
        .where('timestamp', '<', oneYearAgo)
        .get();

      const batch = firestore.batch();
      oldMessages.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
    }

    console.log('Scheduled cleanup completed');
  });

// Función para eliminar cuentas pendientes
export const deleteScheduledAccounts = functions.pubsub
  .schedule('0 4 * * *') // Diariamente a las 4 AM
  .onRun(async (context) => {
    const firestore = admin.firestore();
    const now = admin.firestore.Timestamp.now();

    // Buscar cuentas programadas para eliminación
    const accountsToDelete = await firestore
      .collection('users')
      .where('accountStatus', '==', 'pending_deletion')
      .where('scheduledDeletionDate', '<=', now)
      .get();

    for (const doc of accountsToDelete.docs) {
      const userId = doc.id;

      // Eliminar todos los datos del usuario
      await deleteUserData(userId);

      // Eliminar cuenta de Authentication
      await admin.auth().deleteUser(userId);

      console.log(`Deleted account: ${userId}`);
    }
  });
```

---

## 🧪 Testing

### Test Manual

```markdown
## Checklist de Testing de Data Management

### Limpieza Automática
- [ ] Limpieza se ejecuta diariamente a las 3 AM
- [ ] No se ejecuta en modo debug
- [ ] Mensajes > 1 año se eliminan
- [ ] Media > 6 meses se elimina
- [ ] Ubicaciones > 30 días se eliminan
- [ ] Cache > 7 días se limpia

### Archivado
- [ ] Archivar chat oculta el chat de la lista principal
- [ ] Desarchivar restaura el chat
- [ ] Chat archivado por un usuario no afecta al otro

### Exportación de Datos
- [ ] Exportar incluye todos los datos del usuario
- [ ] JSON es válido y legible
- [ ] Incluye timestamp de exportación

### Eliminación de Cuenta
- [ ] Solicitar eliminación marca cuenta como pending_deletion
- [ ] Período de gracia de 30 días funciona
- [ ] Cancelar eliminación restaura cuenta
- [ ] Eliminación permanente borra todos los datos
- [ ] Usuario no puede hacer login después de eliminación

### Estadísticas
- [ ] Mostrar conteo correcto de chats
- [ ] Mostrar conteo correcto de mensajes
- [ ] Mostrar conteo correcto de emergencias
- [ ] Mostrar uso de cache local
```

### Tests Automatizados

```dart
// test/services/data_management_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/data_management_service.dart';

void main() {
  group('RetentionPolicy', () {
    test('messages retention is 1 year', () {
      expect(RetentionPolicy.messages, const Duration(days: 365));
    });

    test('media retention is 6 months', () {
      expect(RetentionPolicy.media, const Duration(days: 180));
    });

    test('locations retention is 30 days', () {
      expect(RetentionPolicy.locations, const Duration(days: 30));
    });

    test('deleted user data retention is 30 days', () {
      expect(RetentionPolicy.deletedUserData, const Duration(days: 30));
    });
  });

  group('DataManagementService', () {
    late DataManagementService service;

    setUp(() {
      service = DataManagementService();
    });

    test('singleton pattern works', () {
      final instance1 = dataManagement;
      final instance2 = dataManagement;
      expect(identical(instance1, instance2), true);
    });

    test('initialize sets up automatic cleanup', () async {
      await service.initialize(enableAutoCleanup: false);
      // Verify initialization
    });
  });
}
```

---

## 🚨 Troubleshooting

### Problema: Limpieza no se ejecuta automáticamente

**Causa**: Timer no programado o app cerrada

**Solución**:
- Implementar como Cloud Function para confiabilidad
- Verificar que `enableAutoCleanup: true`
- Verificar que no esté en modo debug

### Problema: Exportación de datos falla

**Causa**: Usuario tiene demasiados datos

**Solución**:
- Implementar exportación por lotes
- Comprimir datos antes de enviar
- Usar Cloud Function para exportación grande

### Problema: Eliminación permanente falla

**Causa**: Errores de permisos o datos huérfanos

**Solución**:
- Verificar reglas de Firestore
- Implementar eliminación transaccional
- Logs detallados para debugging

---

## 📚 Recursos

### GDPR
- [GDPR Official Text](https://gdpr-info.eu/)
- [Article 15 - Right of access](https://gdpr-info.eu/art-15-gdpr/)
- [Article 17 - Right to erasure](https://gdpr-info.eu/art-17-gdpr/)
- [Article 20 - Right to data portability](https://gdpr-info.eu/art-20-gdpr/)

### CCPA
- [California Consumer Privacy Act](https://oag.ca.gov/privacy/ccpa)

### Firebase
- [Data Deletion on Cloud Firestore](https://firebase.google.com/docs/firestore/manage-data/delete-data)
- [Cloud Functions Scheduled Functions](https://firebase.google.com/docs/functions/schedule-functions)

---

## 📧 Soporte

Para consultas sobre gestión de datos:
- **Email**: privacy@talia-app.com
- **DPO**: dpo@talia-app.com (Data Protection Officer)

---

**Última actualización:** Enero 2025
