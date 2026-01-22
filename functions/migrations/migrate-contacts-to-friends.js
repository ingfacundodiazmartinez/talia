/**
 * ═══════════════════════════════════════════════════════════════
 * MIGRATION: Migrar contactos existentes a amigos
 * ═══════════════════════════════════════════════════════════════
 *
 * Propósito: Para el feature "Friends for Stories"
 * - Todos los contactos aprobados existentes se convierten en amigos
 * - Esto asegura que usuarios existentes no pierdan visibilidad de historias
 *
 * Ejecutar UNA sola vez después de desplegar el feature.
 *
 * USO:
 * Firebase Console > Functions > migrateContactsToFriends > Test Function
 * O vía HTTPS: POST https://us-central1-{projectId}.cloudfunctions.net/migrateContactsToFriends
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp, getApps } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

// Inicializar Firebase Admin SDK
if (!getApps().length) {
  initializeApp();
}

const db = getFirestore();

/**
 * Migración: Convertir todos los contactos aprobados en amigos
 *
 * Resultado:
 * - Todos los contacts con status='approved' tendrán isFriend=true
 * - friendRequest se inicializa como 'accepted' para indicar migración
 *
 * IMPORTANTE: Esta función es idempotente - puede ejecutarse múltiples veces
 * sin efectos adversos (no sobrescribe contactos ya migrados).
 */
exports.migrateContactsToFriends = onCall({
  region: 'us-central1',
  cors: true,
  timeoutSeconds: 540, // 9 minutos para procesar muchos contactos
  memory: '1GiB',
}, async (request) => {
  const { data, auth } = request;
  const dryRun = data?.dryRun === true;

  console.log(`🔄 [Migration] Iniciando migración de contactos a amigos (dryRun: ${dryRun})`);

  // Verificar autenticación (opcional - puede requerirse admin)
  // Por seguridad, solo usuarios autenticados pueden ejecutar
  if (!auth?.uid) {
    console.log('⚠️ [Migration] Ejecutando sin autenticación');
    // throw new HttpsError('unauthenticated', 'Se requiere autenticación');
  }

  try {
    // 1. Obtener todos los contactos aprobados que NO tienen isFriend definido
    // o que tienen isFriend !== true
    const contactsSnapshot = await db
      .collection('contacts')
      .where('status', '==', 'approved')
      .get();

    console.log(`📊 [Migration] Total contactos aprobados: ${contactsSnapshot.size}`);

    if (contactsSnapshot.empty) {
      return {
        success: true,
        message: 'No hay contactos para migrar',
        stats: { total: 0, migrated: 0, skipped: 0 }
      };
    }

    // 2. Filtrar contactos que necesitan migración
    const contactsToMigrate = [];
    const contactsAlreadyMigrated = [];

    for (const doc of contactsSnapshot.docs) {
      const data = doc.data();

      // Skip si ya tiene isFriend = true
      if (data.isFriend === true) {
        contactsAlreadyMigrated.push(doc.id);
        continue;
      }

      contactsToMigrate.push({
        id: doc.id,
        ref: doc.ref,
        users: data.users,
      });
    }

    console.log(`📊 [Migration] Contactos a migrar: ${contactsToMigrate.length}`);
    console.log(`📊 [Migration] Contactos ya migrados: ${contactsAlreadyMigrated.length}`);

    if (contactsToMigrate.length === 0) {
      return {
        success: true,
        message: 'Todos los contactos ya están migrados',
        stats: {
          total: contactsSnapshot.size,
          migrated: 0,
          skipped: contactsAlreadyMigrated.length
        }
      };
    }

    // 3. Ejecutar migración en batches de 500 (límite de Firestore)
    if (dryRun) {
      console.log(`🔍 [Migration] DRY RUN - No se realizarán cambios`);
      return {
        success: true,
        dryRun: true,
        message: `DRY RUN: Se migrarían ${contactsToMigrate.length} contactos`,
        stats: {
          total: contactsSnapshot.size,
          toMigrate: contactsToMigrate.length,
          alreadyMigrated: contactsAlreadyMigrated.length
        },
        sampleContacts: contactsToMigrate.slice(0, 10).map(c => ({
          id: c.id,
          users: c.users
        }))
      };
    }

    // Ejecutar migración real
    const batchSize = 500;
    let migratedCount = 0;
    let errorCount = 0;

    for (let i = 0; i < contactsToMigrate.length; i += batchSize) {
      const batchContacts = contactsToMigrate.slice(i, i + batchSize);
      const batch = db.batch();

      for (const contact of batchContacts) {
        batch.update(contact.ref, {
          isFriend: true,
          friendRequest: {
            status: 'accepted',
            acceptedAt: FieldValue.serverTimestamp(),
            migratedFromLegacy: true, // Marca para identificar migración
          },
          updatedAt: FieldValue.serverTimestamp(),
        });
      }

      try {
        await batch.commit();
        migratedCount += batchContacts.length;
        console.log(`✅ [Migration] Batch ${Math.floor(i / batchSize) + 1}: ${batchContacts.length} contactos migrados`);
      } catch (batchError) {
        console.error(`❌ [Migration] Error en batch ${Math.floor(i / batchSize) + 1}:`, batchError);
        errorCount += batchContacts.length;
      }
    }

    console.log(`✅ [Migration] Migración completada: ${migratedCount} exitosos, ${errorCount} errores`);

    return {
      success: true,
      message: `Migración completada: ${migratedCount} contactos actualizados`,
      stats: {
        total: contactsSnapshot.size,
        migrated: migratedCount,
        errors: errorCount,
        skipped: contactsAlreadyMigrated.length
      }
    };

  } catch (error) {
    console.error('❌ [Migration] Error en migración:', error);
    throw new HttpsError('internal', `Error en migración: ${error.message}`);
  }
});

/**
 * Verificar estado de migración
 *
 * Retorna estadísticas sobre el estado actual de los contactos.
 */
exports.checkMigrationStatus = onCall({
  region: 'us-central1',
  cors: true,
}, async (request) => {
  console.log(`📊 [Migration] Verificando estado de migración...`);

  try {
    // Contar contactos por estado
    const approvedSnapshot = await db
      .collection('contacts')
      .where('status', '==', 'approved')
      .get();

    let withFriend = 0;
    let withoutFriend = 0;
    let withRejected = 0;
    let withPending = 0;

    for (const doc of approvedSnapshot.docs) {
      const data = doc.data();

      if (data.isFriend === true) {
        withFriend++;
      } else {
        withoutFriend++;
      }

      if (data.friendRequest?.status === 'rejected') {
        withRejected++;
      } else if (data.friendRequest?.status === 'pending') {
        withPending++;
      }
    }

    return {
      success: true,
      stats: {
        totalApproved: approvedSnapshot.size,
        withFriendTrue: withFriend,
        withoutFriend: withoutFriend,
        withRejectedRequest: withRejected,
        withPendingRequest: withPending,
        migrationNeeded: withoutFriend > 0,
      }
    };

  } catch (error) {
    console.error('❌ [Migration] Error verificando estado:', error);
    throw new HttpsError('internal', `Error: ${error.message}`);
  }
});
