const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function checkParentView() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('=== Vista del Padre (Facu) ===\n');

  // 1. Hijos vinculados
  console.log('1. HIJOS VINCULADOS:');
  const linksSnap = await db.collection('parent_child_links')
    .where('parentId', '==', facuId)
    .where('status', '==', 'active')
    .get();

  const childrenIds = linksSnap.docs.map(doc => doc.data().childId);
  console.log('   Hijos:', childrenIds);

  // 2. Contactos de los hijos
  console.log('\n2. CONTACTOS (where users contains child):');
  for (const childId of childrenIds) {
    const contactsSnap = await db.collection('contacts')
      .where('users', 'array-contains', childId)
      .get();

    console.log(`   Child ${childId}:`);
    for (const doc of contactsSnap.docs) {
      const data = doc.data();
      console.log(`   - [${doc.id}] type=${data.type || 'null'} status=${data.status}`);
    }
  }

  // 3. Group approval requests pendientes
  console.log('\n3. GROUP APPROVAL REQUESTS (pending):');
  const pendingSnap = await db.collection('group_approval_requests')
    .where('parentId', '==', facuId)
    .where('status', '==', 'pending')
    .get();
  console.log('   Total pending:', pendingSnap.size);

  // 4. Group approval requests aprobados (para detectar duplicados)
  console.log('\n4. GROUP APPROVAL REQUESTS (approved):');
  const approvedSnap = await db.collection('group_approval_requests')
    .where('parentId', '==', facuId)
    .where('status', '==', 'approved')
    .get();
  console.log('   Total approved:', approvedSnap.size);
  for (const doc of approvedSnap.docs) {
    const data = doc.data();
    console.log(`   - [${doc.id}] group=${data.groupName} child=${data.childId}`);
  }

  // 5. Grupos donde los hijos son miembros
  console.log('\n5. GRUPOS V2 (where members contains children):');
  if (childrenIds.length > 0) {
    const groupsSnap = await db.collection('groups_v2')
      .where('members', 'array-contains-any', childrenIds)
      .get();

    console.log('   Total grupos:', groupsSnap.size);
    for (const doc of groupsSnap.docs) {
      const data = doc.data();
      console.log(`   - [${doc.id}] name=${data.name} members=${data.members?.length}`);
    }
  }
}

async function checkLinks() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('\n\n=== DIAGNÓSTICO DE LINKS ===\n');

  // Todos los links donde Facu es padre
  console.log('Links donde Facu es parentId:');
  const linksParent = await db.collection('parent_child_links')
    .where('parentId', '==', facuId)
    .get();
  console.log('Total:', linksParent.size);
  for (const doc of linksParent.docs) {
    const data = doc.data();
    console.log(`  [${doc.id}] childId=${data.childId} status=${data.status}`);
  }

  // Todos los links donde Tadeo es hijo
  console.log('\nLinks donde Tadeo es childId:');
  const linksChild = await db.collection('parent_child_links')
    .where('childId', '==', tadeoId)
    .get();
  console.log('Total:', linksChild.size);
  for (const doc of linksChild.docs) {
    const data = doc.data();
    console.log(`  [${doc.id}] parentId=${data.parentId} status=${data.status}`);
  }

  // Verificar el documento de Facu para ver sus linkedChildren
  console.log('\nDocumento de Facu (users):');
  const facuDoc = await db.collection('users').doc(facuId).get();
  if (facuDoc.exists) {
    const data = facuDoc.data();
    console.log('  role:', data.role);
    console.log('  linkedChildren:', data.linkedChildren);
    console.log('  linkedParent:', data.linkedParent);
  }

  // Verificar el documento de Tadeo
  console.log('\nDocumento de Tadeo (users):');
  const tadeoDoc = await db.collection('users').doc(tadeoId).get();
  if (tadeoDoc.exists) {
    const data = tadeoDoc.data();
    console.log('  role:', data.role);
    console.log('  linkedChildren:', data.linkedChildren);
    console.log('  linkedParent:', data.linkedParent);
  }
}

checkParentView()
  .then(() => checkLinks())
  .then(() => process.exit(0))
  .catch(e => {
    console.error(e);
    process.exit(1);
  });
