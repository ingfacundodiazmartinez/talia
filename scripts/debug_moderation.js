/**
 * Script de diagnóstico para investigar problemas de moderación
 * Analiza la configuración de moderación entre Facu y Mica
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

function str(value) {
  return value !== undefined ? String(value) : 'undefined';
}

async function debugModeration() {
  try {
    console.log('\n🔍 ========== DIAGNÓSTICO DE MODERACIÓN ==========\n');

    // 1. Buscar usuarios Facu y Mica
    console.log('📱 Buscando usuarios Facu y Mica...\n');

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

    if (!facuUser) {
      console.log('❌ No se encontró usuario Facu');
      return;
    }
    if (!micaUser) {
      console.log('❌ No se encontró usuario Mica');
      return;
    }

    console.log('✅ Usuarios encontrados:');
    console.log('   Facu:', facuUser.id);
    console.log('   Mica:', micaUser.id);
    console.log('');

    // 2. Analizar configuración de moderación de cada usuario
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('👤 CONFIGURACIÓN DE FACU:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('   Nombre:', facuUser.name);
    console.log('   Email:', facuUser.email);
    console.log('   Rol:', facuUser.role);
    console.log('   moderationEnabled:', str(facuUser.moderationEnabled));
    console.log('   moderationLevel:', str(facuUser.moderationLevel));
    console.log('');

    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('👤 CONFIGURACIÓN DE MICA:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('   Nombre:', micaUser.name);
    console.log('   Email:', micaUser.email);
    console.log('   Rol:', micaUser.role);
    console.log('   moderationEnabled:', str(micaUser.moderationEnabled));
    console.log('   moderationLevel:', str(micaUser.moderationLevel));
    console.log('');

    // 3. Buscar chat entre ellos
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('💬 BUSCANDO CHAT ENTRE FACU Y MICA:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    const chatsSnapshot = await db.collection('chats')
      .where('participants', 'array-contains', facuUser.id)
      .get();

    let chat = null;
    chatsSnapshot.forEach(doc => {
      const data = doc.data();
      if (data.participants && data.participants.includes(micaUser.id)) {
        chat = { id: doc.id, ...data };
      }
    });

    if (!chat) {
      console.log('❌ No se encontró chat entre Facu y Mica');
      console.log('');
    } else {
      console.log('✅ Chat encontrado:', chat.id);
      console.log('   Participantes:', chat.participants.join(', '));
      console.log('   moderationEnabled:', str(chat.moderationEnabled));
      console.log('   moderationLevel:', str(chat.moderationLevel));
      console.log('');
    }

    // 4. Buscar contacto entre ellos
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('👥 BUSCANDO CONTACTO ENTRE FACU Y MICA:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    // Buscar contacto (puede haber 2, uno por cada dirección)
    const sortedUsers = [facuUser.id, micaUser.id].sort();
    const contactsSnapshot = await db.collection('contacts')
      .where('users', '==', sortedUsers)
      .get();

    if (contactsSnapshot.empty) {
      console.log('❌ No se encontró contacto entre Facu y Mica');
      console.log('');
    } else {
      contactsSnapshot.forEach(doc => {
        const data = doc.data();
        console.log('✅ Contacto encontrado:', doc.id);
        console.log('   Users:', data.users.join(', '));
        console.log('   ownerId:', str(data.ownerId));
        console.log('   contactId:', str(data.contactId));
        console.log('   moderationEnabled:', str(data.moderationEnabled));
        console.log('   moderationLevel:', str(data.moderationLevel));
        console.log('   moderationSettings:', JSON.stringify(data.moderationSettings || {}, null, 2));
        console.log('');
      });
    }

    // 4.5. BUSCAR TODOS LOS CONTACTOS DE FACU (para ver si arrayContains devuelve incorrectos)
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🔍 BUSCANDO TODOS LOS CONTACTOS DE FACU (usando arrayContains):');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    const facuContactsSnapshot = await db.collection('contacts')
      .where('users', 'array-contains', facuUser.id)
      .get();

    console.log('📊 Total contactos encontrados con arrayContains:', facuContactsSnapshot.size);
    console.log('');

    facuContactsSnapshot.forEach(doc => {
      const data = doc.data();
      const users = data.users || [];
      const moderationSettings = data.moderationSettings || {};

      console.log('  Contacto:', doc.id);
      console.log('    Users:', users.join(', '));
      console.log('    moderationSettings:', JSON.stringify(moderationSettings, null, 6));

      // Ver si alguno tiene moderación activa
      for (const [userId, settings] of Object.entries(moderationSettings)) {
        if (settings && settings.enabled) {
          console.log('    ⚠️ USUARIO', userId, 'TIENE MODERACIÓN ACTIVA!');
        }
      }
      console.log('');
    });

    // 5. Buscar mensajes bloqueados recientes
    if (chat) {
      console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      console.log('🚫 MENSAJES BLOQUEADOS RECIENTES:');
      console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      const messagesSnapshot = await db.collection('chats')
        .doc(chat.id)
        .collection('messages')
        .where('moderationStatus', '==', 'blocked')
        .orderBy('timestamp', 'desc')
        .limit(5)
        .get();

      if (messagesSnapshot.empty) {
        console.log('✅ No hay mensajes bloqueados recientes');
        console.log('');
      } else {
        console.log('📊 Total de mensajes bloqueados encontrados:', messagesSnapshot.size);
        console.log('');

        messagesSnapshot.forEach((doc, index) => {
          const msg = doc.data();
          console.log('   Mensaje', index + 1 + ':');
          console.log('      ID:', doc.id);
          console.log('      SenderId:', msg.senderId);
          console.log('      Sender:', msg.senderId === facuUser.id ? 'Facu' : 'Mica');
          console.log('      Text:', str(msg.text));
          console.log('      OriginalText:', str(msg.originalText));
          console.log('      ModerationStatus:', msg.moderationStatus);
          console.log('      ModerationReason:', str(msg.moderationReason));
          if (msg.timestamp) {
            console.log('      Timestamp:', new Date(msg.timestamp.seconds * 1000).toISOString());
          } else {
            console.log('      Timestamp: null');
          }
          console.log('');
        });
      }
    }

    // 6. RESUMEN Y DIAGNÓSTICO
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('📋 RESUMEN Y DIAGNÓSTICO:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    console.log('');
    console.log('🔍 Jerarquía de moderación (de mayor a menor prioridad):');
    console.log('   1. Chat-level moderation');
    console.log('   2. Contact-level moderation');
    console.log('   3. User-level moderation (receiver)');
    console.log('');

    console.log('💡 ANÁLISIS:');

    // Analizar si hay moderación activa en algún nivel
    const chatModeration = chat ? chat.moderationEnabled : undefined;
    const contactModeration = contactsSnapshot.docs.length > 0
      ? contactsSnapshot.docs[0].data().moderationEnabled
      : undefined;
    const facuModeration = facuUser.moderationEnabled;
    const micaModeration = micaUser.moderationEnabled;

    console.log('   Chat moderation:', str(chatModeration));
    console.log('   Contact moderation:', str(contactModeration));
    console.log('   Facu moderation (receiver):', str(facuModeration));
    console.log('   Mica moderation (receiver):', str(micaModeration));
    console.log('');

    // Determinar qué nivel está causando el bloqueo
    if (chatModeration === true) {
      console.log('⚠️  PROBLEMA ENCONTRADO: Chat-level moderation está ACTIVADA');
      console.log('   Los mensajes se están bloqueando por configuración del chat');
      console.log('');
    } else if (contactModeration === true) {
      console.log('⚠️  PROBLEMA ENCONTRADO: Contact-level moderation está ACTIVADA');
      console.log('   Los mensajes se están bloqueando por configuración del contacto');
      console.log('');
    } else if (facuModeration === true || micaModeration === true) {
      console.log('⚠️  PROBLEMA ENCONTRADO: User-level moderation está ACTIVADA');
      const users = [];
      if (facuModeration) users.push('Facu');
      if (micaModeration) users.push('Mica');
      console.log('  ', users.join(' y '), 'tiene moderación activa');
      console.log('');
    } else {
      console.log('✅ Todas las configuraciones de moderación están DESACTIVADAS');
      console.log('   Si los mensajes siguen siendo bloqueados, hay un bug en el código');
      console.log('');
    }

    console.log('✅ Diagnóstico completado');
    console.log('');

  } catch (error) {
    console.error('❌ Error en diagnóstico:', error);
  } finally {
    process.exit(0);
  }
}

// Ejecutar
debugModeration();
