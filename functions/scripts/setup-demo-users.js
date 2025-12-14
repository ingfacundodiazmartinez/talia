/**
 * Script completo para configurar usuarios de demo
 *
 * 1. Busca usuarios de prueba por teléfono
 * 2. Copia fotos de usuarios originales
 * 3. Asigna roles (parent/child)
 * 4. Cambia nombres
 * 5. Crea vinculaciones parent-child
 * 6. Crea contactos aprobados
 * 7. Crea grupo familiar
 * 8. Crea conversaciones guionadas
 */

const admin = require('firebase-admin');
const serviceAccount = require('../../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: 'talia-chat-app-v2'
});

const db = admin.firestore();

// ============================================
// CONFIGURACIÓN
// ============================================

// Usuarios originales (para copiar fotos)
const ORIGINAL_USERS = {
  mica: '60iJdkq4aEXLj9JHSVBD9JsxtBR2',
  oli: 'oEhhRP6mIuh1TlyShmdfqDfVPeu2',
  tadeo: '77m006WREsaxzVO726xs8wCReBJ3'
};

// Teléfonos de prueba
const TEST_PHONES = {
  facu: '+5493875433442',
  sofi: '+5493875433446',    // Será mamá
  tadeo: '+5493875433447',   // Será hijo
  mia: '+5493875433445'      // Será hija (recién creada)
};

// Configuración final deseada
const DESIRED_CONFIG = {
  facu: { name: 'Facu', role: 'parent', copyPhotoFrom: null },
  sofi: { name: 'Sofi', role: 'parent', copyPhotoFrom: 'mica' },
  tadeo: { name: 'Tadeo', role: 'child', copyPhotoFrom: 'tadeo' },
  mia: { name: 'Mia', role: 'child', copyPhotoFrom: 'oli' }
};

// Storage de IDs encontrados
let users = {};

// ============================================
// UTILIDADES
// ============================================

function getTimestamp(minutesAgo = 0) {
  return admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - minutesAgo * 60 * 1000)
  );
}

function getChatId(userId1, userId2) {
  const sorted = [userId1, userId2].sort();
  return `${sorted[0]}_${sorted[1]}`;
}

// ============================================
// PASO 1: BUSCAR USUARIOS
// ============================================

async function findTestUsers() {
  console.log('\n📱 PASO 1: Buscando usuarios de prueba...\n');

  const usersSnapshot = await db.collection('users').get();

  for (const [key, phone] of Object.entries(TEST_PHONES)) {
    const normalizedSearch = phone.replace(/[+\s-]/g, '').slice(-10);

    usersSnapshot.forEach(doc => {
      const data = doc.data();
      const userPhone = (data.phone || data.phoneNumber || '').replace(/[+\s-]/g, '');

      if (userPhone.includes(normalizedSearch) || normalizedSearch.includes(userPhone.slice(-10))) {
        if (userPhone.length >= 10) {
          users[key] = {
            id: doc.id,
            currentName: data.name || data.displayName || 'Sin nombre',
            currentRole: data.role || 'unknown',
            phone: data.phone || data.phoneNumber,
            photoURL: data.photoURL
          };
        }
      }
    });
  }

  // Mostrar resultados
  for (const [key, config] of Object.entries(DESIRED_CONFIG)) {
    if (users[key]) {
      console.log(`   ✅ ${key.toUpperCase()}: ${users[key].currentName} → ${config.name} (${config.role})`);
      console.log(`      ID: ${users[key].id}`);
    } else {
      console.log(`   ❌ ${key.toUpperCase()}: NO ENCONTRADO (${TEST_PHONES[key]})`);
    }
  }

  const found = Object.keys(users).length;
  if (found < 4) {
    console.log(`\n⚠️  Solo se encontraron ${found}/4 usuarios.`);
    return false;
  }

  return true;
}

// ============================================
// PASO 2: OBTENER FOTOS DE USUARIOS ORIGINALES
// ============================================

async function getOriginalPhotos() {
  console.log('\n📸 PASO 2: Obteniendo fotos de usuarios originales...\n');

  const photos = {};

  for (const [key, id] of Object.entries(ORIGINAL_USERS)) {
    const doc = await db.collection('users').doc(id).get();
    if (doc.exists) {
      const data = doc.data();
      photos[key] = data.photoURL || null;
      console.log(`   ${key}: ${photos[key] ? '✅ Foto encontrada' : '❌ Sin foto'}`);
    }
  }

  return photos;
}

