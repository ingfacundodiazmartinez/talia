/**
 * Script para ELIMINAR todos los datos creados por setup-demo-users.js
 *
 * Elimina:
 * - Contactos entre usuarios de prueba
 * - Chats y mensajes entre ellos
 * - Grupos creados
 * - Vinculaciones parent-child
 * - Restaura usuarios a estado limpio
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// Teléfonos de prueba usados en setup-demo-users.js
const TEST_PHONES = {
  facu: '+5493875433442',
  sofi: '+5493875433446',
  tadeo: '+5493875433447',
  mia: '+5493875433445'
};

let users = {};

/**
 * Elimina todos los documentos de una subcolección
 */
async function deleteSubcollection(collectionPath) {
  const ref = db.collection(collectionPath);
  let totalDeleted = 0;
  let snapshot = await ref.limit(500).get();

  while (!snapshot.empty) {
    const batch = db.batch();
    snapshot.docs.forEach(doc => {
      batch.delete(doc.ref);
      totalDeleted++;
    });
    await batch.commit();
    snapshot = await ref.limit(500).get();
  }

  return totalDeleted;
}

/**
 * Buscar usuarios de prueba por teléfono
 */
async function findTestUsers() {
  console.log('\n📱 Buscando usuarios de prueba...\n');

  const usersSnapshot = await db.collection('users').get();

  for (const [key, phone] of Object.entries(TEST_PHONES)) {
    const normalizedSearch = phone.replace(/[+\s-]/g, '').slice(-10);

    usersSnapshot.forEach(doc => {
      const data = doc.data();
      const userPhone = (data.phone || data.phoneNumber || '').replace(/[+\s-]/g, '');

      if (userPhone.includes(normalizedSearch) || normalizedSearch.includes(userPhone.slice(-10))) {
        if (userPhone.length >= 10) {
          users[key] = {
            id: doc.id,
            name: data.name || data.displayName || 'Sin nombre',
            phone: data.phone || data.phoneNumber
          };
        }
      }
    });
  }

  // Mostrar resultados
  for (const [key, phone] of Object.entries(TEST_PHONES)) {
    if (users[key]) {
      console.log(`   ✅ ${key}: ${users[key].name} (${users[key].id})`);
    } else {
      console.log(`   ❌ ${key}: NO ENCONTRADO (${phone})`);
    }
  }

  return Object.keys(users).length;
}

/**
 * Eliminar contactos entre usuarios de prueba
 */
async function deleteContacts() {
  console.log('\n📇 Eliminando contactos...\n');

  const userIds = Object.values(users).map(u => u.id);
  let deleted = 0;

  // Buscar contactos que contengan cualquiera de los usuarios
  for (const userId of userIds) {
    const contactsSnapshot = await db.collection('contacts')
      .where('users', 'array-contains', userId)
      .get();

    for (const doc of contactsSnapshot.docs) {
      const data = doc.data();
      const contactUsers = data.users || [];

      // Solo eliminar si AMBOS usuarios son de prueba
      const bothTestUsers = contactUsers.every(id => userIds.includes(id));

      if (bothTestUsers) {
        await doc.ref.delete();
        deleted++;
        console.log(`   🗑️ Contacto eliminado: ${doc.id}`);
      }
    }
  }

  console.log(`   ✅ ${deleted} contactos eliminados`);
  return deleted;
}

/**
 * Eliminar chats entre usuarios de prueba
 */
async function deleteChats() {
  console.log('\n💬 Eliminando chats...\n');

  const userIds = Object.values(users).map(u => u.id);
  let deleted = 0;

  for (const userId of userIds) {
    const chatsSnapshot = await db.collection('chats')
      .where('participants', 'array-contains', userId)
      .get();

    for (const doc of chatsSnapshot.docs) {
      const data = doc.data();
      const participants = data.participants || [];

      // Solo eliminar si AMBOS participantes son de prueba
      const bothTestUsers = participants.every(id => userIds.includes(id));

      if (bothTestUsers) {
        // Eliminar mensajes primero
        const msgDeleted = await deleteSubcollection(`chats/${doc.id}/messages`);
        console.log(`   🗑️ Chat ${doc.id}: ${msgDeleted} mensajes eliminados`);

        // Eliminar typing indicators
        await deleteSubcollection(`chats/${doc.id}/typing`);

        // Eliminar el chat
        await doc.ref.delete();
        deleted++;
      }
    }
  }

  console.log(`   ✅ ${deleted} chats eliminados`);
  return deleted;
}

