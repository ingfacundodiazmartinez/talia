const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function checkCorrectCollection() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('=== VERIFICACIÓN DE COLECCIONES ===\n');

  // 1. Verificar parent_children (la correcta según Cloud Functions)
  console.log('1. Colección parent_children (CORRECTA):');
  const parentChildrenSnap = await db.collection('parent_children').limit(20).get();
  console.log('   Total documentos:', parentChildrenSnap.size);
  for (const doc of parentChildrenSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] parentId=${data.parentId} childId=${data.childId} status=${data.status}`);
  }

  // 2. Verificar parent_child_links (la que usé por error)
  console.log('\n2. Colección parent_child_links (INCORRECTA - usada por mi script):');
  const parentChildLinksSnap = await db.collection('parent_child_links').limit(20).get();
  console.log('   Total documentos:', parentChildLinksSnap.size);
  for (const doc of parentChildLinksSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] parentId=${data.parentId} childId=${data.childId} status=${data.status}`);
  }

  // 3. Buscar link específico Facu-Tadeo en ambas colecciones
  const linkId = `${facuId}_${tadeoId}`;
  console.log(`\n3. Buscando link específico: ${linkId}`);

  const correctDoc = await db.collection('parent_children').doc(linkId).get();
  console.log('   En parent_children:', correctDoc.exists ? 'EXISTE' : 'NO EXISTE');

  const wrongDoc = await db.collection('parent_child_links').doc(linkId).get();
  console.log('   En parent_child_links:', wrongDoc.exists ? 'EXISTE (mi error)' : 'NO EXISTE');

  // 4. Ver estado actual del usuario Facu
  console.log('\n4. Estado actual de Facu:');
  const facuDoc = await db.collection('users').doc(facuId).get();
  const facuData = facuDoc.data();
  console.log('   linkedChildrenIds:', JSON.stringify(facuData.linkedChildrenIds));
}

checkCorrectCollection()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