// ============================================
// PASO 3: ACTUALIZAR USUARIOS
// ============================================

async function updateUsers(originalPhotos) {
  console.log('\n👤 PASO 3: Actualizando usuarios...\n');

  for (const [key, config] of Object.entries(DESIRED_CONFIG)) {
    if (!users[key]) continue;

    const userId = users[key].id;
    const updateData = {
      name: config.name,
      displayName: config.name,
      role: config.role,
      updatedAt: admin.firestore.FieldValue.serverTimestamp()
    };

    // Copiar foto si está configurado
    if (config.copyPhotoFrom && originalPhotos[config.copyPhotoFrom]) {
      updateData.photoURL = originalPhotos[config.copyPhotoFrom];
    }

    // Campos específicos por rol
    if (config.role === 'parent') {
      updateData.linkedChildrenIds = [];
    }

    await db.collection('users').doc(userId).update(updateData);
    console.log(`   ✅ ${config.name} (${config.role}) actualizado`);

    // Actualizar objeto local
    users[key].name = config.name;
    users[key].role = config.role;
  }
}

// ============================================
// PASO 4: CREAR VINCULACIONES PARENT-CHILD
// ============================================

async function createParentChildLinks() {
  console.log('\n👨‍👩‍👧‍👦 PASO 4: Creando vinculaciones parent-child...\n');

  const facu = users.facu;
  const sofi = users.sofi;
  const tadeo = users.tadeo;
  const mia = users.mia;

  // Facu es padre de Tadeo
  await db.collection('users').doc(facu.id).update({
    linkedChildrenIds: admin.firestore.FieldValue.arrayUnion(tadeo.id)
  });
  console.log(`   ✅ Facu → Tadeo (padre-hijo)`);

  // Sofi es madre de Mia
  await db.collection('users').doc(sofi.id).update({
    linkedChildrenIds: admin.firestore.FieldValue.arrayUnion(mia.id)
  });
  console.log(`   ✅ Sofi → Mia (madre-hija)`);

  // También vinculamos cruzado para el grupo familiar
  await db.collection('users').doc(facu.id).update({
    linkedChildrenIds: admin.firestore.FieldValue.arrayUnion(mia.id)
  });
  await db.collection('users').doc(sofi.id).update({
    linkedChildrenIds: admin.firestore.FieldValue.arrayUnion(tadeo.id)
  });
  console.log(`   ✅ Vinculaciones cruzadas creadas`);
}

// ============================================
// PASO 5: CREAR CONTACTOS APROBADOS
// ============================================

async function createApprovedContacts() {
  console.log('\n📇 PASO 5: Creando contactos aprobados...\n');

  const allUsers = [users.facu, users.sofi, users.tadeo, users.mia];

  // Crear contactos entre todos los usuarios
  for (let i = 0; i < allUsers.length; i++) {
    for (let j = i + 1; j < allUsers.length; j++) {
      const user1 = allUsers[i];
      const user2 = allUsers[j];

      const sortedUsers = [user1.id, user2.id].sort();

      // Verificar si ya existe el contacto
      const existingContact = await db.collection('contacts')
        .where('users', '==', sortedUsers)
        .get();

      if (existingContact.empty) {
        await db.collection('contacts').add({
          users: sortedUsers,
          user1Name: user1.name,
          user2Name: user2.name,
          status: 'approved',
          autoApproved: true,
          addedAt: getTimestamp(1440),
          approvedAt: getTimestamp(1440),
          updatedAt: getTimestamp(0)
        });
        console.log(`   ✅ Contacto: ${user1.name} ↔ ${user2.name}`);
      } else {
        // Actualizar a approved si existe
        const docId = existingContact.docs[0].id;
        await db.collection('contacts').doc(docId).update({
          status: 'approved',
          approvedAt: getTimestamp(1440)
        });
        console.log(`   🔄 Contacto actualizado: ${user1.name} ↔ ${user2.name}`);
      }
    }
  }
}

// ============================================
// PASO 6: CREAR GRUPO FAMILIAR
// ============================================

