const admin = require('firebase-admin');
admin.initializeApp({projectId: 'talia-chat-app-v2'});
const db = admin.firestore();

(async () => {
  // Facu (parent) and Oli (child)
  const facuId = 'pITOJtAy8If7Fzi6UnxeP1sYqJA3';
  const oliId = 'AxEt9zqN5SbY0gZ70zzPSkgEnTk2';

  const ids = [facuId, oliId].sort();
  const chatId = `${ids[0]}_${ids[1]}`;
  console.log(`ChatId: ${chatId}`);

  // Chat doc
  const chatDoc = await db.collection('chats').doc(chatId).get();
  if (chatDoc.exists) {
    const d = chatDoc.data();
    console.log('Chat exists:');
    console.log('  participants:', d.participants);
    console.log('  moderationEnabled:', d.moderationEnabled);
    console.log('  visible:', d.visible);
    console.log('  lastMessage:', d.lastMessage);
  } else {
    console.log('NO HAY CHAT');
  }

  // Contact doc
  const contactId = chatId;
  const contactDoc = await db.collection('contacts').doc(contactId).get();
  if (contactDoc.exists) {
    const d = contactDoc.data();
    console.log('\nContact exists:');
    console.log('  status:', d.status);
    console.log('  moderationSettings:', JSON.stringify(d.moderationSettings));
    console.log('  approvals:', JSON.stringify(d.approvals));
  } else {
    console.log('\nNO HAY CONTACT entre Facu y Oli');
  }

  // Recent messages
  const msgs = await db.collection('chats').doc(chatId).collection('messages')
    .orderBy('timestamp', 'desc').limit(5).get();
  console.log(`\nUltimos ${msgs.size} mensajes:`);
  for (const m of msgs.docs) {
    const md = m.data();
    console.log(`  - ${m.id}: status=${md.moderationStatus || 'n/a'} text=${(md.text || '').substring(0, 30)} sender=${md.senderId}`);
  }
})().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
