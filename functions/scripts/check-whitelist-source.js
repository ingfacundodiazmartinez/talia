const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function investigateWhitelist() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('=== INVESTIGACIÓN COMPLETA ===\n');

  // 1. Contactos donde Facu es participante directo
  console.log('1. CONTACTOS DONDE FACU ESTÁ EN users[]:');
  const facuContactsSnap = await db.collection('contacts')
    .where('users', 'array-contains', facuId)
    .get();
  console.log('   Total:', facuContactsSnap.size);
  for (const doc of facuContactsSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] type=${data.type || 'null'} status=${data.status} users=${JSON.stringify(data.users)}`);
  }

  // 2. Contactos donde Facu está en parentViewers
  console.log('\n2. CONTACTOS DONDE FACU ESTÁ EN parentViewers[]:');
  const parentViewerSnap = await db.collection('contacts')
    .where('parentViewers', 'array-contains', facuId)
    .get();
  console.log('   Total:', parentViewerSnap.size);
  for (const doc of parentViewerSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] type=${data.type || 'null'} status=${data.status}`);
    console.log(`     users: ${JSON.stringify(data.users)}`);
    console.log(`     approvals: ${JSON.stringify(data.approvals)}`);
  }

  // 3. Group approval requests (todos los estados)
  console.log('\n3. TODOS LOS GROUP APPROVAL REQUESTS DE FACU:');
  const allRequestsSnap = await db.collection('group_approval_requests')
    .where('parentId', '==', facuId)
    .get();
  console.log('   Total:', allRequestsSnap.size);
  for (const doc of allRequestsSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] status=${data.status} group=${data.groupName} child=${data.childId}`);
  }

  // 4. Ver documento de Facu completo para entender su rol
  console.log('\n4. DOCUMENTO COMPLETO DE FACU:');
  const facuDoc = await db.collection('users').doc(facuId).get();
  if (facuDoc.exists) {
    const data = facuDoc.data();
    console.log('   role:', data.role);
    console.log('   name:', data.name);
    console.log('   linkedChildren:', JSON.stringify(data.linkedChildren));
    console.log('   linkedParent:', data.linkedParent);
    console.log('   parentLinkCode:', data.parentLinkCode);
    console.log('   childLinkCode:', data.childLinkCode);
  }

  // 5. Ver documento de Tadeo completo
  console.log('\n5. DOCUMENTO COMPLETO DE TADEO:');
  const tadeoDoc = await db.collection('users').doc(tadeoId).get();
  if (tadeoDoc.exists) {
    const data = tadeoDoc.data();
    console.log('   role:', data.role);
    console.log('   name:', data.name);
    console.log('   linkedChildren:', JSON.stringify(data.linkedChildren));
    console.log('   linkedParent:', data.linkedParent);
    console.log('   parentLinkCode:', data.parentLinkCode);
    console.log('   childLinkCode:', data.childLinkCode);
  }

  // 6. Buscar TODOS los parent_child_links (puede haber formato diferente de ID)
  console.log('\n6. TODOS LOS PARENT_CHILD_LINKS (primeros 20):');
  const allLinksSnap = await db.collection('parent_child_links')
    .limit(20)
    .get();
  console.log('   Total en colección:', allLinksSnap.size);
  for (const doc of allLinksSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] parentId=${data.parentId} childId=${data.childId} status=${data.status}`);
  }
}

investigateWhitelist()
  .then(() => process.exit(0))
  .catch(e => {
    console.error(e);
    process.exit(1);
  });
