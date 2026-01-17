const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function verifyMica() {
  const micaId = 'oZhENi0ogCadnj5rO50KH6I9Mm73';

  console.log('=== VERIFICACIÓN DE MICA ===\n');

  const micaDoc = await db.collection('users').doc(micaId).get();
  if (micaDoc.exists) {
    const data = micaDoc.data();
    console.log('ID:', micaId);
    console.log('name:', data.name);
    console.log('displayName:', data.displayName);
    console.log('phone:', data.phone);
    console.log('phoneNumber:', data.phoneNumber);
    console.log('photoURL:', data.photoURL ? 'exists' : 'null');
    console.log('role:', data.role);
  } else {
    console.log('❌ USUARIO NO EXISTE!');
    console.log('Este es el problema - el contacto de Tadeo apunta a un usuario que no existe');
  }
}

verifyMica()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
