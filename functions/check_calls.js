const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function checkRecentCalls() {
  const snapshot = await db.collection('video_calls')
    .orderBy('createdAt', 'desc')
    .limit(5)
    .get();
  
  console.log('\n📞 Últimas 5 llamadas en Firestore:\n');
  
  snapshot.forEach(doc => {
    const data = doc.data();
    console.log(`ID: ${doc.id}`);
    console.log(`  Caller: ${data.callerName} (${data.callerId})`);
    console.log(`  Receiver: ${data.receiverName} (${data.receiverId})`);
    console.log(`  Type: ${data.callType || 'NO DEFINIDO ⚠️'}`);
    console.log(`  Status: ${data.status}`);
    console.log(`  Created: ${data.createdAt?.toDate()}`);
    console.log('---');
  });
  
  process.exit(0);
}

checkRecentCalls().catch(console.error);
