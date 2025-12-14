/**
 * Buscar usuarios de prueba por número de teléfono
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// Números a buscar
const phones = [
  '+5493875433442', // Facu
  '+5493875433445', // Prueba 1
  '+5493875433446', // Prueba 2
  '+5493875433447'  // Prueba 3
];

async function findUsers() {
  console.log('\n🔍 Buscando usuarios por teléfono...\n');

  const usersSnapshot = await db.collection('users').get();

  console.log(`📊 Total usuarios: ${usersSnapshot.size}\n`);

  const foundUsers = [];

  usersSnapshot.forEach(doc => {
    const data = doc.data();
    const phone = data.phone || data.phoneNumber || '';

    // Buscar coincidencia parcial (por si el formato varía)
    for (const searchPhone of phones) {
      // Normalizar: quitar + y espacios
      const normalizedSearch = searchPhone.replace(/[+\s-]/g, '');
      const normalizedPhone = phone.replace(/[+\s-]/g, '');

      if (normalizedPhone.includes(normalizedSearch.slice(-10)) ||
          normalizedSearch.includes(normalizedPhone.slice(-10))) {
        foundUsers.push({
          id: doc.id,
          name: data.name || data.displayName || 'Sin nombre',
          phone: phone,
          email: data.email || '',
          role: data.role || 'unknown',
          searchedPhone: searchPhone
        });
        break;
      }
    }
  });

  if (foundUsers.length > 0) {
    console.log('✅ Usuarios encontrados:\n');
    foundUsers.forEach(u => {
      console.log(`   📱 ${u.searchedPhone}`);
      console.log(`      ID: ${u.id}`);
      console.log(`      Nombre: ${u.name}`);
      console.log(`      Role: ${u.role}`);
      console.log(`      Phone en DB: ${u.phone}`);
      console.log('');
    });
  } else {
    console.log('❌ No se encontraron usuarios con esos teléfonos.\n');
    console.log('📋 Mostrando todos los usuarios con teléfono:\n');

    usersSnapshot.forEach(doc => {
      const data = doc.data();
      if (data.phone || data.phoneNumber) {
        console.log(`   - ${data.name || 'Sin nombre'} | ${data.phone || data.phoneNumber} | ${doc.id}`);
      }
    });
  }
}

findUsers().then(() => process.exit(0));
