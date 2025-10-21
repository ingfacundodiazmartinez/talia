const admin = require('firebase-admin');

// Inicializar Firebase Admin
const serviceAccount = require('../functions/talia-chat-app-v2-firebase-adminsdk-z6s29-49f0d17d68.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function checkVoIPToken() {
  const userId = 'pLz0EBu7ByYw2AfjSXfwSu5F9d63'; // Facu (padre)

  const userDoc = await db.collection('users').doc(userId).get();

  if (!userDoc.exists) {
    console.log('❌ Usuario no encontrado');
    return;
  }

  const data = userDoc.data();

  console.log('\n📱 VoIP Token Info para Facu (padre):');
  console.log('=====================================');
  console.log('Token:', data.voipToken || 'NO TIENE');
  console.log('Updated:', data.voipTokenUpdatedAt?.toDate() || 'NUNCA');
  console.log('\n📱 FCM Token (para comparación):');
  console.log('Token:', data.fcmToken ? data.fcmToken.substring(0, 30) + '...' : 'NO TIENE');
  console.log('Updated:', data.fcmTokenUpdatedAt?.toDate() || 'NUNCA');

  process.exit(0);
}

checkVoIPToken().catch(err => {
  console.error('Error:', err);
  process.exit(1);
});
