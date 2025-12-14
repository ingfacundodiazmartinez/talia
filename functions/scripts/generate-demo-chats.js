/**
 * Script para generar conversaciones de demo para capturas de pantalla
 *
 * Usuarios:
 * - Facu: padre
 * - Mica: madre
 * - Oli: hija de Mica
 * - Tadeo: hijo de Facu
 *
 * Uso: node generate-demo-chats.js
 */

const admin = require('firebase-admin');
const path = require('path');

// Inicializar Firebase Admin
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// ============================================
// CONFIGURACION - Usuarios a buscar
// ============================================
const USER_SEARCH_CONFIG = {
  facu: { searchTerms: ['facu', 'facundo'], role: 'parent' },
  mica: { searchTerms: ['mica', 'micaela'], role: 'parent' },
  oli: { searchTerms: ['oli', 'olivia'], role: 'child' },
  tadeo: { searchTerms: ['tadeo', 'tade'], role: 'child' }
};

// Almacenamiento de IDs encontrados
let users = {
  facu: null,
  mica: null,
  oli: null,
  tadeo: null
};

// ============================================
// UTILIDADES
// ============================================

/**
 * Genera un ID de chat a partir de dos user IDs (ordenados alfabeticamente)
 */
function getChatId(userId1, userId2) {
  const sorted = [userId1, userId2].sort();
  return `${sorted[0]}_${sorted[1]}`;
}

/**
 * Genera un timestamp con offset en minutos desde ahora
 */
function getTimestamp(minutesAgo = 0) {
  return admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - minutesAgo * 60 * 1000)
  );
}

/**
 * Busca usuarios por nombre
 */
async function findUsers() {
  console.log('\n🔍 Buscando usuarios en Firestore...\n');

  const usersSnapshot = await db.collection('users').get();
  const allUsers = [];

  usersSnapshot.forEach(doc => {
    const data = doc.data();
    allUsers.push({
      id: doc.id,
      name: data.name || data.displayName || '',
      email: data.email || '',
      role: data.role || 'unknown'
    });
  });

  console.log(`📊 Total usuarios en DB: ${allUsers.length}\n`);

  // Buscar cada usuario por sus terminos de busqueda
  for (const [key, config] of Object.entries(USER_SEARCH_CONFIG)) {
    for (const term of config.searchTerms) {
      const found = allUsers.find(u =>
        u.name.toLowerCase().includes(term.toLowerCase()) ||
        u.email.toLowerCase().includes(term.toLowerCase())
      );

      if (found) {
        users[key] = found;
        console.log(`✅ ${key.toUpperCase()}: ${found.name} (${found.id}) - ${found.role}`);
        break;
      }
    }

    if (!users[key]) {
      console.log(`❌ ${key.toUpperCase()}: NO ENCONTRADO`);
    }
  }

  // Verificar que todos los usuarios fueron encontrados
  const missing = Object.entries(users).filter(([_, v]) => !v).map(([k, _]) => k);
  if (missing.length > 0) {
    console.log(`\n⚠️  Usuarios no encontrados: ${missing.join(', ')}`);
    console.log('\n📋 Lista de usuarios disponibles:');
    allUsers.forEach(u => {
      console.log(`   - ${u.name} (${u.id}) - ${u.role}`);
    });
    return false;
  }

  return true;
}

// ============================================
// LIMPIEZA DE CHATS
// ============================================

/**
 * Vacia los mensajes de un chat individual (sin eliminar el chat)
 */
async function clearChatMessages(chatId) {
  const messagesRef = db.collection('chats').doc(chatId).collection('messages');
  const messages = await messagesRef.get();

  if (messages.empty) {
    console.log(`   📭 Chat ${chatId}: ya estaba vacio`);
    return 0;
  }

  const batch = db.batch();
  messages.forEach(doc => {
    batch.delete(doc.ref);
  });
  await batch.commit();

  console.log(`   🗑️  Chat ${chatId}: ${messages.size} mensajes eliminados`);
  return messages.size;
}

/**
 * Vacia los mensajes de un grupo (sin eliminar el grupo)
 */