async function createFamilyGroup() {
  console.log('\n🏠 PASO 6: Creando grupo familiar "Casa"...\n');

  const memberIds = [users.facu.id, users.sofi.id, users.tadeo.id, users.mia.id];

  // Buscar si ya existe un grupo con estos miembros
  const existingGroups = await db.collection('groups_v2')
    .where('members', 'array-contains', users.facu.id)
    .get();

  let groupId = null;

  for (const doc of existingGroups.docs) {
    const data = doc.data();
    if (data.name && data.name.toLowerCase().includes('casa')) {
      groupId = doc.id;
      console.log(`   🔄 Grupo existente encontrado: ${doc.id}`);
      break;
    }
  }

  if (!groupId) {
    // Crear nuevo grupo
    const groupRef = await db.collection('groups_v2').add({
      name: 'Casa 🏡',
      description: 'Grupo familiar',
      type: 'group',
      members: memberIds,
      admins: [users.facu.id, users.sofi.id],
      createdBy: users.facu.id,
      createdAt: getTimestamp(1440),
      lastActivity: getTimestamp(0),
      lastMessage: '',
      lastMessageType: 'text'
    });
    groupId = groupRef.id;
    console.log(`   ✅ Grupo creado: ${groupId}`);
  }

  // Crear/actualizar miembros del grupo
  for (const user of [users.facu, users.sofi, users.tadeo, users.mia]) {
    const isAdmin = user.role === 'parent';
    await db.collection('groups_v2').doc(groupId).collection('members').doc(user.id).set({
      userId: user.id,
      displayName: user.name,
      status: isAdmin ? 'admin' : 'approved',
      joinedAt: getTimestamp(1440),
      approvedAt: getTimestamp(1440)
    }, { merge: true });
  }
  console.log(`   ✅ Miembros del grupo configurados`);

  return groupId;
}

// ============================================
// PASO 7: CREAR CHATS Y MENSAJES
// ============================================

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

async function ensureChatExists(user1, user2) {
  const chatId = getChatId(user1.id, user2.id);
  const chatRef = db.collection('chats').doc(chatId);
  const chatDoc = await chatRef.get();

  if (!chatDoc.exists) {
    await chatRef.set({
      participants: [user1.id, user2.id].sort(),
      type: 'individual',
      createdAt: getTimestamp(1440),
      lastActivity: getTimestamp(0),
      lastMessage: '',
      lastMessageType: 'text',
      [`unreadCount_${user1.id}`]: 0,
      [`unreadCount_${user2.id}`]: 0
    });
  }

  return chatId;
}

async function createGroupMessage(groupId, senderId, senderName, text, minutesAgo) {
  const messageData = {
    senderId,
    senderName,
    text,
    type: 'text',
    timestamp: getTimestamp(minutesAgo),
    readBy: [],
    deliveredTo: []
  };

  await db.collection('groups_v2').doc(groupId).collection('messages').add(messageData);

  await db.collection('groups_v2').doc(groupId).update({
    lastMessage: text.substring(0, 100),
    lastMessageAt: messageData.timestamp,
    lastMessageSender: senderId,
    lastActivity: messageData.timestamp
  });
}

