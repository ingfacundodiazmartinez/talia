/**
 * Script para diagnosticar problemas con un número de teléfono
 *
 * Uso: node diagnose-phone.js +5493885087814
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin (usa las credenciales por defecto del proyecto)
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const auth = admin.auth();

async function diagnosePhone(phoneNumber) {
  console.log('\n' + '='.repeat(60));
  console.log(`DIAGNÓSTICO PARA TELÉFONO: ${phoneNumber}`);
  console.log('='.repeat(60) + '\n');

  // 1. Buscar documentos en Firestore con este teléfono
  console.log('1. BUSCANDO EN FIRESTORE (collection: users)...\n');

  const usersQuery = await db.collection('users')
    .where('phone', '==', phoneNumber)
    .get();

  if (usersQuery.empty) {
    console.log('   ❌ No se encontró ningún documento con este teléfono\n');
  } else {
    console.log(`   ✅ Se encontraron ${usersQuery.size} documento(s):\n`);

    for (const doc of usersQuery.docs) {
      const data = doc.data();
      console.log(`   📄 Document ID (UID): ${doc.id}`);
      console.log(`      - name: ${data.name || '(sin nombre)'}`);
      console.log(`      - role: ${data.role || '(sin rol)'}`);
      console.log(`      - phone: ${data.phone}`);
      console.log(`      - createdAt: ${data.createdAt?.toDate?.() || data.createdAt || '(sin fecha)'}`);
      console.log(`      - migratedTo: ${data.migratedTo || '(no migrado)'}`);
      console.log(`      - migratedFrom: ${data.migratedFrom || '(no migrado)'}`);

      // 2. Verificar si este UID existe en Firebase Auth
      console.log(`\n      🔐 Verificando en Firebase Auth...`);
      try {
        const authUser = await auth.getUser(doc.id);
        console.log(`      ✅ Usuario Auth EXISTE`);
        console.log(`         - Auth UID: ${authUser.uid}`);
        console.log(`         - Auth Phone: ${authUser.phoneNumber || '(sin teléfono)'}`);
        console.log(`         - Auth Created: ${authUser.metadata.creationTime}`);
        console.log(`         - Auth Last Login: ${authUser.metadata.lastSignInTime}`);
      } catch (authError) {
        if (authError.code === 'auth/user-not-found') {
          console.log(`      ❌ Usuario Auth NO EXISTE (documento huérfano!)`);
        } else {
          console.log(`      ⚠️ Error verificando Auth: ${authError.message}`);
        }
      }
      console.log('');
    }
  }

  // 3. Buscar en Firebase Auth por teléfono
  console.log('\n2. BUSCANDO EN FIREBASE AUTH POR TELÉFONO...\n');

  try {
    const authUser = await auth.getUserByPhoneNumber(phoneNumber);
    console.log(`   ✅ Usuario Auth encontrado:`);
    console.log(`      - Auth UID: ${authUser.uid}`);
    console.log(`      - Auth Phone: ${authUser.phoneNumber}`);
    console.log(`      - Auth Created: ${authUser.metadata.creationTime}`);
    console.log(`      - Auth Last Login: ${authUser.metadata.lastSignInTime}`);

    // Verificar si este UID tiene documento en Firestore
    const firestoreDoc = await db.collection('users').doc(authUser.uid).get();
    if (firestoreDoc.exists) {
      console.log(`      ✅ Documento Firestore EXISTE para este Auth UID`);
    } else {
      console.log(`      ❌ Documento Firestore NO EXISTE para este Auth UID`);
    }
  } catch (authError) {
    if (authError.code === 'auth/user-not-found') {
      console.log(`   ❌ No existe usuario en Firebase Auth con este teléfono`);
    } else {
      console.log(`   ⚠️ Error: ${authError.message}`);
    }
  }

  console.log('\n' + '='.repeat(60));
  console.log('FIN DEL DIAGNÓSTICO');
  console.log('='.repeat(60) + '\n');
}

// Ejecutar
const phone = process.argv[2];
if (!phone) {
  console.log('Uso: node diagnose-phone.js +5493885087814');
  process.exit(1);
}

diagnosePhone(phone)
  .then(() => process.exit(0))
  .catch(err => {
    console.error('Error:', err);
    process.exit(1);
  });