async function clearGroupMessages(groupId) {
  // Intentar en groups_v2 primero, luego en groups
  let messagesRef = db.collection('groups_v2').doc(groupId).collection('messages');
  let messages = await messagesRef.get();

  if (messages.empty) {
    messagesRef = db.collection('groups').doc(groupId).collection('messages');
    messages = await messagesRef.get();
  }

  if (messages.empty) {
    console.log(`   📭 Grupo ${groupId}: ya estaba vacio`);
    return 0;
  }

  const batch = db.batch();
  messages.forEach(doc => {
    batch.delete(doc.ref);
  });
  await batch.commit();

  console.log(`   🗑️  Grupo ${groupId}: ${messages.size} mensajes eliminados`);
  return messages.size;
}

/**
 * Encuentra y vacia todos los chats relevantes
 */
async function clearAllRelevantChats() {
  console.log('\n🧹 Limpiando chats existentes...\n');

  const userIds = Object.values(users).map(u => u.id);

  // Buscar todos los chats donde participen estos usuarios
  const chatsSnapshot = await db.collection('chats')
    .where('participants', 'array-contains-any', userIds)
    .get();

  let totalCleared = 0;

  for (const doc of chatsSnapshot.docs) {
    const chatId = doc.id;
    const data = doc.data();

    // Verificar que ambos participantes son de nuestro grupo
    const participants = data.participants || [];
    const isRelevant = participants.every(p => userIds.includes(p));

    if (isRelevant) {
      totalCleared += await clearChatMessages(chatId);
    }
  }

  // Buscar el grupo familiar "Casa"
  const groupsSnapshot = await db.collection('groups_v2').get();
  for (const doc of groupsSnapshot.docs) {
    const data = doc.data();
    if (data.name && (data.name.toLowerCase().includes('casa') || data.name.toLowerCase().includes('casita'))) {
      console.log(`\n📁 Encontrado grupo familiar: ${data.name} (${doc.id})`);
      totalCleared += await clearGroupMessages(doc.id);
    }
  }

  console.log(`\n✅ Total mensajes eliminados: ${totalCleared}`);
}

// ============================================
// CREACION DE MENSAJES
// ============================================

/**
 * Crea un mensaje en un chat
 */
async function createMessage(chatId, senderId, text, options = {}) {
  const {
    minutesAgo = 0,
    type = 'text',
    moderationStatus = null,
    moderationReason = null,
    originalText = null,
    replyTo = null
  } = options;

  const messageData = {
    senderId,
    text,
    type,
    timestamp: getTimestamp(minutesAgo),
    readBy: [],
    deliveredTo: []
  };

  // Agregar campos de moderacion si es necesario
  if (moderationStatus) {
    messageData.moderationStatus = moderationStatus;
    messageData.moderationReason = moderationReason;
    messageData.originalText = originalText;
    messageData.moderationSeverity = 'medium';
  }

  // Agregar reply si existe
  if (replyTo) {
    messageData.replyTo = replyTo;
  }

  const ref = await db.collection('chats').doc(chatId).collection('messages').add(messageData);

  // Actualizar lastMessage del chat
  await db.collection('chats').doc(chatId).update({
    lastMessage: moderationStatus === 'blocked' ? 'Mensaje bloqueado' : text.substring(0, 100),
    lastMessageAt: messageData.timestamp,
    lastMessageSender: senderId,
    lastMessageId: ref.id,
    lastMessageType: type,
    lastActivity: messageData.timestamp
  });

  return ref.id;
}

/**
 * Crea un mensaje en un grupo
 */
async function createGroupMessage(groupId, senderId, senderName, text, minutesAgo = 0) {
  const messageData = {
    senderId,
    senderName,
    text,
    type: 'text',
    timestamp: getTimestamp(minutesAgo),
    readBy: [],
    deliveredTo: []
  };

  // Intentar en groups_v2 primero
  let groupRef = db.collection('groups_v2').doc(groupId);
  let groupDoc = await groupRef.get();

  if (!groupDoc.exists) {
    groupRef = db.collection('groups').doc(groupId);
    groupDoc = await groupRef.get();
  }

  if (!groupDoc.exists) {
    console.log(`   ❌ Grupo ${groupId} no encontrado`);
    return null;
  }

  const ref = await groupRef.collection('messages').add(messageData);

  // Actualizar lastMessage del grupo
  await groupRef.update({
    lastMessage: text.substring(0, 100),
    lastMessageAt: messageData.timestamp,
    lastMessageSender: senderId,
    lastActivity: messageData.timestamp
  });

  return ref.id;
}

