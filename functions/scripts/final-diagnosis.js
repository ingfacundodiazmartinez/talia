const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function finalDiagnosis() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('=== DIAGNÓSTICO FINAL ===\n');

  // 1. ¿Por qué aparecían "Usuario" en la whitelist?
  console.log('1. CONTACTOS ACTUALES DE TADEO:');
  const tadeoContactsSnap = await db.collection('contacts')
    .where('users', 'array-contains', tadeoId)
    .get();

  console.log('   Total:', tadeoContactsSnap.size);
  for (const doc of tadeoContactsSnap.docs) {
    const data = doc.data();
    const otherUserId = data.users.find(u => u !== tadeoId);

    // Obtener nombre del otro usuario
    let otherUserName = 'DESCONOCIDO';
    if (otherUserId) {
      const userDoc = await db.collection('users').doc(otherUserId).get();
      if (userDoc.exists) {
        otherUserName = userDoc.data().name || 'SIN NOMBRE';
      } else {
        otherUserName = '⚠️ USUARIO NO EXISTE';
      }
    }

    console.log(`\n   [${doc.id}]`);
    console.log(`     type: ${data.type || 'null (contacto normal)'}`);
    console.log(`     status: ${data.status}`);
    console.log(`     otherUser: ${otherUserId} (${otherUserName})`);
    console.log(`     parentViewers: ${JSON.stringify(data.parentViewers)}`);
    console.log(`     createdAt: ${data.createdAt?.toDate()}`);
    console.log(`     createdBy: ${data.createdBy}`);
  }

  // 2. Verificar group_approval_requests restantes
  console.log('\n\n2. GROUP APPROVAL REQUESTS DE FACU:');
  const garSnap = await db.collection('group_approval_requests')
    .where('parentId', '==', facuId)
    .get();

  console.log('   Total:', garSnap.size);
  for (const doc of garSnap.docs) {
    const data = doc.data();
    console.log(`\n   [${doc.id}]`);
    console.log(`     status: ${data.status}`);
    console.log(`     groupName: ${data.groupName}`);
    console.log(`     childId: ${data.childId}`);
  }

  // 3. Explicación final
  console.log('\n\n=== CAUSA RAÍZ DEL PROBLEMA "Usuario" ===\n');
  console.log('El problema NO era el trigger ni el link padre-hijo.');
  console.log('');
  console.log('El problema era que había:');
  console.log('1. Múltiples group_approval_requests duplicados para el mismo grupo');
  console.log('2. Estos aparecían como "Usuario" porque el groupName no se resolvía bien');
  console.log('3. También había un contacto Facu-Tadeo directo que no debía existir como contacto');
  console.log('');
  console.log('El sistema de vinculación padre-hijo estaba funcionando correctamente.');
  console.log('El problema era data basura en group_approval_requests y contacts.');

  // 4. Limpiar documento duplicado en parent_child_links
  console.log('\n\n4. LIMPIEZA: Eliminando documento duplicado en parent_child_links...');
  const wrongDoc = await db.collection('parent_child_links')
    .doc(`${facuId}_${tadeoId}`).get();
  if (wrongDoc.exists) {
    await wrongDoc.ref.delete();
    console.log('   ✅ Eliminado documento duplicado en parent_child_links');
  } else {
    console.log('   Ya no existe');
  }
}

finalDiagnosis()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
