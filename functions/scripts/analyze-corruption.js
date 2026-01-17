const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function analyzeCorruption() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('=== ANÁLISIS DE CAUSA RAÍZ ===\n');

  // 1. El documento que creé por error en parent_child_links
  console.log('1. Mi script creó documento en colección INCORRECTA:');
  const wrongLinkDoc = await db.collection('parent_child_links')
    .doc(`${facuId}_${tadeoId}`).get();
  if (wrongLinkDoc.exists) {
    const data = wrongLinkDoc.data();
    console.log('   Colección: parent_child_links (INCORRECTO)');
    console.log('   linkedAt:', data.linkedAt ? data.linkedAt.toDate() : 'null');
    console.log('   createdAt:', data.createdAt ? data.createdAt.toDate() : 'null');
    console.log('   status:', data.status);
  }

  // 2. El documento correcto en parent_children
  console.log('\n2. Documento CORRECTO en parent_children:');
  const correctLinkDoc = await db.collection('parent_children')
    .doc(`${facuId}_${tadeoId}`).get();
  if (correctLinkDoc.exists) {
    const data = correctLinkDoc.data();
    console.log('   Colección: parent_children (CORRECTO)');
    console.log('   linkedAt:', data.linkedAt ? data.linkedAt.toDate() : 'null');
    console.log('   status:', data.status);
  }

  // 3. Historial de linkedChildrenIds
  console.log('\n3. Historial de linkedChildrenIds en Facu:');
  const facuDoc = await db.collection('users').doc(facuId).get();
  if (facuDoc.exists) {
    const data = facuDoc.data();
    console.log('   linkedChildrenIds:', JSON.stringify(data.linkedChildrenIds));
    console.log('   linkedChildrenIdsUpdatedAt:', data.linkedChildrenIdsUpdatedAt?.toDate());
    // Si hay campo de historia
    if (data.linkedChildrenIdsHistory) {
      console.log('   Historia:', JSON.stringify(data.linkedChildrenIdsHistory));
    }
  }

  // 4. Verificar si había datos de whitelist antigua
  console.log('\n4. Colección whitelist (legacy):');
  const whitelistSnap = await db.collection('whitelist').limit(5).get();
  console.log('   Total documentos:', whitelistSnap.size);

  // 5. Posibles causas
  console.log('\n=== CONCLUSIÓN ===\n');
  console.log('CAUSA PROBABLE DEL PROBLEMA:');
  console.log('');
  console.log('Escenario 1: El WhitelistController usa linkedChildrenIds que');
  console.log('             es poblado por el trigger onParentChildLinkCreated.');
  console.log('             Si el trigger no estaba desplegado o falló, el campo');
  console.log('             quedaba vacío aunque el link existía.');
  console.log('');
  console.log('Escenario 2: La app Flutter usaba una colección diferente');
  console.log('             (parent_child_links) en algún momento, y el trigger');
  console.log('             escuchaba otra colección (parent_children).');
  console.log('');
  console.log('Escenario 3: El campo linkedChildrenIds fue limpiado manualmente');
  console.log('             o por una migración/script que no debía ejecutarse.');

  // 6. Buscar en index.js para ver si hay referencias a parent_child_links
  console.log('\n=== VERIFICACIÓN DE COLECCIONES EN USO ===\n');
  console.log('La Cloud Function createParentChildLink usa: parent_children');
  console.log('Los triggers escuchan: parent_children/{linkId}');
  console.log('Mi script de "fix" usó: parent_child_links (ERROR!)');
}

analyzeCorruption()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
