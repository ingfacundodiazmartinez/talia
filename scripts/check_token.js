const admin = require('firebase-admin');

// Usar credenciales de aplicación por defecto
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

async function checkToken() {
  const userId = 'tq1uus55o8VlZ890IlCEGwtxUc83'; // Facu (padre)

  const userDoc = await db.collection('users').doc(userId).get();

  if (!userDoc.exists) {
    console.log('❌ Usuario no encontrado');
    return;
  }

  const data = userDoc.data();

  console.log('\n📱 Token Info:');
  console.log('='.repeat(50));
  console.log('VoIP Token:', data.voipToken || 'NO TIENE');
  console.log('VoIP Updated:', data.voipTokenUpdatedAt?.toDate() || 'NUNCA');
  console.log('FCM Token:', data.fcmToken?.substring(0, 30) + '...' || 'NO TIENE');
  console.log('FCM Updated:', data.fcmTokenUpdatedAt?.toDate() || 'NUNCA');
  console.log('='.repeat(50));

  // Verificar si es el token viejo
  const oldToken = '74e173d9594d1ab425168c385934c29613985cde8d03cc2322706c55b2065406';
  if (data.voipToken === oldToken) {
    console.log('⚠️  ESTE ES EL TOKEN VIEJO QUE APPLE RECHAZA');
  } else if (data.voipToken) {
    console.log('✅ Este es un token NUEVO (diferente al viejo)');
  }

  process.exit(0);
}

checkToken().catch(err => {
  console.error('Error:', err);
  process.exit(1);
});
