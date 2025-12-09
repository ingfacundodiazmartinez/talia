const admin = require('firebase-admin');
const { applicationDefault } = require('firebase-admin/app');

// Initialize with default credentials
if (admin.apps.length === 0) {
  admin.initializeApp({
    credential: applicationDefault(),
    projectId: 'talia-chat'
  });
}

const db = admin.firestore();

async function checkUsers() {
  const userId1 = 'ldUCB59Xo7gfoGlo948pHJZjeRF3';
  const userId2 = 'a6KLenhHOoXrfbf6oyRILG8iJuw2';

  // Get both users
  const [user1Doc, user2Doc] = await Promise.all([
    db.collection('users').doc(userId1).get(),
    db.collection('users').doc(userId2).get()
  ]);

  const user1 = user1Doc.data();
  const user2 = user2Doc.data();

  console.log('=== USER 1 (Tu) ===');
  console.log('Name:', user1?.name);
  console.log('Role:', user1?.role);
  console.log('Phone:', user1?.phone);
  console.log('phoneHash:', user1?.phoneHash ? user1.phoneHash.substring(0,20) + '...' : 'NO TIENE');
  console.log('devicePhoneHashes count:', user1?.devicePhoneHashes?.length || 0);
  console.log('lastContactsSync:', user1?.lastContactsSync?.toDate?.() || 'NO HAY');

  console.log('');
  console.log('=== USER 2 (Flor) ===');
  console.log('Name:', user2?.name);
  console.log('Role:', user2?.role);
  console.log('Phone:', user2?.phone);
  console.log('phoneHash:', user2?.phoneHash ? user2.phoneHash.substring(0,20) + '...' : 'NO TIENE');
  console.log('devicePhoneHashes count:', user2?.devicePhoneHashes?.length || 0);
  console.log('lastContactsSync:', user2?.lastContactsSync?.toDate?.() || 'NO HAY');

  // Check bidirectionality
  console.log('');
  console.log('=== VERIFICACIÓN BIDIRECCIONAL ===');

  if (user1?.phoneHash && user2?.devicePhoneHashes) {
    const user2HasUser1 = user2.devicePhoneHashes.includes(user1.phoneHash);
    console.log('Flor tiene tu phoneHash en sus devicePhoneHashes?', user2HasUser1 ? 'SI' : 'NO');
  } else {
    console.log('Flor tiene tu phoneHash? NO SE PUEDE VERIFICAR (faltan datos)');
    if (!user1?.phoneHash) console.log('  - Tu phoneHash no existe');
    if (!user2?.devicePhoneHashes) console.log('  - Flor no tiene devicePhoneHashes');
  }

  if (user2?.phoneHash && user1?.devicePhoneHashes) {
    const user1HasUser2 = user1.devicePhoneHashes.includes(user2.phoneHash);
    console.log('Tu tienes el phoneHash de Flor en devicePhoneHashes?', user1HasUser2 ? 'SI' : 'NO');
  } else {
    console.log('Tu tienes el phoneHash de Flor? NO SE PUEDE VERIFICAR (faltan datos)');
    if (!user2?.phoneHash) console.log('  - Flor phoneHash no existe');
    if (!user1?.devicePhoneHashes) console.log('  - Tu no tienes devicePhoneHashes');
  }

  // Check if contact exists
  console.log('');
  console.log('=== CONTACTO EXISTENTE ===');
  const sortedUsers = [userId1, userId2].sort();
  const contactQuery = await db.collection('contacts')
    .where('users', '==', sortedUsers)
    .get();

  if (contactQuery.empty) {
    console.log('NO existe contacto entre ustedes');
  } else {
    const contact = contactQuery.docs[0].data();
    console.log('Contacto encontrado:', contactQuery.docs[0].id);
    console.log('Status:', contact.status);
    console.log('CreatedAt:', contact.createdAt?.toDate?.());
  }

  // Check chat
  const chatId = sortedUsers.join('_');
  const chatDoc = await db.collection('chats').doc(chatId).get();
  console.log('');
  console.log('=== CHAT ===');
  if (chatDoc.exists) {
    const chat = chatDoc.data();
    console.log('Chat existe:', chatId);
    console.log('isValidChat:', chat.isValidChat);
    console.log('visible:', chat.visible);
  } else {
    console.log('NO existe chat entre ustedes');
  }
}

checkUsers().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
