/**
 * Script para limpiar campos obsoletos de moderación
 *
 * Elimina:
 * - users/{userId}.moderationEnabled
 * - users/{userId}.moderationLevel
 * - users/{userId}.moderationEnabledAt
 *
 * IMPORTANTE: Solo ejecutar después de la migración exitosa
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

async function cleanupOldFields() {
  try {
    console.log('\n🧹 ========== LIMPIEZA DE CAMPOS OBSOLETOS ==========\n');

    // Confirmar con el usuario
    console.log('⚠️  ADVERTENCIA: Este script eliminará campos obsoletos de moderación\n');
    console.log('Campos a eliminar:');
    console.log('  - users/{userId}.moderationEnabled');
    console.log('  - users/{userId}.moderationLevel');
    console.log('  - users/{userId}.moderationEnabledAt\n');

    // Obtener todos los usuarios
    const usersSnapshot = await db.collection('users').get();

    let totalUpdated = 0;
    let totalSkipped = 0;

    console.log(`📊 Procesando ${usersSnapshot.size} usuarios...\n`);

    for (const userDoc of usersSnapshot.docs) {
      const data = userDoc.data();

      // Verificar si tiene campos obsoletos
      const hasOldFields = data.moderationEnabled !== undefined ||
                           data.moderationLevel !== undefined ||
                           data.moderationEnabledAt !== undefined;

      if (!hasOldFields) {
        totalSkipped++;
        continue;
      }

      // Eliminar campos obsoletos
      const updateData = {
        moderationEnabled: admin.firestore.FieldValue.delete(),
        moderationLevel: admin.firestore.FieldValue.delete(),
        moderationEnabledAt: admin.firestore.FieldValue.delete(),
      };

      await db.collection('users').doc(userDoc.id).update(updateData);

      console.log(`✅ Usuario ${data.name || userDoc.id}: Campos eliminados`);
      totalUpdated++;
    }

    console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('📊 RESUMEN:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    console.log(`   Usuarios actualizados: ${totalUpdated}`);
    console.log(`   Usuarios saltados: ${totalSkipped}`);
    console.log('');
    console.log('✅ Limpieza completada\n');

  } catch (error) {
    console.error('❌ Error en limpieza:', error);
  } finally {
    process.exit(0);
  }
}

// Ejecutar
cleanupOldFields();
