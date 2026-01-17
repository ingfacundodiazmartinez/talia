const admin = require('firebase-admin');
const serviceAccount = require('./service-account-key.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

async function checkNotifications() {
  console.log('🔍 Verificando notificaciones de story_approval_request...\\n');

  const snapshot = await db.collection('notifications')
    .where('type', '==', 'story_approval_request')
    .orderBy('timestamp', 'desc')
    .limit(5)
    .get();

  if (snapshot.empty) {
    console.log('❌ No hay notificaciones de story_approval_request');
    return;
  }

  snapshot.forEach(doc => {
    const data = doc.data();
    console.log('📄 Notification ID:', doc.id);
    console.log('   userId:', data.userId);
    console.log('   type:', data.type);
    console.log('   title:', data.title);
    console.log('   body:', data.body);
    console.log('   senderId:', data.senderId);
    console.log('   timestamp:', data.timestamp);
    console.log('   Fields in document:', Object.keys(data));
    console.log('');
  });

  process.exit(0);
}

checkNotifications().catch(error => {
  console.error('❌ Error:', error);
  process.exit(1);
});
