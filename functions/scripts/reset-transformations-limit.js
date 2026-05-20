/**
 * Script para resetear el límite de transformaciones de un usuario
 *
 * USO:
 *   node scripts/reset-transformations-limit.js <userId> [--prod]
 *
 * Ejemplos:
 *   node scripts/reset-transformations-limit.js abc123              # Staging
 *   node scripts/reset-transformations-limit.js abc123 --prod       # Producción
 */

const admin = require('firebase-admin');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

// Parsear argumentos
const args = process.argv.slice(2);
const userId = args.find(arg => !arg.startsWith('--'));
const isProd = args.includes('--prod');

if (!userId) {
  console.error('❌ Error: userId es requerido');
  console.log('\nUso: node scripts/reset-transformations-limit.js <userId> [--prod]');
  console.log('\nEjemplos:');
  console.log('  node scripts/reset-transformations-limit.js abc123              # Staging');
  console.log('  node scripts/reset-transformations-limit.js abc123 --prod       # Producción');
  process.exit(1);
}

const projectId = isProd ? 'talia-chat-app-v2' : 'talia-staging';

console.log(`\n🔧 Reset Transformations Limit`);
console.log(`   Proyecto: ${projectId} (${isProd ? 'PRODUCCIÓN' : 'staging'})`);
console.log(`   Usuario: ${userId}\n`);

admin.initializeApp({ projectId });
const db = getFirestore();

async function resetLimit() {
  try {
    // 1. Obtener info del usuario
    const userDoc = await db.collection('users').doc(userId).get();
    if (!userDoc.exists) {
      console.error(`❌ Usuario ${userId} no existe`);
      process.exit(1);
    }

    const userData = userDoc.data();
    console.log(`👤 Usuario: ${userData.name || 'Sin nombre'}`);
    console.log(`   Tier: ${userData.subscriptionTier || 'free'}`);

    // 2. Contar transformaciones actuales
    const now = new Date();
    const startOfDay = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 0, 0, 0, 0));
    const startOfMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1, 0, 0, 0, 0));

    // Free = daily, Premium = monthly
    const isPremium = userData.isPremium === true;
    const periodStart = isPremium ? startOfMonth : startOfDay;
    const periodName = isPremium ? 'este mes' : 'hoy';

    const snapshot = await db.collection('character_transformations')
      .where('userId', '==', userId)
      .where('createdAt', '>=', Timestamp.fromDate(periodStart))
      .get();

    console.log(`📊 Transformaciones ${periodName}: ${snapshot.size}`);

    if (snapshot.empty) {
      console.log('\n✅ No hay transformaciones que eliminar');
      process.exit(0);
    }

    // 3. Eliminar registros en batches
    console.log(`\n🗑️  Eliminando ${snapshot.size} registros...`);

    const batchSize = 500;
    let deleted = 0;

    for (let i = 0; i < snapshot.docs.length; i += batchSize) {
      const batch = db.batch();
      const batchDocs = snapshot.docs.slice(i, i + batchSize);

      for (const doc of batchDocs) {
        batch.delete(doc.ref);
      }

      await batch.commit();
      deleted += batchDocs.length;
      console.log(`   Eliminados: ${deleted}/${snapshot.size}`);
    }

    console.log(`\n✅ Límite reseteado. El usuario puede usar ${isPremium ? '50-100' : '10'} transformaciones ${periodName}.`);

  } catch (error) {
    console.error('❌ Error:', error.message);
    process.exit(1);
  }
}

resetLimit().then(() => process.exit(0));
