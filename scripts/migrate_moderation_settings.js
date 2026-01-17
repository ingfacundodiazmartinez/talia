/**
 * Script de migración para unificar atributos de moderación
 *
 * Migra:
 * - Campos antiguos de moderación en documento `users` a `moderationSettings` en documento `contacts`
 * - NO toca los chats (la moderación de chat es diferente - activada por padres)
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

async function migrateModeration() {
  try {
    console.log('\n🔄 ========== MIGRACIÓN DE MODERACIÓN ==========\n');

    // 1. Obtener todos los usuarios que tengan configuración de moderación
    console.log('📱 Buscando usuarios con moderación configurada...\n');
    const usersSnapshot = await db.collection('users').get();

    const usersWithModeration = [];
    usersSnapshot.forEach(doc => {
      const data = doc.data();
      if (data.moderationEnabled !== undefined || data.moderationLevel !== undefined) {
        usersWithModeration.push({
          id: doc.id,
          name: data.name || 'Sin nombre',
          moderationEnabled: data.moderationEnabled,
          moderationLevel: data.moderationLevel || 'high',
        });
      }
    });

    console.log(`✅ Encontrados ${usersWithModeration.length} usuarios con configuración de moderación\n`);

    if (usersWithModeration.length === 0) {
      console.log('✅ No hay usuarios para migrar\n');
      return;
    }

    // 2. Para cada usuario con moderación, buscar sus contactos
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🔍 MIGRANDO CONFIGURACIÓN DE MODERACIÓN');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    let totalMigrated = 0;
    let totalSkipped = 0;

    for (const user of usersWithModeration) {
      console.log(`👤 Usuario: ${user.name} (${user.id})`);
      console.log(`   moderationEnabled: ${user.moderationEnabled}`);
      console.log(`   moderationLevel: ${user.moderationLevel}`);

      // Buscar todos los contactos de este usuario
      const contactsSnapshot = await db.collection('contacts')
        .where('users', 'array-contains', user.id)
        .get();

      console.log(`   📊 Contactos encontrados: ${contactsSnapshot.size}`);

      if (contactsSnapshot.empty) {
        console.log(`   ⚠️  Sin contactos para migrar\n`);
        continue;
      }

      // Migrar cada contacto
      for (const contactDoc of contactsSnapshot.docs) {
        const contactData = contactDoc.data();
        const moderationSettings = contactData.moderationSettings || {};

        // Verificar si ya existe configuración para este usuario
        if (moderationSettings[user.id]) {
          console.log(`   ⏭️  Contacto ${contactDoc.id} ya tiene moderationSettings para este usuario, saltando...`);
          totalSkipped++;
          continue;
        }

        // Crear nueva configuración
        const newSettings = {
          enabled: user.moderationEnabled ?? false,
          level: user.moderationLevel || 'high',
        };

        // Si está habilitada, agregar timestamp
        if (newSettings.enabled) {
          newSettings.enabledAt = admin.firestore.Timestamp.now();
        }

        // Actualizar el documento de contacto
        await db.collection('contacts').doc(contactDoc.id).update({
          [`moderationSettings.${user.id}`]: newSettings,
        });

        console.log(`   ✅ Migrado contacto ${contactDoc.id}`);
        console.log(`      Nueva configuración:`, newSettings);
        totalMigrated++;
      }

      console.log('');
    }

    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('📊 RESUMEN DE MIGRACIÓN:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    console.log(`   Usuarios procesados: ${usersWithModeration.length}`);
    console.log(`   Contactos migrados: ${totalMigrated}`);
    console.log(`   Contactos saltados: ${totalSkipped}`);
    console.log('');

    // 3. Confirmar si eliminar campos antiguos de usuarios
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('⚠️  LIMPIEZA DE CAMPOS ANTIGUOS');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    console.log('Los siguientes campos antiguos están obsoletos:');
    console.log('  - users/{userId}.moderationEnabled');
    console.log('  - users/{userId}.moderationLevel');
    console.log('  - users/{userId}.moderationEnabledAt');
    console.log('');
    console.log('⚠️  Ejecuta el script cleanup_old_moderation_fields.js para eliminarlos');
    console.log('');

    console.log('✅ Migración completada\n');

  } catch (error) {
    console.error('❌ Error en migración:', error);
  } finally {
    process.exit(0);
  }
}

// Ejecutar
migrateModeration();
