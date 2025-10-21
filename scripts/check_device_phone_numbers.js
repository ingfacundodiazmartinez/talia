/**
 * Script para verificar el campo devicePhoneNumbers en usuarios
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

async function checkDevicePhoneNumbers() {
  try {
    console.log('\n📱 ========== VERIFICACIÓN devicePhoneNumbers ==========\n');

    const usersSnapshot = await db.collection('users').get();

    console.log(`📊 Total usuarios: ${usersSnapshot.size}\n`);

    usersSnapshot.forEach((doc) => {
      const userData = doc.data();
      const devicePhoneNumbers = userData.devicePhoneNumbers;
      const lastContactsSync = userData.lastContactsSync;

      console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      console.log(`👤 ${userData.name || 'Sin nombre'} (${doc.id})`);
      console.log(`   Rol: ${userData.role || 'Sin rol'}`);
      console.log(`   Teléfono: ${userData.phone || 'Sin teléfono'}`);

      if (!devicePhoneNumbers) {
        console.log('   ❌ Campo "devicePhoneNumbers" NO EXISTE');
      } else if (Array.isArray(devicePhoneNumbers)) {
        console.log(`   ✅ devicePhoneNumbers: ${devicePhoneNumbers.length} números`);
        if (devicePhoneNumbers.length > 0) {
          console.log(`   📞 Primeros 5: ${devicePhoneNumbers.slice(0, 5).join(', ')}`);
        }
      } else {
        console.log(`   ⚠️ devicePhoneNumbers tiene tipo incorrecto: ${typeof devicePhoneNumbers}`);
      }

      if (lastContactsSync) {
        const syncDate = new Date(lastContactsSync.seconds * 1000);
        console.log(`   🕐 Última sincronización: ${syncDate.toISOString()}`);
      } else {
        console.log('   ⚠️ Nunca sincronizó contactos');
      }

      console.log('');
    });

    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    // Resumen
    const withDeviceNumbers = usersSnapshot.docs.filter(
      doc => doc.data().devicePhoneNumbers && doc.data().devicePhoneNumbers.length > 0
    ).length;

    console.log('📊 RESUMEN:');
    console.log(`   Total usuarios: ${usersSnapshot.size}`);
    console.log(`   Con devicePhoneNumbers: ${withDeviceNumbers}`);
    console.log(`   Sin devicePhoneNumbers: ${usersSnapshot.size - withDeviceNumbers}`);

    if (withDeviceNumbers === 0) {
      console.log('\n⚠️ PROBLEMA: Ningún usuario tiene devicePhoneNumbers');
      console.log('   Esto significa que no se está sincronizando contactos');
    }

    console.log('\n✅ Verificación completada\n');

  } catch (error) {
    console.error('❌ Error:', error);
  } finally {
    process.exit(0);
  }
}

checkDevicePhoneNumbers();
