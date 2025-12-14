/**
 * Arreglar sincronización de vinculación padre-hijo
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

const FACU_ID = 'ldUCB59Xo7gfoGlo948pHJZjeRF3';
const TADEO_ID = '77m006WREsaxzVO726xs8wCReBJ3';

async function main() {
  console.log('🔧 Arreglando sincronización de vinculación...\n');

  // 1. Agregar Tadeo a linkedChildrenIds de Facu
  await db.collection('users').doc(FACU_ID).update({
    linkedChildrenIds: admin.firestore.FieldValue.arrayUnion(TADEO_ID)
  });
  console.log('✅ Agregado Tadeo a linkedChildrenIds de Facu');

  // 2. Agregar Facu a linkedParentIds de Tadeo (si existe el campo)
  await db.collection('users').doc(TADEO_ID).update({
    linkedParentIds: admin.firestore.FieldValue.arrayUnion(FACU_ID)
  });
  console.log('✅ Agregado Facu a linkedParentIds de Tadeo');

  // 3. Verificar
  const facuDoc = await db.collection('users').doc(FACU_ID).get();
  const tadeoDoc = await db.collection('users').doc(TADEO_ID).get();

  console.log('\n📋 Estado final:\n');
  console.log(`   Facu linkedChildrenIds: ${JSON.stringify(facuDoc.data().linkedChildrenIds)}`);
  console.log(`   Tadeo linkedParentIds: ${JSON.stringify(tadeoDoc.data().linkedParentIds)}`);

  console.log('\n✅ Sincronización completada');
  process.exit(0);
}

main();
