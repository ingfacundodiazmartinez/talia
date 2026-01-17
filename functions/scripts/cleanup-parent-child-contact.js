const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function cleanupParentChildContact() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  // El contacto Facu-Tadeo no debería existir como contacto normal
  // Son padre-hijo, no contactos entre sí
  const contactId = `${facuId}_${tadeoId}`;

  console.log('=== LIMPIEZA DE CONTACTO PADRE-HIJO ===\n');

  const contactRef = db.collection('contacts').doc(contactId);
  const contactDoc = await contactRef.get();

  if (contactDoc.exists) {
    const data = contactDoc.data();
    console.log('Contacto encontrado:', contactId);
    console.log('  type:', data.type);
    console.log('  status:', data.status);
    console.log('  users:', data.users);

    console.log('\nEliminando contacto padre-hijo...');
    await contactRef.delete();
    console.log('✅ Contacto eliminado');
  } else {
    console.log('Contacto no existe (ya fue eliminado)');
  }

  // Verificar lo que queda
  console.log('\n=== CONTACTOS RESTANTES DONDE FACU ESTÁ EN users[] ===\n');
  const remainingSnap = await db.collection('contacts')
    .where('users', 'array-contains', facuId)
    .get();

  console.log('Total:', remainingSnap.size);
  for (const doc of remainingSnap.docs) {
    const data = doc.data();
    console.log(`  - [${doc.id}] type=${data.type || 'null'} status=${data.status}`);
  }

  // Verificar contactos de Tadeo (esto es lo que debería ver el padre en la whitelist)
  console.log('\n=== CONTACTOS DE TADEO (para whitelist del padre) ===\n');
  const tadeoContactsSnap = await db.collection('contacts')
    .where('users', 'array-contains', tadeoId)
    .get();

  console.log('Total:', tadeoContactsSnap.size);
  for (const doc of tadeoContactsSnap.docs) {
    const data = doc.data();
    const otherUserId = data.users.find(u => u !== tadeoId);
    console.log(`  - [${doc.id}]`);
    console.log(`    type=${data.type || 'null'} status=${data.status}`);
    console.log(`    otherUser=${otherUserId}`);
    console.log(`    parentViewers=${JSON.stringify(data.parentViewers)}`);
  }
}

cleanupParentChildContact()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
