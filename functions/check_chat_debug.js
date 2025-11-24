const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function checkChat() {
  const chatId = 'MNgyNxxDoCYKeLn7t4lsdTktEwq1_kRp6m9NwlYdLVBlUCjstqgCGof32';
  console.log(`🔍 Verificando chat: ${chatId}\n`);

  const chatDoc = await db.collection('chats').doc(chatId).get();

  if (!chatDoc.exists) {
    console.log('❌ Chat NO existe');
    return;
  }

  const data = chatDoc.data();

  console.log('📄 VERIFICACIÓN DE CAMPOS CRÍTICOS:');
  console.log('=' .repeat(60));
  console.log(`  lastMessageAt:     ${data.lastMessageAt ? '✅ EXISTS - ' + data.lastMessageAt.toDate() : '❌ NULL/UNDEFINED'}`);
  console.log(`  lastMessageTime:   ${data.lastMessageTime ? '✅ EXISTS - ' + data.lastMessageTime.toDate() : '❌ NULL/UNDEFINED'}`);
  console.log(`  lastMessage:       "${data.lastMessage || 'EMPTY'}"`);
  console.log(`  lastMessageSender: ${data.lastMessageSender || 'EMPTY'}`);
  console.log('=' .repeat(60));

  console.log('\n📋 DOCUMENTO COMPLETO:');
  console.log(JSON.stringify(data, (key, value) => {
    if (value && typeof value.toDate === 'function') {
      return value.toDate().toISOString();
    }
    return value;
  }, 2));

  process.exit(0);
}

checkChat().catch(err => {
  console.error('❌ Error:', err);
  process.exit(1);
});