async function createAllChats(groupId) {
  console.log('\n💬 PASO 7: Creando chats y mensajes...\n');

  const facu = users.facu;
  const sofi = users.sofi;
  const tadeo = users.tadeo;
  const mia = users.mia;

  // Chat 1: Papa-Hijo (Facu-Tadeo)
  console.log('   💬 Chat Facu-Tadeo (Papa-Hijo)...');
  const chatFacuTadeo = await ensureChatExists(facu, tadeo);
  await createMessage(chatFacuTadeo, tadeo.id, 'Pa, ¿cómo estás? 😊', { minutesAgo: 25 });
  await createMessage(chatFacuTadeo, facu.id, 'Bien hijo, ¿vos?', { minutesAgo: 23 });
  await createMessage(chatFacuTadeo, tadeo.id, 'Todo bien. ¿Hoy me llevás a fútbol? ⚽️', { minutesAgo: 20 });
  await createMessage(chatFacuTadeo, facu.id, 'Claro, salimos a las 18:00. ¿Te parece?', { minutesAgo: 18 });
  await createMessage(chatFacuTadeo, tadeo.id, 'Sí, perfecto 🙌', { minutesAgo: 15 });
  console.log('      ✅ 5 mensajes');

  // Chat 2: Mama-Hija (Sofi-Mia)
  console.log('   💬 Chat Sofi-Mia (Mama-Hija)...');
  const chatSofiMia = await ensureChatExists(sofi, mia);
  await createMessage(chatSofiMia, mia.id, 'Mamáaa 💜 ¿qué hacemos para la merienda?', { minutesAgo: 45 });
  await createMessage(chatSofiMia, sofi.id, 'Lo que quieras amor, ¿panqueques? 🥞✨', { minutesAgo: 42 });
  await createMessage(chatSofiMia, mia.id, '¡¡Siii!!', { minutesAgo: 40 });
  await createMessage(chatSofiMia, sofi.id, 'Ok, te espero cuando vuelvas.', { minutesAgo: 38 });
  console.log('      ✅ 4 mensajes');

  // Chat 3: Hermanos (Tadeo-Mia) con mensaje bloqueado
  console.log('   💬 Chat Tadeo-Mia (Hermanos + moderación)...');
  const chatHermanos = await ensureChatExists(tadeo, mia);

  // Habilitar moderación
  await db.collection('chats').doc(chatHermanos).update({
    moderationEnabled: true,
    moderationLevel: 'moderate'
  });

  await createMessage(chatHermanos, tadeo.id, '¿Jugamos más tarde al juego de construir mundos? 😄', { minutesAgo: 35 });
  await createMessage(chatHermanos, mia.id, 'Mensaje bloqueado – Lenguaje ofensivo detectado', {
    minutesAgo: 33,
    moderationStatus: 'blocked',
    moderationReason: 'Lenguaje ofensivo detectado',
    originalText: '[Contenido moderado - chiste inapropiado]'
  });
  await createMessage(chatHermanos, tadeo.id, 'Jajaja tu mensaje apareció bloqueado 😂 ¿Qué pusiste?', { minutesAgo: 30 });
  await createMessage(chatHermanos, mia.id, 'Era un chiste sobre tu casita del juego 😅 La app lo frenó.', { minutesAgo: 28 });
  await createMessage(chatHermanos, tadeo.id, 'Bueno mejor así jaja. ¿Jugamos a las 8:30?', { minutesAgo: 25 });
  await createMessage(chatHermanos, mia.id, 'Dale.', { minutesAgo: 23 });
  console.log('      ✅ 6 mensajes (1 bloqueado)');

  // Chat 4: Grupo Familiar
  console.log('   💬 Grupo Casa...');
  await createGroupMessage(groupId, sofi.id, sofi.name, 'Chicos, hoy cenamos temprano 🍝✨', 60);
  await createGroupMessage(groupId, facu.id, facu.name, 'Genial, llego tipo 19:30 👍', 55);
  await createGroupMessage(groupId, tadeo.id, tadeo.name, '¡Bien! Después quiero ver una peli 😎🎬', 50);
  await createGroupMessage(groupId, mia.id, mia.name, 'Yo también, elijo yo hoy 😁', 45);
  await createGroupMessage(groupId, sofi.id, sofi.name, 'Dale, pero primero tarea 😉📚', 40);
  console.log('      ✅ 5 mensajes');
}

// ============================================
// MAIN
// ============================================

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════════╗');
  console.log('║     CONFIGURACIÓN COMPLETA DE USUARIOS DE DEMO               ║');
  console.log('╚═══════════════════════════════════════════════════════════════╝');

  try {
    // Paso 1: Buscar usuarios
    const usersFound = await findTestUsers();
    if (!usersFound) {
      console.log('\n❌ No se pueden continuar sin todos los usuarios.\n');
      process.exit(1);
    }

    // Paso 2: Obtener fotos originales
    const originalPhotos = await getOriginalPhotos();

    // Paso 3: Actualizar usuarios
    await updateUsers(originalPhotos);

    // Paso 4: Crear vinculaciones parent-child
    await createParentChildLinks();

    // Paso 5: Crear contactos aprobados
    await createApprovedContacts();

    // Paso 6: Crear grupo familiar
    const groupId = await createFamilyGroup();

    // Paso 7: Crear chats y mensajes
    await createAllChats(groupId);

    console.log('\n╔═══════════════════════════════════════════════════════════════╗');
    console.log('║     ✅ CONFIGURACIÓN COMPLETADA                               ║');
    console.log('╚═══════════════════════════════════════════════════════════════╝\n');

    console.log('📱 Usuarios configurados:');
    console.log(`   👨 Facu (papá): ${users.facu.id}`);
    console.log(`   👩 Sofi (mamá): ${users.sofi.id}`);
    console.log(`   👦 Tadeo (hijo): ${users.tadeo.id}`);
    console.log(`   👧 Mia (hija): ${users.mia.id}`);
    console.log(`\n🏠 Grupo familiar: ${groupId}\n`);

    console.log('⚠️  IMPORTANTE: Cierra la app completamente y vuelve a abrirla\n');

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    console.error(error.stack);
  } finally {
    process.exit(0);
  }
}

main();
