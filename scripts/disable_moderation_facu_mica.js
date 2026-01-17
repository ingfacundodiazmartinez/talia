/**
 * Script para desactivar moderación entre Facu y Mica
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

async function disableModeration() {
  try {
    console.log('\n🔧 ========== DESACTIVANDO MODERACIÓN ==========\n');

    // 1. Buscar usuarios
    const usersSnapshot = await db.collection('users').get();
    let facuUser = null;
    let micaUser = null;

    usersSnapshot.forEach(doc => {
      const data = doc.data();
      if (data.name === 'Facu') {
        facuUser = { id: doc.id, ...data };
      } else if (data.name === 'Mica') {
        micaUser = { id: doc.id, ...data };
      }
    });

    if (!facuUser || !micaUser) {
      console.log('❌ No se encontraron los usuarios');
      return;
    }

    console.log('✅ Usuarios encontrados:');
    console.log('   Facu:', facuUser.id);
    console.log('   Mica:', micaUser.id);
    console.log('');

    // 2. Buscar contacto entre ellos
    const sortedUsers = [facuUser.id, micaUser.id].sort();
    const contactsSnapshot = await db.collection('contacts')
      .where('users', '==', sortedUsers)
      .get();

    if (contactsSnapshot.empty) {
      console.log('❌ No se encontró contacto entre Facu y Mica');
      return;
    }

    const contactDoc = contactsSnapshot.docs[0];
    const contactData = contactDoc.data();

    console.log('✅ Contacto encontrado:', contactDoc.id);
    console.log('');

    // 3. Mostrar configuración actual
    console.log('📋 CONFIGURACIÓN ACTUAL:');
    console.log('   moderationSettings:', JSON.stringify(contactData.moderationSettings || {}, null, 2));
    console.log('');

    // 4. Desactivar moderación para ambos usuarios
    console.log('🔧 Desactivando moderación...');
    console.log('');

    const newModerationSettings = {
      [facuUser.id]: {
        enabled: false,
        level: 'low',
        disabledAt: new Date(),
      },
      [micaUser.id]: {
        enabled: false,
        level: 'low',
        disabledAt: new Date(),
      },
    };

    await db.collection('contacts').doc(contactDoc.id).update({
      moderationSettings: newModerationSettings,
    });

    console.log('✅ Moderación desactivada exitosamente');
    console.log('');
    console.log('📋 NUEVA CONFIGURACIÓN:');
    console.log('   moderationSettings:', JSON.stringify(newModerationSettings, null, 2));
    console.log('');
    console.log('✅ Proceso completado');
    console.log('');

  } catch (error) {
    console.error('❌ Error:', error);
  } finally {
    process.exit(0);
  }
}

// Ejecutar
disableModeration();
