const admin = require('firebase-admin');
const serviceAccount = require('./service-account-key.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

async function checkFormat() {
  console.log('🔍 Verificando formato de IDs en parent_children...\n');

  const snapshot = await db.collection('parent_children').limit(5).get();

  if (snapshot.empty) {
    console.log('❌ No hay documentos en parent_children');
    return;
  }

  snapshot.forEach(doc => {
    console.log('📄 Document ID:', doc.id);
    console.log('   Data:', JSON.stringify(doc.data(), null, 2));
    console.log('');
  });

  process.exit(0);
}

checkFormat().catch(error => {
  console.error('❌ Error:', error);
  process.exit(1);
});
