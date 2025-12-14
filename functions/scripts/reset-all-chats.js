/**
 * Script para ELIMINAR COMPLETAMENTE todos los mensajes y recrear los guionados
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// IDs de usuarios
const users = {
  facu: { id: 'ldUCB59Xo7gfoGlo948pHJZjeRF3', name: 'Facu' },
  mica: { id: '60iJdkq4aEXLj9JHSVBD9JsxtBR2', name: 'Mica' },
  oli: { id: 'oEhhRP6mIuh1TlyShmdfqDfVPeu2', name: 'Oli' },
  tadeo: { id: '77m006WREsaxzVO726xs8wCReBJ3', name: 'Tadeo' }
};

const GROUP_ID = 'YNjFtdLEmszYXo0e9V1c';

// Chat IDs
const CHAT_IDS = {
  facuTadeo: '77m006WREsaxzVO726xs8wCReBJ3_ldUCB59Xo7gfoGlo948pHJZjeRF3',
  micaOli: '60iJdkq4aEXLj9JHSVBD9JsxtBR2_oEhhRP6mIuh1TlyShmdfqDfVPeu2',
  tadeoOli: '77m006WREsaxzVO726xs8wCReBJ3_oEhhRP6mIuh1TlyShmdfqDfVPeu2'
};

function getTimestamp(minutesAgo = 0) {
  return admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - minutesAgo * 60 * 1000)
  );
}

/**
 * Elimina TODOS los mensajes de un chat usando batches
 */
async function deleteAllMessages(collectionPath) {
  const messagesRef = db.collection(collectionPath);

  let totalDeleted = 0;
  let snapshot = await messagesRef.limit(500).get();

  while (!snapshot.empty) {
    const batch = db.batch();
    snapshot.docs.forEach(doc => {
      batch.delete(doc.ref);
      totalDeleted++;
    });
    await batch.commit();

    // Obtener siguiente batch
    snapshot = await messagesRef.limit(500).get();
  }

  return totalDeleted;
}

/**
 * Crea un mensaje
 */
async function createMessage(chatId, senderId, text, options = {}) {
  const {
    minutesAgo = 0,
    moderationStatus = null,
    moderationReason = null,
    originalText = null
  } = options;

  const messageData = {
    senderId,
    text,
    type: 'text',
    timestamp: getTimestamp(minutesAgo),
    readBy: [],
    deliveredTo: []
  };

  if (moderationStatus) {
    messageData.moderationStatus = moderationStatus;
    messageData.moderationReason = moderationReason;
    messageData.originalText = originalText;
    messageData.moderationSeverity = 'medium';
  }

  const ref = await db.collection('chats').doc(chatId).collection('messages').add(messageData);

  await db.collection('chats').doc(chatId).update({
    lastMessage: moderationStatus === 'blocked' ? 'Mensaje bloqueado' : text.substring(0, 100),
    lastMessageAt: messageData.timestamp,
    lastMessageSender: senderId,
    lastMessageId: ref.id,
    lastMessageType: 'text',
    lastActivity: messageData.timestamp
  });

  return ref.id;
}