/**
 * Asegura que existe un chat entre dos usuarios
 */
async function ensureChatExists(userId1, userId2, user1Name, user2Name) {
  const chatId = getChatId(userId1, userId2);
  const chatRef = db.collection('chats').doc(chatId);
  const chatDoc = await chatRef.get();

  if (!chatDoc.exists) {
    console.log(`   📝 Creando chat ${chatId}...`);
    await chatRef.set({
      participants: [userId1, userId2].sort(),
      type: 'individual',
      createdAt: getTimestamp(1440), // Hace 1 dia
      lastActivity: getTimestamp(0),
      lastMessage: '',
      lastMessageType: 'text',
      [`unreadCount_${userId1}`]: 0,
      [`unreadCount_${userId2}`]: 0
    });
  }

  return chatId;
}

// ============================================
// CHATS GUIONADOS
// ============================================

/**
 * Chat 1: Papa (Facu) - Hijo (Tadeo)
 */
async function createPapaHijoChat() {
  console.log('\n💬 Creando chat Papa-Hijo (Facu-Tadeo)...\n');

  const papa = users.facu;
  const hijo = users.tadeo;

  const chatId = await ensureChatExists(papa.id, hijo.id, papa.name, hijo.name);

  // Mensajes del guion (de mas antiguo a mas reciente)
  await createMessage(chatId, hijo.id, 'Pa, ¿cómo estás? 😊', { minutesAgo: 25 });
  await createMessage(chatId, papa.id, 'Bien hijo, ¿vos?', { minutesAgo: 23 });
  await createMessage(chatId, hijo.id, 'Todo bien. ¿Hoy me llevás a fútbol? ⚽️', { minutesAgo: 20 });
  await createMessage(chatId, papa.id, 'Claro, salimos a las 18:00. ¿Te parece?', { minutesAgo: 18 });
  await createMessage(chatId, hijo.id, 'Sí, perfecto 🙌', { minutesAgo: 15 });

  console.log(`   ✅ Chat ${chatId} creado con 5 mensajes`);
}

/**
 * Chat 2: Mama (Mica) - Hija (Oli)
 */
async function createMamaHijaChat() {
  console.log('\n💬 Creando chat Mama-Hija (Mica-Oli)...\n');

  const mama = users.mica;
  const hija = users.oli;

  const chatId = await ensureChatExists(mama.id, hija.id, mama.name, hija.name);

  // Mensajes del guion
  await createMessage(chatId, hija.id, 'Mamáaa 💜 ¿qué hacemos para la merienda?', { minutesAgo: 45 });
  await createMessage(chatId, mama.id, 'Lo que quieras amor, ¿panqueques? 🥞✨', { minutesAgo: 42 });
  await createMessage(chatId, hija.id, '¡¡Siii!!', { minutesAgo: 40 });
  await createMessage(chatId, mama.id, 'Ok, te espero cuando vuelvas.', { minutesAgo: 38 });

  console.log(`   ✅ Chat ${chatId} creado con 4 mensajes`);
}

/**
 * Chat 3: Hermanos (Tadeo - Oli) - Con mensaje bloqueado
 */
async function createHermanosChat() {
  console.log('\n💬 Creando chat Hermanos (Tadeo-Oli) con moderacion...\n');

  const hermano1 = users.tadeo; // Tadeo
  const hermano2 = users.oli;   // Oli

  const chatId = await ensureChatExists(hermano1.id, hermano2.id, hermano1.name, hermano2.name);

  // Habilitar moderacion en el chat
  await db.collection('chats').doc(chatId).update({
    moderationEnabled: true,
    moderationLevel: 'moderate'
  });

  // Mensajes del guion con mensaje bloqueado
  await createMessage(chatId, hermano1.id, '¿Jugamos más tarde al juego de construir mundos? 😄', { minutesAgo: 35 });

  // Mensaje bloqueado de hermano2
  await createMessage(chatId, hermano2.id, 'Mensaje bloqueado – Lenguaje ofensivo detectado', {
    minutesAgo: 33,
    moderationStatus: 'blocked',
    moderationReason: 'Lenguaje ofensivo detectado',
    originalText: '[Contenido moderado - chiste inapropiado]'
  });

  await createMessage(chatId, hermano1.id, 'Jajaja tu mensaje apareció bloqueado 😂 ¿Qué pusiste?', { minutesAgo: 30 });
  await createMessage(chatId, hermano2.id, 'Era un chiste sobre tu casita del juego 😅 La app lo frenó.', { minutesAgo: 28 });
  await createMessage(chatId, hermano1.id, 'Bueno mejor así jaja. ¿Jugamos a las 8:30?', { minutesAgo: 25 });
  await createMessage(chatId, hermano2.id, 'Dale.', { minutesAgo: 23 });

  console.log(`   ✅ Chat ${chatId} creado con 6 mensajes (1 bloqueado)`);
}

