const admin = require('firebase-admin');
admin.initializeApp({projectId: 'talia-chat-app-v2'});
const db = admin.firestore();

(async () => {
  const adulto = await db.collection('users').where('phone', '==', '+5493875433447').limit(1).get();
  const nino = await db.collection('users').where('phone', '==', '+5493875433443').limit(1).get();
  if (adulto.empty) { console.log('ADULTO NO ENCONTRADO'); process.exit(1); }
  if (nino.empty) { console.log('NINO NO ENCONTRADO'); process.exit(1); }
  const adultoId = adulto.docs[0].id;
  const ninoId = nino.docs[0].id;
  console.log(`Adulto: ${adultoId} (${adulto.docs[0].data().name})`);
  console.log(`Nino: ${ninoId} (${nino.docs[0].data().name})`);

  const ids = [adultoId, ninoId].sort();
  const contactId = `${ids[0]}_${ids[1]}`;
  console.log(`ContactId: ${contactId}`);

  const doc = await db.collection('contacts').doc(contactId).get();
  if (doc.exists) {
    const data = doc.data();
    console.log('Contact status:', data.status);
    console.log('Approvals:', JSON.stringify(data.approvals));
    await db.collection('contacts').doc(contactId).delete();
    console.log('CONTACT DELETED');
  } else {
    console.log('NO HAY CONTACTO');
  }

  // Buscar y eliminar chat entre ambos usuarios
  const chatsQuery = await db.collection('chats').where('participants', '==', ids).get();
  for (const chatDoc of chatsQuery.docs) {
    const chatId = chatDoc.id;
    console.log(`Found chat: ${chatId}`);
    // Eliminar todos los mensajes subcollection
    const msgsSnap = await db.collection('chats').doc(chatId).collection('messages').get();
    console.log(`  Deleting ${msgsSnap.size} messages...`);
    const batch = db.batch();
    msgsSnap.docs.forEach(m => batch.delete(m.ref));
    await batch.commit();
    // Eliminar el chat doc
    await chatDoc.ref.delete();
    console.log(`  CHAT ${chatId} DELETED`);
  }
  if (chatsQuery.empty) {
    console.log('NO HAY CHAT');
  }

  // Eliminar story_approval_requests relacionados (si existen)
  const arQuery = await db.collection('story_approval_requests').where('contactId', '==', contactId).get();
  for (const d of arQuery.docs) {
    await d.ref.delete();
    console.log('Deleted story_approval_request:', d.id);
  }
})().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
