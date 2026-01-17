const admin = require('firebase-admin');

// Inicializar Firebase Admin
const serviceAccount = require('./talia-79da1-firebase-adminsdk-aokcy-b77e2ef1f5.json');
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function checkNotifications() {
  try {
    console.log('🔍 Buscando notificaciones de tipo story_approval_request...\n');

    const snapshot = await db.collection('notifications')
      .where('type', '==', 'story_approval_request')
      .get();

    console.log(`📊 Total encontradas: ${snapshot.size}\n`);

    snapshot.forEach(doc => {
      const data = doc.data();
      console.log(`📧 ID: ${doc.id}`);
      console.log(`   userId: ${data.userId}`);
      console.log(`   senderId: ${data.senderId}`);
      console.log(`   type: ${data.type}`);
      console.log(`   title: ${data.title}`);
      console.log(`   read: ${data.read}`);
      console.log(`   timestamp: ${data.timestamp ? data.timestamp.toDate() : 'NULL'}`);
      console.log(`   data:`, data.data);
      console.log('');
    });

    process.exit(0);
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  }
}

checkNotifications();