/**
 * Chat 4: Grupo Familiar "Casa"
 */
async function createGrupoFamiliarChat() {
  console.log('\n💬 Buscando y actualizando grupo familiar "Casa"...\n');

  // Buscar el grupo "Casa"
  const groupsSnapshot = await db.collection('groups_v2').get();
  let groupId = null;

  for (const doc of groupsSnapshot.docs) {
    const data = doc.data();
    if (data.name && (data.name.toLowerCase().includes('casa') || data.name.toLowerCase().includes('casita'))) {
      groupId = doc.id;
      console.log(`   📁 Grupo encontrado: ${data.name} (${groupId})`);
      break;
    }
  }

  if (!groupId) {
    // Buscar en groups tambien
    const oldGroupsSnapshot = await db.collection('groups').get();
    for (const doc of oldGroupsSnapshot.docs) {
      const data = doc.data();
      if (data.name && (data.name.toLowerCase().includes('casa') || data.name.toLowerCase().includes('casita'))) {
        groupId = doc.id;
        console.log(`   📁 Grupo encontrado (legacy): ${data.name} (${groupId})`);
        break;
      }
    }
  }

  if (!groupId) {
    console.log('   ❌ No se encontró el grupo "Casa"');
    console.log('   ℹ️  Grupos disponibles:');
    groupsSnapshot.forEach(doc => {
      const data = doc.data();
      console.log(`      - ${data.name || 'Sin nombre'} (${doc.id})`);
    });
    return;
  }

  const mama = users.mica;
  const papa = users.facu;
  const hermano1 = users.tadeo;
  const hermano2 = users.oli;

  // Mensajes del guion
  await createGroupMessage(groupId, mama.id, mama.name, 'Chicos, hoy cenamos temprano 🍝✨', 60);
  await createGroupMessage(groupId, papa.id, papa.name, 'Genial, llego tipo 19:30 👍', 55);
  await createGroupMessage(groupId, hermano1.id, hermano1.name, '¡Bien! Después quiero ver una peli 😎🎬', 50);
  await createGroupMessage(groupId, hermano2.id, hermano2.name, 'Yo también, elijo yo hoy 😁', 45);
  await createGroupMessage(groupId, mama.id, mama.name, 'Dale, pero primero tarea 😉📚', 40);

  console.log(`   ✅ Grupo ${groupId} actualizado con 5 mensajes`);
}

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('╔════════════════════════════════════════════════════════════╗');
  console.log('║     GENERADOR DE CHATS DE DEMO - TALIA                    ║');
  console.log('╚════════════════════════════════════════════════════════════╝');

  try {
    // 1. Buscar usuarios
    const usersFound = await findUsers();
    if (!usersFound) {
      console.log('\n❌ No se pueden crear los chats sin todos los usuarios.');
      console.log('   Por favor verifica los nombres en la configuracion.\n');
      process.exit(1);
    }

    // 2. Limpiar chats existentes
    await clearAllRelevantChats();

    // 3. Crear chats guionados
    await createPapaHijoChat();
    await createMamaHijaChat();
    await createHermanosChat();
    await createGrupoFamiliarChat();

    console.log('\n╔════════════════════════════════════════════════════════════╗');
    console.log('║     ✅ PROCESO COMPLETADO                                  ║');
    console.log('╚════════════════════════════════════════════════════════════╝\n');

    console.log('📱 Ahora puedes abrir la app y tomar las capturas de pantalla.\n');
    console.log('Recuerda que aun debes hacer manualmente:');
    console.log('  - Actualizar fotos de perfil de los padres');
    console.log('  - Crear las historias desde la app');
    console.log('  - Responder a las historias\n');

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    console.error(error.stack);
  } finally {
    process.exit(0);
  }
}

// Ejecutar
main();
