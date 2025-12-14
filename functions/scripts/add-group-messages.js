/**
 * Script para agregar mensajes al grupo familiar
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// IDs de usuarios (obtenidos del script anterior)
const users = {
  facu: { id: 'ldUCB59Xo7gfoGlo948pHJZjeRF3', name: 'Facu' },
  mica: { id: '60iJdkq4aEXLj9JHSVBD9JsxtBR2', name: 'Mica' },
  oli: { id: 'oEhhRP6mIuh1TlyShmdfqDfVPeu2', name: 'Oli' },
  tadeo: { id: '77m006WREsaxzVO726xs8wCReBJ3', name: 'Tadeo' }
};

const GROUP_ID = 'YNjFtdLEmszYXo0e9V1c';

function getTimestamp(minutesAgo = 0) {
  return admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - minutesAgo * 60 * 1000)
  );
}

async function createGroupMessage(groupId, senderId, senderName, text, minutesAgo = 0) {
  const messageData = {
    senderId,
    senderName,
    text,
    type: 'text',
    timestamp: getTimestamp(minutesAgo),
    readBy: [],
    deliveredTo: []
  };

  const groupRef = db.collection('groups_v2').doc(groupId);
  const ref = await groupRef.collection('messages').add(messageData);

  await groupRef.update({
    lastMessage: text.substring(0, 100),
    lastMessageAt: messageData.timestamp,
    lastMessageSender: senderId,
    lastActivity: messageData.timestamp
  });

  console.log(`   ✅ Mensaje agregado: "${text.substring(0, 30)}..."`);
  return ref.id;
}

async function clearGroupMessages(groupId) {
  const messagesRef = db.collection('groups_v2').doc(groupId).collection('messages');
  const messages = await messagesRef.get();

  if (messages.empty) {
    console.log('   📭 Grupo ya estaba vacio');
    return;
  }

  const batch = db.batch();
  messages.forEach(doc => {
    batch.delete(doc.ref);
  });
  await batch.commit();
  console.log(`   🗑️  ${messages.size} mensajes eliminados del grupo`);
}

async function main() {
  console.log('\n💬 Agregando mensajes al grupo familiar "Casita"...\n');

  try {
    // Limpiar mensajes existentes
    await clearGroupMessages(GROUP_ID);

    const mama = users.mica;
    const papa = users.facu;
    const hermano1 = users.tadeo;
    const hermano2 = users.oli;

    // Mensajes del guion
    await createGroupMessage(GROUP_ID, mama.id, mama.name, 'Chicos, hoy cenamos temprano 🍝✨', 60);
    await createGroupMessage(GROUP_ID, papa.id, papa.name, 'Genial, llego tipo 19:30 👍', 55);
    await createGroupMessage(GROUP_ID, hermano1.id, hermano1.name, '¡Bien! Después quiero ver una peli 😎🎬', 50);
    await createGroupMessage(GROUP_ID, hermano2.id, hermano2.name, 'Yo también, elijo yo hoy 😁', 45);
    await createGroupMessage(GROUP_ID, mama.id, mama.name, 'Dale, pero primero tarea 😉📚', 40);

    console.log('\n✅ Grupo actualizado con 5 mensajes\n');

  } catch (error) {
    console.error('❌ Error:', error.message);
  } finally {
    process.exit(0);
  }
}

main();
