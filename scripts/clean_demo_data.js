/**
 * Script para limpiar datos de demostración
 *
 * PRECAUCIÓN: Este script eliminará todas las cuentas y datos marcados como demo
 *
 * Uso:
 *   node scripts/clean_demo_data.js
 */

const admin = require('firebase-admin');
const readline = require('readline');

// Inicializar Firebase Admin
const serviceAccount = require('../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL: 'https://talia-chat-app-v2.firebaseio.com'
});

const db = admin.firestore();
const auth = admin.auth();

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(query) {
  return new Promise(resolve => rl.question(query, resolve));
}

/**
 * Eliminar usuarios demo de Auth
 */
async function deleteDemoAuthUsers() {
  console.log('\n🔍 Buscando usuarios demo en Firebase Auth...');

  const listUsersResult = await auth.listUsers();
  const demoUsers = listUsersResult.users.filter(
    user => user.email && user.email.includes('.demo@talia.app')
  );

  console.log(`📋 Encontrados ${demoUsers.length} usuarios demo en Auth`);

  for (const user of demoUsers) {
    try {
      await auth.deleteUser(user.uid);
      console.log(`✓ Eliminado de Auth: ${user.email} (${user.uid})`);
    } catch (error) {
      console.error(`✗ Error eliminando ${user.email}:`, error.message);
    }
  }
}

/**
 * Eliminar colección completa
 */
async function deleteCollection(collectionPath, batchSize = 100) {
  const collectionRef = db.collection(collectionPath);
  const query = collectionRef.where('isDemo', '==', true).limit(batchSize);

  return new Promise((resolve, reject) => {
    deleteQueryBatch(query, resolve).catch(reject);
  });
}

async function deleteQueryBatch(query, resolve) {
  const snapshot = await query.get();

  const batchSize = snapshot.size;
  if (batchSize === 0) {
    resolve();
    return;
  }

  const batch = db.batch();
  snapshot.docs.forEach((doc) => {
    batch.delete(doc.ref);
  });
  await batch.commit();

  process.nextTick(() => {
    deleteQueryBatch(query, resolve);
  });
}

/**
 * Eliminar documentos de colección sin campo isDemo
 */
async function deleteDemoDocuments(collectionPath, emailField) {
  console.log(`\n🔍 Limpiando ${collectionPath}...`);

  const snapshot = await db.collection(collectionPath).get();
  let deleted = 0;

  const batch = db.batch();
  let count = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();

    // Verificar si es demo por email o flag isDemo
    const isDemo = data.isDemo === true ||
                   (emailField && data[emailField]?.includes('.demo@talia.app'));

    if (isDemo) {
      batch.delete(doc.ref);
      count++;
      deleted++;

      // Commit cada 500 documentos
      if (count >= 500) {
        await batch.commit();
        count = 0;
      }
    }
  }

  // Commit remaining
  if (count > 0) {
    await batch.commit();
  }

  console.log(`✓ Eliminados ${deleted} documentos de ${collectionPath}`);
}

/**
 * Limpiar subcollections
 */
async function cleanChatMessages() {
  console.log('\n🔍 Limpiando mensajes de chats demo...');

  const chatsSnapshot = await db.collection('chats').get();
  let deletedChats = 0;

  for (const chatDoc of chatsSnapshot.docs) {
    const participants = chatDoc.data().participants || [];

    // Verificar si algún participante es demo
    let isDemoChat = false;
    for (const participantId of participants) {
      const userDoc = await db.collection('users').doc(participantId).get();
      if (userDoc.exists && userDoc.data().isDemo === true) {
        isDemoChat = true;
        break;
      }
    }

    if (isDemoChat) {
      // Eliminar mensajes
      const messagesSnapshot = await chatDoc.ref.collection('messages').get();
      const messageBatch = db.batch();
      messagesSnapshot.docs.forEach(msg => messageBatch.delete(msg.ref));
      await messageBatch.commit();

      // Eliminar chat
      await chatDoc.ref.delete();
      deletedChats++;
    }
  }

  console.log(`✓ Eliminados ${deletedChats} chats demo`);
}

async function cleanGroupMessages() {
  console.log('\n🔍 Limpiando mensajes de grupos demo...');

  const groupsSnapshot = await db.collection('groups').where('isDemo', '==', true).get();

  for (const groupDoc of groupsSnapshot.docs) {
    // Eliminar mensajes
    const messagesSnapshot = await groupDoc.ref.collection('messages').get();
    const messageBatch = db.batch();
    messagesSnapshot.docs.forEach(msg => messageBatch.delete(msg.ref));
    await messageBatch.commit();

    // Eliminar grupo
    await groupDoc.ref.delete();
  }

  console.log(`✓ Eliminados ${groupsSnapshot.size} grupos demo`);
}

/**
 * Script principal
 */
async function main() {
  console.log('=================================');
  console.log('   LIMPIEZA DE DATOS DE DEMO');
  console.log('=================================');
  console.log('\n⚠️  ADVERTENCIA: Este script eliminará:');
  console.log('   • Usuarios demo de Firebase Auth');
  console.log('   • Documentos marcados con isDemo: true');
  console.log('   • Chats y grupos con participantes demo');
  console.log('   • Mensajes de chats y grupos demo');
  console.log('   • Historias, ubicaciones y reportes demo\n');

  const answer = await question('¿Estás seguro? Escribe "ELIMINAR" para confirmar: ');

  if (answer !== 'ELIMINAR') {
    console.log('\n❌ Operación cancelada');
    rl.close();
    process.exit(0);
  }

  console.log('\n🚀 Iniciando limpieza...\n');

  try {
    // 1. Limpiar colecciones simples con isDemo flag
    const collectionsWithFlag = [
      'users',
      'stories',
      'weekly_reports',
      'user_locations',
    ];

    for (const collection of collectionsWithFlag) {
      await deleteCollection(collection);
      console.log(`✓ Limpiada colección: ${collection}`);
    }

    // 2. Limpiar colecciones relacionales
    await deleteDemoDocuments('parent_children', null);
    await deleteDemoDocuments('contacts', null);
    await deleteDemoDocuments('permission_requests', null);

    // 3. Limpiar chats y grupos (con subcollections)
    await cleanChatMessages();
    await cleanGroupMessages();

    // 4. Eliminar usuarios de Auth (al final)
    await deleteDemoAuthUsers();

    console.log('\n✅ LIMPIEZA COMPLETADA\n');
    console.log('=================================\n');

  } catch (error) {
    console.error('❌ Error durante la limpieza:', error);
    process.exit(1);
  }

  rl.close();
  process.exit(0);
}

// Ejecutar
main();