/**
 * Eliminar grupos donde todos los miembros son de prueba
 */
async function deleteGroups() {
  console.log('\n🏠 Eliminando grupos...\n');

  const userIds = Object.values(users).map(u => u.id);
  let deleted = 0;

  for (const userId of userIds) {
    // Buscar en groups_v2
    const groupsSnapshot = await db.collection('groups_v2')
      .where('members', 'array-contains', userId)
      .get();

    for (const doc of groupsSnapshot.docs) {
      const data = doc.data();
      const members = data.members || [];

      // Solo eliminar si TODOS los miembros son de prueba
      const allTestUsers = members.every(id => userIds.includes(id));

      if (allTestUsers) {
        // Eliminar mensajes
        const msgDeleted = await deleteSubcollection(`groups_v2/${doc.id}/messages`);
        console.log(`   🗑️ Grupo "${data.name}": ${msgDeleted} mensajes eliminados`);

        // Eliminar miembros subcollection
        await deleteSubcollection(`groups_v2/${doc.id}/members`);

        // Eliminar typing
        await deleteSubcollection(`groups_v2/${doc.id}/typing`);

        // Eliminar grupo
        await doc.ref.delete();
        deleted++;
        console.log(`   🗑️ Grupo "${data.name}" eliminado`);
      }
    }
  }

  console.log(`   ✅ ${deleted} grupos eliminados`);
  return deleted;
}

/**
 * Limpiar vinculaciones parent-child
 */
async function cleanParentChildLinks() {
  console.log('\n👨‍👩‍👧‍👦 Limpiando vinculaciones parent-child...\n');

  const userIds = Object.values(users).map(u => u.id);

  for (const [key, user] of Object.entries(users)) {
    // Quitar linkedChildrenIds que sean usuarios de prueba
    const userDoc = await db.collection('users').doc(user.id).get();
    if (userDoc.exists) {
      const data = userDoc.data();
      const linkedChildren = data.linkedChildrenIds || [];

      // Filtrar solo los que NO son de prueba
      const filteredChildren = linkedChildren.filter(id => !userIds.includes(id));

      await db.collection('users').doc(user.id).update({
        linkedChildrenIds: filteredChildren
      });

      const removed = linkedChildren.length - filteredChildren.length;
      if (removed > 0) {
        console.log(`   ✅ ${user.name}: ${removed} vinculaciones removidas`);
      }
    }
  }
}

/**
 * Main
 */
async function main() {
  console.log('╔═══════════════════════════════════════════════════════════════╗');
  console.log('║  LIMPIEZA DE DATOS DE DEMO (usuarios ficticios)               ║');
  console.log('╚═══════════════════════════════════════════════════════════════╝');

  try {
    // Buscar usuarios
    const foundCount = await findTestUsers();

    if (foundCount === 0) {
      console.log('\n⚠️ No se encontraron usuarios de prueba.\n');
      process.exit(0);
    }

    console.log(`\n📊 Se encontraron ${foundCount} usuarios de prueba.\n`);

    // Eliminar datos
    await deleteContacts();
    await deleteChats();
    await deleteGroups();
    await cleanParentChildLinks();

    console.log('\n╔═══════════════════════════════════════════════════════════════╗');
    console.log('║  ✅ LIMPIEZA COMPLETADA                                       ║');
    console.log('╚═══════════════════════════════════════════════════════════════╝\n');

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    console.error(error.stack);
  } finally {
    process.exit(0);
  }
}

main();
