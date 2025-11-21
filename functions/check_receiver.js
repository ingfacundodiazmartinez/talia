const admin = require('firebase-admin');
const serviceAccount = require('/Users/olagg/Personal/talia/serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function checkReceiver() {
  const receiverId = 'MNgyNxxDoCYKeLn7t4lsdTktEwq1';

  const userDoc = await db.collection('users').doc(receiverId).get();

  if (!userDoc.exists) {
    console.log('❌ Receiver document does not exist!');
    return;
  }

  const userData = userDoc.data();
  console.log('\n📱 Receiver Document:');
  console.log('  Name:', userData.name);
  console.log('  Phone:', userData.phone);
  console.log('  fcmToken:', userData.fcmToken ? userData.fcmToken.substring(0, 30) + '...' : 'NULL');
  console.log('  voipToken:', userData.voipToken || 'NULL');
  console.log('  fcmTokenUpdatedAt:', userData.fcmTokenUpdatedAt);

  if (!userData.fcmToken && !userData.voipToken) {
    console.log('\n⚠️ PROBLEM: Receiver has NO push tokens configured!');
    console.log('   This is why notifications are not being sent.');
  }

  process.exit(0);
}

checkReceiver().catch(error => {
  console.error('Error:', error);
  process.exit(1);
});