async function createGroupMessage(senderId, senderName, text, minutesAgo) {
  const messageData = {
    senderId,
    senderName,
    text,
    type: 'text',
    timestamp: getTimestamp(minutesAgo),
    readBy: [],
    deliveredTo: []
  };

  const groupRef = db.collection('groups_v2').doc(GROUP_ID);
  await groupRef.collection('messages').add(messageData);

  await groupRef.update({
    lastMessage: text.substring(0, 100),
    lastMessageAt: messageData.timestamp,
    lastMessageSender: senderId,
    lastActivity: messageData.timestamp
  });
}

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════════╗');
  console.log('║  RESET COMPLETO DE CHATS - Eliminando y recreando mensajes   ║');
  console.log('╚═══════════════════════════════════════════════════════════════╝\n');

  try {
    // ============================================
    // PASO 1: ELIMINAR TODOS LOS MENSAJES
    // ============================================
    console.log('🗑️  ELIMINANDO TODOS LOS MENSAJES...\n');

    // Chat Facu-Tadeo
    let deleted = await deleteAllMessages(`chats/${CHAT_IDS.facuTadeo}/messages`);
    console.log(`   ✅ Facu-Tadeo: ${deleted} mensajes eliminados`);

    // Chat Mica-Oli
    deleted = await deleteAllMessages(`chats/${CHAT_IDS.micaOli}/messages`);
    console.log(`   ✅ Mica-Oli: ${deleted} mensajes eliminados`);

    // Chat Tadeo-Oli
    deleted = await deleteAllMessages(`chats/${CHAT_IDS.tadeoOli}/messages`);
    console.log(`   ✅ Tadeo-Oli: ${deleted} mensajes eliminados`);

    // Grupo
    deleted = await deleteAllMessages(`groups_v2/${GROUP_ID}/messages`);
    console.log(`   ✅ Grupo Casita: ${deleted} mensajes eliminados`);

    // ============================================
    // PASO 2: CREAR MENSAJES NUEVOS
    // ============================================
    console.log('\n📝 CREANDO MENSAJES NUEVOS...\n');

    // Chat 1: Papa-Hijo (Facu-Tadeo)
    console.log('   💬 Chat Facu-Tadeo...');
    await createMessage(CHAT_IDS.facuTadeo, users.tadeo.id, 'Pa, ¿cómo estás? 😊', { minutesAgo: 25 });
    await createMessage(CHAT_IDS.facuTadeo, users.facu.id, 'Bien hijo, ¿vos?', { minutesAgo: 23 });
    await createMessage(CHAT_IDS.facuTadeo, users.tadeo.id, 'Todo bien. ¿Hoy me llevás a fútbol? ⚽️', { minutesAgo: 20 });
    await createMessage(CHAT_IDS.facuTadeo, users.facu.id, 'Claro, salimos a las 18:00. ¿Te parece?', { minutesAgo: 18 });
    await createMessage(CHAT_IDS.facuTadeo, users.tadeo.id, 'Sí, perfecto 🙌', { minutesAgo: 15 });
    console.log('      ✅ 5 mensajes creados');

    // Chat 2: Mama-Hija (Mica-Oli)
    console.log('   💬 Chat Mica-Oli...');
    await createMessage(CHAT_IDS.micaOli, users.oli.id, 'Mamáaa 💜 ¿qué hacemos para la merienda?', { minutesAgo: 45 });
    await createMessage(CHAT_IDS.micaOli, users.mica.id, 'Lo que quieras amor, ¿panqueques? 🥞✨', { minutesAgo: 42 });
    await createMessage(CHAT_IDS.micaOli, users.oli.id, '¡¡Siii!!', { minutesAgo: 40 });
    await createMessage(CHAT_IDS.micaOli, users.mica.id, 'Ok, te espero cuando vuelvas.', { minutesAgo: 38 });
    console.log('      ✅ 4 mensajes creados');

    // Chat 3: Hermanos (Tadeo-Oli) con mensaje bloqueado
    console.log('   💬 Chat Tadeo-Oli (con moderación)...');

    // Habilitar moderación
    await db.collection('chats').doc(CHAT_IDS.tadeoOli).update({
      moderationEnabled: true,
      moderationLevel: 'moderate'
    });

    await createMessage(CHAT_IDS.tadeoOli, users.tadeo.id, '¿Jugamos más tarde al juego de construir mundos? 😄', { minutesAgo: 35 });
    await createMessage(CHAT_IDS.tadeoOli, users.oli.id, 'Mensaje bloqueado – Lenguaje ofensivo detectado', {
      minutesAgo: 33,
      moderationStatus: 'blocked',
      moderationReason: 'Lenguaje ofensivo detectado',
      originalText: '[Contenido moderado - chiste inapropiado]'
    });
    await createMessage(CHAT_IDS.tadeoOli, users.tadeo.id, 'Jajaja tu mensaje apareció bloqueado 😂 ¿Qué pusiste?', { minutesAgo: 30 });
    await createMessage(CHAT_IDS.tadeoOli, users.oli.id, 'Era un chiste sobre tu casita del juego 😅 La app lo frenó.', { minutesAgo: 28 });
    await createMessage(CHAT_IDS.tadeoOli, users.tadeo.id, 'Bueno mejor así jaja. ¿Jugamos a las 8:30?', { minutesAgo: 25 });
    await createMessage(CHAT_IDS.tadeoOli, users.oli.id, 'Dale.', { minutesAgo: 23 });
    console.log('      ✅ 6 mensajes creados (1 bloqueado)');

    // Chat 4: Grupo Familiar
    console.log('   💬 Grupo Casita...');
    await createGroupMessage(users.mica.id, users.mica.name, 'Chicos, hoy cenamos temprano 🍝✨', 60);
    await createGroupMessage(users.facu.id, users.facu.name, 'Genial, llego tipo 19:30 👍', 55);
    await createGroupMessage(users.tadeo.id, users.tadeo.name, '¡Bien! Después quiero ver una peli 😎🎬', 50);
    await createGroupMessage(users.oli.id, users.oli.name, 'Yo también, elijo yo hoy 😁', 45);
    await createGroupMessage(users.mica.id, users.mica.name, 'Dale, pero primero tarea 😉📚', 40);
    console.log('      ✅ 5 mensajes creados');

    console.log('\n╔═══════════════════════════════════════════════════════════════╗');
    console.log('║  ✅ PROCESO COMPLETADO                                        ║');
    console.log('╚═══════════════════════════════════════════════════════════════╝\n');

    console.log('📱 Ahora CIERRA COMPLETAMENTE la app y vuelve a abrirla.\n');
    console.log('   Si usas iOS: desliza hacia arriba y cierra la app');
    console.log('   Si usas Android: fuerza el cierre desde configuración\n');

  } catch (error) {
    console.error('❌ Error:', error.message);
    console.error(error.stack);
  } finally {
    process.exit(0);
  }
}

main();
