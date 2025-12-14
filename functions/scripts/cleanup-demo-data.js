/**
 * Script para ELIMINAR todos los mensajes de demo generados
 * Solo elimina mensajes, NO elimina chats ni contactos
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// IDs de chats y grupos donde se generaron mensajes de demo
const DEMO_CHAT_IDS = [
  '77m006WREsaxzVO726xs8wCReBJ3_ldUCB59Xo7gfoGlo948pHJZjeRF3', // Facu-Tadeo
  '60iJdkq4aEXLj9JHSVBD9JsxtBR2_oEhhRP6mIuh1TlyShmdfqDfVPeu2', // Mica-Oli
  '77m006WREsaxzVO726xs8wCReBJ3_oEhhRP6mIuh1TlyShmdfqDfVPeu2'  // Tadeo-Oli
];

const DEMO_GROUP_IDS = [
  'YNjFtdLEmszYXo0e9V1c' // Casita
];

/**
 * Elimina todos los mensajes de una colección
 */
async function deleteAllMessages(collectionPath) {
  const messagesRef = db.collection(collectionPath);

  let totalDeleted = 0;
  let snapshot = await messagesRef.limit(500).get();

  while (!snapshot.empty) {
    const batch = db.batch();
    snapshot.docs.forEach(doc => {
      batch.delete(doc.ref);
      totalDeleted++;
    });
    await batch.commit();

    snapshot = await messagesRef.limit(500).get();
  }

  return totalDeleted;
}

/**
 * Resetea metadata de un chat
 */
async function resetChatMetadata(chatId) {
  try {
    await db.collection('chats').doc(chatId).update({
      lastMessage: null,
      lastMessageAt: null,
      lastMessageSender: null,
      lastMessageId: null,
      lastMessageType: null,
      lastActivity: null,
      moderationEnabled: false,
      moderationLevel: null
    });
  } catch (e) {
    console.log(`   ⚠️ No se pudo resetear metadata de chat ${chatId}: ${e.message}`);
  }
}

/**
 * Resetea metadata de un grupo
 */
async function resetGroupMetadata(groupId) {
  try {
    await db.collection('groups_v2').doc(groupId).update({
      lastMessage: null,
      lastMessageAt: null,
      lastMessageSender: null,
      lastActivity: null
    });
  } catch (e) {
    console.log(`   ⚠️ No se pudo resetear metadata de grupo ${groupId}: ${e.message}`);
  }
}

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════════╗');
  console.log('║  LIMPIEZA DE DATOS DE DEMO                                    ║');
  console.log('╚═══════════════════════════════════════════════════════════════╝\n');

  try {
    // Eliminar mensajes de chats 1:1
    console.log('🗑️  Eliminando mensajes de chats 1:1...\n');

    for (const chatId of DEMO_CHAT_IDS) {
      const deleted = await deleteAllMessages(`chats/${chatId}/messages`);
      console.log(`   ✅ Chat ${chatId.substring(0, 20)}...: ${deleted} mensajes eliminados`);
      await resetChatMetadata(chatId);
    }

    // Eliminar mensajes de grupos
    console.log('\n🗑️  Eliminando mensajes de grupos...\n');

    for (const groupId of DEMO_GROUP_IDS) {
      const deleted = await deleteAllMessages(`groups_v2/${groupId}/messages`);
      console.log(`   ✅ Grupo ${groupId}: ${deleted} mensajes eliminados`);
      await resetGroupMetadata(groupId);
    }

    console.log('\n╔═══════════════════════════════════════════════════════════════╗');
    console.log('║  ✅ LIMPIEZA COMPLETADA                                       ║');
    console.log('╚═══════════════════════════════════════════════════════════════╝\n');

  } catch (error) {
    console.error('❌ Error:', error.message);
    console.error(error.stack);
  } finally {
    process.exit(0);
  }
}

main();
