const admin = require('firebase-admin');

// Usar las credenciales que ya están en functions
process.env.GOOGLE_APPLICATION_CREDENTIALS = '../functions/.env';

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

async function deleteVoIPToken() {
  const userId = 'pLz0EBu7ByYw2AfjSXfwSu5F9d63'; // Facu (padre)

  console.log(`\n🗑️ Eliminando token VoIP viejo para userId: ${userId}`);

  await db.collection('users').doc(userId).update({
    voipToken: admin.firestore.FieldValue.delete(),
    voipTokenUpdatedAt: admin.firestore.FieldValue.delete()
  });

  console.log('✅ Token VoIP eliminado de Firestore');
  console.log('\n📱 Ahora abre la app en el iPhone y haz login de nuevo');
  console.log('   El token se regenerará automáticamente\n');

  process.exit(0);
}

deleteVoIPToken().catch(err => {
  console.error('❌ Error:', err);
  process.exit(1);
});
