const admin = require('firebase-admin');
const serviceAccount = require('./talia-chat-app-v2-firebase-adminsdk-uqmvb-beac3a8fca.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function createBlock() {
  const childId = 'Cw2quhc0SLVKubEI9v71F7vXBk62';
  const contactId = '973N2o5LCSQj6sAi5u9Ff7yJCBi2';
  
  const ids = [childId, contactId].sort();
  const chatId = ids[0] + '_' + ids[1];
  
  console.log('🔒 Creando bloqueo de chat...');
  console.log('   childId:', childId);
  console.log('   contactId:', contactId);
  console.log('   chatId:', chatId);
  
  await db.collection('blocked_chats').doc(chatId).set({
    chatId: chatId,
    childId: childId,
    contactId: contactId,
    blockedAt: admin.firestore.FieldValue.serverTimestamp(),
    blockedBy: 'test_manual',
    reason: 'Contacto revocado por el padre (TEST MANUAL)',
    isActive: true,
    participants: [childId, contactId],
  });
  
  console.log('✅ Documento creado en blocked_chats/' + chatId);
  
  process.exit(0);
}

createBlock().catch(console.error);
