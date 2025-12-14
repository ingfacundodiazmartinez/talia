/**
 * Verificar estado de vinculación entre usuarios
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

const PHONES = {
  facu: '+5493875433442',
  tadeo: '+5493875433443'
};

async function main() {
  console.log('🔍 Buscando usuarios...\n');

  const usersSnapshot = await db.collection('users').get();
  const users = {};

  for (const [key, phone] of Object.entries(PHONES)) {
    const normalizedSearch = phone.replace(/[+\s-]/g, '').slice(-10);

    usersSnapshot.forEach(doc => {
      const data = doc.data();
      const userPhone = (data.phone || data.phoneNumber || '').replace(/[+\s-]/g, '');

      if (userPhone.includes(normalizedSearch)) {
        users[key] = { id: doc.id, ...data };
      }
    });
  }

  // Mostrar Facu
  if (users.facu) {
    console.log('👨 FACU:');
    console.log(`   ID: ${users.facu.id}`);
    console.log(`   Nombre: ${users.facu.name}`);
    console.log(`   Role: ${users.facu.role}`);
    console.log(`   linkedChildrenIds: ${JSON.stringify(users.facu.linkedChildrenIds || [])}`);
  } else {
    console.log('❌ Facu no encontrado');
  }

  console.log('');

  // Mostrar Tadeo
  if (users.tadeo) {
    console.log('👦 TADEO:');
    console.log(`   ID: ${users.tadeo.id}`);
    console.log(`   Nombre: ${users.tadeo.name}`);
    console.log(`   Role: ${users.tadeo.role}`);
    console.log(`   parentId: ${users.tadeo.parentId || 'N/A'}`);
    console.log(`   linkedParentIds: ${JSON.stringify(users.tadeo.linkedParentIds || [])}`);
  } else {
    console.log('❌ Tadeo no encontrado');
  }

  // Buscar en parent_children
  console.log('\n📋 Buscando en parent_children...\n');

  if (users.facu && users.tadeo) {
    // Buscar relación Facu -> Tadeo
    const link1 = await db.collection('parent_children')
      .where('parentId', '==', users.facu.id)
      .where('childId', '==', users.tadeo.id)
      .get();

    if (!link1.empty) {
      const data = link1.docs[0].data();
      console.log(`   ✅ parent_children encontrado:`);
      console.log(`      Doc ID: ${link1.docs[0].id}`);
      console.log(`      parentId: ${data.parentId}`);
      console.log(`      childId: ${data.childId}`);
      console.log(`      status: ${data.status}`);
    } else {
      console.log('   ❌ No hay documento en parent_children');
    }
  }

  process.exit(0);
}

main();
