const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function checkExactFields() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';

  console.log('=== CAMPOS EXACTOS DE FACU ===\n');

  const facuDoc = await db.collection('users').doc(facuId).get();
  if (facuDoc.exists) {
    const data = facuDoc.data();

    // Mostrar TODOS los campos
    console.log('Todos los campos del documento:');
    for (const [key, value] of Object.entries(data)) {
      console.log(`  ${key}: ${JSON.stringify(value)}`);
    }

    console.log('\n--- Campos específicos de links ---');
    console.log('linkedChildren:', JSON.stringify(data.linkedChildren));
    console.log('linkedChildrenIds:', JSON.stringify(data.linkedChildrenIds));
    console.log('linkedParent:', data.linkedParent);
    console.log('linkedParentId:', data.linkedParentId);
    console.log('children:', JSON.stringify(data.children));
  }
}

checkExactFields()
  .then(() => process.exit(0))
  .catch(e => {
    console.error(e);
    process.exit(1);
  });
