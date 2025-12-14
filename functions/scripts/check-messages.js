/**
 * Script para verificar y limpiar mensajes en todos los chats
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// IDs de usuarios
const userIds = [
  'ldUCB59Xo7gfoGlo948pHJZjeRF3', // Facu
  '60iJdkq4aEXLj9JHSVBD9JsxtBR2', // Mica
  'oEhhRP6mIuh1TlyShmdfqDfVPeu2', // Oli
  '77m006WREsaxzVO726xs8wCReBJ3'  // Tadeo
];

async function checkAndCleanAllChats() {
  console.log('\n🔍 Verificando mensajes en Firestore...\n');

  // 1. Buscar todos los chats donde participen estos usuarios
  const chatsSnapshot = await db.collection('chats').get();

  console.log(`📊 Total chats en DB: ${chatsSnapshot.size}\n`);

  for (const chatDoc of chatsSnapshot.docs) {
    const chatId = chatDoc.id;
    const chatData = chatDoc.data();
    const participants = chatData.participants || [];

    // Verificar si algún participante es de nuestro grupo
    const hasOurUsers = participants.some(p => userIds.includes(p));

    if (hasOurUsers) {
      console.log(`\n📁 Chat: ${chatId}`);
      console.log(`   Participantes: ${participants.join(', ')}`);

      // Contar mensajes
      const messagesSnapshot = await db.collection('chats').doc(chatId).collection('messages').get();
      console.log(`   Mensajes actuales: ${messagesSnapshot.size}`);

      // Mostrar los primeros 3 mensajes
      if (messagesSnapshot.size > 0) {
        console.log('   Últimos mensajes:');
        let count = 0;
        messagesSnapshot.forEach(msgDoc => {
          if (count < 5) {
            const msg = msgDoc.data();
            const time = msg.timestamp?.toDate?.() || 'sin fecha';
            console.log(`     - "${(msg.text || '[media]').substring(0, 40)}..." (${time})`);
            count++;
          }
        });
      }
    }
  }

  // 2. Verificar grupo
  console.log('\n\n📁 Verificando grupo Casita...');
  const groupDoc = await db.collection('groups_v2').doc('YNjFtdLEmszYXo0e9V1c').get();
  if (groupDoc.exists) {
    const groupMessages = await db.collection('groups_v2').doc('YNjFtdLEmszYXo0e9V1c').collection('messages').get();
    console.log(`   Mensajes en grupo: ${groupMessages.size}`);
    groupMessages.forEach(msgDoc => {
      const msg = msgDoc.data();
      console.log(`     - "${(msg.text || '[media]').substring(0, 40)}..."`);
    });
  }
}

async function forceDeleteAllMessages() {
  console.log('\n\n🗑️  ELIMINANDO TODOS LOS MENSAJES...\n');

  // Chat IDs relevantes
  const chatIds = [
    '77m006WREsaxzVO726xs8wCReBJ3_ldUCB59Xo7gfoGlo948pHJZjeRF3', // Facu-Tadeo
    '60iJdkq4aEXLj9JHSVBD9JsxtBR2_oEhhRP6mIuh1TlyShmdfqDfVPeu2', // Mica-Oli
    '77m006WREsaxzVO726xs8wCReBJ3_oEhhRP6mIuh1TlyShmdfqDfVPeu2', // Tadeo-Oli
    '60iJdkq4aEXLj9JHSVBD9JsxtBR2_77m006WREsaxzVO726xs8wCReBJ3', // Mica-Tadeo
    '60iJdkq4aEXLj9JHSVBD9JsxtBR2_ldUCB59Xo7gfoGlo948pHJZjeRF3', // Mica-Facu
    'ldUCB59Xo7gfoGlo948pHJZjeRF3_oEhhRP6mIuh1TlyShmdfqDfVPeu2'  // Facu-Oli
  ];

  for (const chatId of chatIds) {
    const messagesRef = db.collection('chats').doc(chatId).collection('messages');
    const messages = await messagesRef.get();

    if (messages.empty) {
      console.log(`   📭 ${chatId}: vacío`);
      continue;
    }

    console.log(`   🗑️  ${chatId}: eliminando ${messages.size} mensajes...`);

    // Eliminar en batches de 500 (límite de Firestore)
    const batchSize = 500;
    let deleted = 0;

    while (true) {
      const batch = db.batch();
      const snapshot = await messagesRef.limit(batchSize).get();

      if (snapshot.empty) break;

      snapshot.docs.forEach(doc => {
        batch.delete(doc.ref);
        deleted++;
      });

      await batch.commit();
    }

    console.log(`      ✅ ${deleted} mensajes eliminados`);
  }

  // Limpiar grupo
  console.log('\n   🗑️  Limpiando grupo Casita...');
  const groupMessagesRef = db.collection('groups_v2').doc('YNjFtdLEmszYXo0e9V1c').collection('messages');
  const groupMessages = await groupMessagesRef.get();

  if (!groupMessages.empty) {
    const batch = db.batch();
    groupMessages.forEach(doc => batch.delete(doc.ref));
    await batch.commit();
    console.log(`      ✅ ${groupMessages.size} mensajes eliminados del grupo`);
  }
}

async function main() {
  const args = process.argv.slice(2);

  if (args.includes('--delete')) {
    await forceDeleteAllMessages();
    console.log('\n✅ Limpieza completada. Ahora ejecuta generate-demo-chats.js para crear los nuevos mensajes.\n');
  } else {
    await checkAndCleanAllChats();
    console.log('\n\n💡 Para eliminar todos los mensajes, ejecuta: node check-messages.js --delete\n');
  }

  process.exit(0);
}

main();
