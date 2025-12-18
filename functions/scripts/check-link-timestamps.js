const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function checkTimestamps() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';
  const linkId = `${facuId}_${tadeoId}`;

  console.log('=== ANÁLISIS DE TIMESTAMPS ===\n');

  // 1. Documento en parent_children
  console.log('1. Documento en parent_children:');
  const linkDoc = await db.collection('parent_children').doc(linkId).get();
  if (linkDoc.exists) {
    const data = linkDoc.data();
    console.log('   linkedAt:', data.linkedAt ? data.linkedAt.toDate() : 'null');
    console.log('   status:', data.status);
    console.log('   createdBy:', data.createdBy);
    console.log('   Todos los campos:');
    for (const [key, value] of Object.entries(data)) {
      const displayValue = value && value.toDate ? value.toDate().toISOString() : JSON.stringify(value);
      console.log(`     ${key}: ${displayValue}`);
    }
  }

  // 2. Documento de Facu
  console.log('\n2. Documento de Facu (users):');
  const facuDoc = await db.collection('users').doc(facuId).get();
  if (facuDoc.exists) {
    const data = facuDoc.data();
    console.log('   linkedChildrenIds:', JSON.stringify(data.linkedChildrenIds));
    console.log('   linkedChildrenIdsUpdatedAt:', data.linkedChildrenIdsUpdatedAt ? data.linkedChildrenIdsUpdatedAt.toDate() : 'null');
    console.log('   createdAt:', data.createdAt ? data.createdAt.toDate() : 'null');
    console.log('   updatedAt:', data.updatedAt ? data.updatedAt.toDate() : 'null');
  }

  // 3. Documento de Tadeo
  console.log('\n3. Documento de Tadeo (users):');
  const tadeoDoc = await db.collection('users').doc(tadeoId).get();
  if (tadeoDoc.exists) {
    const data = tadeoDoc.data();
    console.log('   linkedParentIds:', JSON.stringify(data.linkedParentIds));
    console.log('   linkedParentId:', data.linkedParentId);
    console.log('   parentId:', data.parentId);
    console.log('   createdAt:', data.createdAt ? data.createdAt.toDate() : 'null');
    console.log('   linkedAt:', data.linkedAt ? data.linkedAt.toDate() : 'null');
  }

  // 4. Buscar contacto con type=parent_child_link
  console.log('\n4. Contacto con type=parent_child_link:');
  const contactsSnap = await db.collection('contacts')
    .where('type', '==', 'parent_child_link')
    .get();
  console.log('   Total encontrados:', contactsSnap.size);
  for (const doc of contactsSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}]`);
    console.log(`     users: ${JSON.stringify(data.users)}`);
    console.log(`     createdAt: ${data.createdAt ? data.createdAt.toDate() : 'null'}`);
    console.log(`     createdBy: ${data.createdBy}`);
  }
}

checkTimestamps()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
